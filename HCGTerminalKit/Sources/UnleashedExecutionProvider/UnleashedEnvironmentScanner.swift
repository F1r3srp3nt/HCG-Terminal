import Foundation
import TerminalCapabilityProvider
import TerminalCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Tool candidates

/// What the read-only probes established about one candidate executable. Each state is
/// backed by the exact system call that produced it (see `probes`):
/// existence, executable permission and a successful launch are three different facts.
public enum ToolState: Hashable, Sendable {
    /// `lstat` failed with ENOENT/ENOTDIR: established absence.
    case missing
    /// A symlink whose target does not resolve (`realpath` failed with ENOENT).
    case brokenSymlink(target: String)
    /// The system refused this app (EPERM/EACCES) at the named step. Says nothing about whether
    /// the program is installed or works.
    case denied(operation: String, errno: Int32)
    /// Exists but is not a regular file.
    case notRegularFile
    /// Exists, but no execute bit is set in its mode.
    case notExecutable
    /// `access(X_OK)` passed. Not launched yet: this is not "verified".
    case executable
    /// Another error (recorded).
    case failed(operation: String, errno: Int32)

    public var exists: Bool {
        switch self {
        case .missing: false
        case .denied(let operation, _): operation != "lstat"
        default: true
        }
    }

    /// Worth an explicit launch attempt: the file exists as a regular file (even if the
    /// sandbox refused `access(X_OK)`; only a launch shows the real result).
    public var launchCandidate: Bool {
        switch self {
        case .executable: true
        case .denied(let operation, _): operation == "access(X_OK)"
        default: false
        }
    }

    public var label: String {
        switch self {
        case .missing: "not found (ENOENT)"
        case .brokenSymlink(let target): "broken symlink → \(target)"
        case .denied(let operation, let code): "\(operation) refused: \(PathProbe.errnoName(code))"
        case .notRegularFile: "not a regular file"
        case .notExecutable: "no execute permission bits"
        case .executable: "access(X_OK) passed; not launched yet"
        case .failed(let operation, let code): "\(operation) failed: \(PathProbe.errnoName(code))"
        }
    }
}

public struct ToolCandidate: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    /// Where a symlink really points, when it could be resolved.
    public var resolvedPath: String?
    public var state: ToolState
    public var probes: [ProbeRecord]
    public var id: String { path }
}

/// Resolves concrete tool paths under every candidate root without executing anything.
public struct ToolResolver: Sendable {
    public static let shellNames = ["zsh", "bash", "sh", "dash"]
    public static let shellDirectories = ["bin", "usr/bin"]
    public static let toolDirectories = ["usr/bin", "bin", "usr/sbin", "sbin", "usr/local/bin"]

    let probe: any SystemProbing

    public init(probe: any SystemProbing) {
        self.probe = probe
    }

    public func resolve(_ path: String, name: String) -> ToolCandidate {
        var probes: [ProbeRecord] = []
        let link = probe.lstatRecord(path)
        probes.append(link)
        guard link.succeeded else {
            let state: ToolState = link.showsAbsence ? .missing : link.showsDenial ? .denied(operation: "lstat", errno: link.errorCode ?? EPERM) : .failed(operation: "lstat", errno: link.errorCode ?? EIO)
            return ToolCandidate(name: name, path: path, resolvedPath: nil, state: state, probes: probes)
        }
        var resolved: String?
        let isLink = link.detail.hasPrefix(ProbedFileType.symlink)
        let target = isLink ? probe.readlinkRecord(path) : nil
        if let target { probes.append(target) }
        // realpath also resolves symlinked parent folders (e.g. /var/jb → /private/preboot/…).
        let real = probe.realpathRecord(path)
        probes.append(real)
        if real.succeeded {
            resolved = real.detail
        } else if isLink, let target {
            if real.showsAbsence {
                return ToolCandidate(name: name, path: path, resolvedPath: nil, state: .brokenSymlink(target: target.detail.isEmpty ? "?" : target.detail), probes: probes)
            } else if real.showsDenial {
                return ToolCandidate(name: name, path: path, resolvedPath: nil, state: .denied(operation: "realpath", errno: real.errorCode ?? EPERM), probes: probes)
            }
        }
        let info = probe.statRecord(path)
        probes.append(info)
        guard info.succeeded else {
            let state: ToolState = info.showsAbsence ? .brokenSymlink(target: "?") : info.showsDenial ? .denied(operation: "stat", errno: info.errorCode ?? EPERM) : .failed(operation: "stat", errno: info.errorCode ?? EIO)
            return ToolCandidate(name: name, path: path, resolvedPath: resolved, state: state, probes: probes)
        }
        guard info.detail.hasPrefix(ProbedFileType.regular) else {
            return ToolCandidate(name: name, path: path, resolvedPath: resolved, state: .notRegularFile, probes: probes)
        }
        let exec = probe.accessRecord(path, mode: X_OK)
        probes.append(exec)
        let state: ToolState
        if exec.succeeded {
            state = .executable
        } else if let mode = Self.mode(from: info.detail), mode & 0o111 == 0 {
            state = .notExecutable
        } else if exec.showsDenial {
            state = .denied(operation: "access(X_OK)", errno: exec.errorCode ?? EPERM)
        } else {
            state = .failed(operation: "access(X_OK)", errno: exec.errorCode ?? EIO)
        }
        return ToolCandidate(name: name, path: path, resolvedPath: resolved, state: state, probes: probes)
    }

    static func mode(from detail: String) -> Int? {
        guard let range = detail.range(of: "mode ") else { return nil }
        return Int(detail[range.upperBound...].prefix { $0.isNumber }, radix: 8)
    }

    /// Every concrete candidate path for `names` under each root (in order) and directory.
    public static func paths(names: [String], roots: [String], directories: [String]) -> [(name: String, path: String)] {
        var result: [(String, String)] = []
        var seen: Set<String> = []
        for root in roots {
            for directory in directories {
                for name in names {
                    let path = root + "/" + directory + "/" + name
                    if seen.insert(path).inserted { result.append((name, path)) }
                }
            }
        }
        return result
    }
}

// MARK: - Scan

/// Access observed for one filesystem location.
public struct LocationAccess: Hashable, Sendable, Codable {
    public var path: String
    public var exists: Bool
    public var readable: Bool
    public var listable: Bool
    public var writable: Bool
}

public struct DetectedTool: Hashable, Sendable, Codable {
    public var name: String
    public var path: String
}

/// One location outside the sandbox and the exact result of listing it, reading a file in it
/// and asking whether it is writable.
public struct LocationProbe: Hashable, Sendable {
    public var path: String
    public var listing: ProbeRecord
    /// Reading one regular file found in the listing (nil when there was nothing to read).
    public var fileRead: ProbeRecord?
    public var writeCheck: ProbeRecord?
}

/// Everything the read-only scan observed. No field is inferred from another: each one
/// comes from its own probe, and each probe is recorded.
public struct UnleashedEnvironmentScan: Hashable, Sendable {
    /// The first root whose shell candidates exist (`/var/jb`, a relocated root, `""` for the
    /// system root), or `nil` if none.
    public var environmentPrefix: String?
    /// Candidates that passed `access(X_OK)` (not launched yet).
    public var shells: [String]
    public var executableDirectories: [String: Int]
    public var packageManagers: [DetectedTool]
    public var elevationTools: [DetectedTool]
    public var effectiveUserID: UInt32
    public var loopbackServicePorts: [Int]
    public var visibleProcessCount: Int?
    public var locations: [LocationAccess]
    public var evidence: [CapabilityEvidence]
    public var operatingSystem: String
    /// Outcome of each path probe (keeps EPERM vs ENOENT).
    public var pathProbes: [String: PathProbe] = [:]
    /// Candidate bootstrap roots and what was observed for each.
    public var roots: [EnvironmentAssessment.Root] = []
    /// Jailbreak indicators checked. Their presence is never treated as usability.
    public var indicators: [EnvironmentAssessment.Indicator] = []
    /// Tool name → resolved executable path.
    public var resolvedTools: [String: String] = [:]

    /// Every shell path that was tried, with its state.
    public var shellCandidates: [ToolCandidate] = []
    /// Package-manager and elevation candidates, with their states.
    public var toolCandidates: [ToolCandidate] = []
    /// Listing each program folder (bin, usr/bin, sbin, usr/sbin) under each root.
    public var programFolderListings: [ProbeRecord] = []
    /// Locations outside the sandbox: listing, reading and writability.
    public var locationProbes: [LocationProbe] = []
    /// TCP connects to 127.0.0.1 (no data sent).
    public var loopbackProbes: [ProbeRecord] = []
    /// The dpkg status database, if one was readable.
    public var packageDatabase: String?
    /// Attempts to read the dpkg status database under each root.
    public var packageDatabaseProbes: [ProbeRecord] = []
    /// Prefix reported by a jailbreak-provided resolver already present in this process.
    public var resolverPrefix: String?
    /// When the scan ran.
    public var scannedAt = Date()

    /// Whether any bootstrap root exists (not that anything in it is usable).
    public var environmentVisible: Bool {
        environmentPrefix != nil || !executableDirectories.isEmpty || !shells.isEmpty
            || roots.contains { !$0.path.isEmpty && $0.probe == .present }
    }

    /// Paths the system refused to let this app inspect.
    public var deniedPaths: [String] {
        pathProbes.filter { $0.value.isDenied }.map(\.key).sorted()
    }

    /// Locations this app could list, read or write (browsable ones are the listable ones).
    public var permittedLocations: [LocationAccess] { locations.filter { $0.listable || $0.readable || $0.writable } }

    /// Shell candidates worth an explicit launch attempt, best first: executable ones, then
    /// existing files whose `access(X_OK)` the sandbox refused.
    public var launchableShells: [String] {
        let preferred = shellCandidates.filter { $0.state == .executable }
        let denied = shellCandidates.filter { $0.state != .executable && $0.state.launchCandidate }
        return (preferred + denied).map(\.path)
    }

    /// Directories to put on PATH for spawned shells, in priority order.
    public var searchPath: [String] {
        let prefix = environmentPrefix ?? ""
        var paths = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"].map { prefix + $0 }
        if !prefix.isEmpty { paths += ["/usr/sbin", "/usr/bin", "/sbin", "/bin"] }
        var unique: [String] = []
        for path in paths where !unique.contains(path) { unique.append(path) }
        return unique
    }
}

/// Performs the read-only Unleashed scan: stat/lstat/readlink/realpath/access, directory
/// listings, reading one byte of a file, a sysctl read and loopback TCP connects without data.
/// It never writes, never executes anything and never loads code.
public struct UnleashedEnvironmentScanner: Sendable {
    /// Fixed candidate prefixes: rootless, then the system root (rootful). Relocated roots and
    /// roots the user entered are added at scan time.
    public static let prefixes = ["/var/jb", ""]
    /// Where relocated rootless bootstraps live (e.g. `/private/preboot/<UUID>/jb-XXXX/procursus`
    /// or `…/dopamine-XXXX/procursus`). Only listed if the system allows it.
    public static let prebootDirectory = "/private/preboot"
    public static let relocatedNamePrefixes = ["jb-", "dopamine-"]
    /// Roothide-style roots: `/var/containers/Bundle/Application/.jbroot-XXXX`.
    public static let roothideDirectory = "/var/containers/Bundle/Application"
    /// Files a bootstrap creates. Relative to a root.
    public static let strongIndicators = [".procursus_strapped", ".installed_dopamine", ".bootstrapped", "var/lib/dpkg/status", "etc/apt/sources.list.d"]
    /// Common but not conclusive (an app bundle can exist without a working userland).
    public static let weakIndicators = ["Applications/Sileo.app", "Applications/Zebra.app", "Applications/Cydia.app", "Applications/Filza.app"]
    public static let packageToolNames = ["apt", "apt-get", "dpkg", "dpkg-query"]
    public static let elevationToolNames = ["sudo", "su"]
    public static let loopbackPorts = [22, 2222]
    /// Locations outside the sandbox. Root-relative entries are added for every bootstrap root.
    public static let systemLocations = [
        "/var/mobile", "/var/mobile/Documents", "/var/mobile/Library/Logs", "/var/log", "/private/var/tmp", "/tmp", "/etc",
        "/Applications", "/var/containers/Bundle/Application",
    ]
    public static let rootLocations = ["", "/etc", "/var/log", "/var/lib/dpkg", "/Applications", "/var/mobile"]

    private let probe: any SystemProbing
    /// Bootstrap roots the user entered (Settings → Unleashed environment). Probed read-only
    /// like the built-in candidates; never trusted without evidence.
    private let customRoots: @Sendable () -> [String]
    /// A jailbreak-provided prefix resolver, if one is already present in this process.
    private let prefixResolver: @Sendable () -> String?

    public init(
        probe: any SystemProbing,
        customRoots: @escaping @Sendable () -> [String] = { [] },
        prefixResolver: @escaping @Sendable () -> String? = { JailbreakPrefixResolver.prefixFromLoadedResolver() }
    ) {
        self.probe = probe
        self.customRoots = customRoots
        self.prefixResolver = prefixResolver
    }

    /// Finds candidate bootstrap roots: a prefix reported by a loaded resolver, `/var/jb` (and
    /// where it really points), relocated and roothide roots when listable, user-entered roots,
    /// and the system root.
    func candidateRoots(pathProbes: inout [String: PathProbe], resolverPrefix: String?) -> [EnvironmentAssessment.Root] {
        var roots: [EnvironmentAssessment.Root] = []
        var seen: Set<String> = []
        func add(_ path: String, _ layout: EnvironmentAssessment.Layout) {
            let result = probe.probe(path.isEmpty ? "/" : path)
            if result != .missing { pathProbes[path.isEmpty ? "/" : path] = result }
            let resolved = result == .present ? probe.resolvedPath(path.isEmpty ? "/" : path) : nil
            let key = resolved ?? path
            guard !seen.contains(key) || path.isEmpty else { return }
            seen.insert(key)
            roots.append(EnvironmentAssessment.Root(path: path, resolvedPath: resolved, layout: layout, probe: result))
        }
        if let resolverPrefix, resolverPrefix.hasPrefix("/"), resolverPrefix != "/" {
            add(resolverPrefix.hasSuffix("/") ? String(resolverPrefix.dropLast()) : resolverPrefix, .relocated)
        }
        add("/var/jb", .rootless)
        switch probe.listing(Self.prebootDirectory) {
        case .success(let volumes):
            for volume in volumes.sorted().prefix(16) {
                let volumePath = Self.prebootDirectory + "/" + volume
                guard case .success(let entries) = probe.listing(volumePath) else { continue }
                for entry in entries.sorted().prefix(32) where Self.relocatedNamePrefixes.contains(where: entry.hasPrefix) {
                    let candidate = volumePath + "/" + entry + "/procursus"
                    if probe.isDirectory(candidate) { add(candidate, .relocated) }
                }
            }
        case .failure(let failure):
            if failure.probe != .missing { pathProbes[Self.prebootDirectory] = failure.probe }
        }
        if case .success(let entries) = probe.listing(Self.roothideDirectory) {
            for entry in entries.sorted().prefix(64) where entry.hasPrefix(".jbroot-") {
                add(Self.roothideDirectory + "/" + entry, .relocated)
            }
        }
        for custom in customRoots() {
            let trimmed = custom.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/"), trimmed != "/" else { continue }
            add(trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed, .custom)
        }
        add("", .rootful)
        return roots
    }

    public func scan() -> UnleashedEnvironmentScan {
        var evidence: [CapabilityEvidence] = []
        var pathProbes: [String: PathProbe] = [:]
        let resolverPrefix = prefixResolver()
        let roots = candidateRoots(pathProbes: &pathProbes, resolverPrefix: resolverPrefix)
        evidence.append(CapabilityEvidence(
            probe: "jailbreak prefix resolver (already loaded in this process)",
            observation: resolverPrefix.map { "reported \($0)" } ?? "not present in this process; using path candidates",
            positive: resolverPrefix != nil
        ))

        // Indicators: context only, never decisive.
        var indicators: [EnvironmentAssessment.Indicator] = []
        for root in roots where root.layout == .rootful || root.probe == .present {
            for (names, strength) in [(Self.strongIndicators, EnvironmentAssessment.Indicator.Strength.strong), (Self.weakIndicators, .weak)] {
                for name in names {
                    if name == ".bootstrapped" && root.layout != .rootful { continue }
                    let path = root.path + "/" + name
                    let result = probe.probe(path)
                    if result != .missing { pathProbes[path] = result }
                    indicators.append(EnvironmentAssessment.Indicator(path: path, layout: root.layout, strength: strength, probe: result))
                }
            }
        }

        // Roots to search for programs: every existing non-system root, then the system root.
        let programRoots = roots.filter { !$0.path.isEmpty && $0.probe == .present }.map(\.path) + [""]
        let resolver = ToolResolver(probe: probe)

        // Every concrete shell path, each resolved and recorded.
        let shellCandidates = ToolResolver.paths(names: ToolResolver.shellNames, roots: programRoots, directories: ToolResolver.shellDirectories)
            .map { resolver.resolve($0.path, name: $0.name) }
        let toolCandidates = ToolResolver.paths(names: Self.packageToolNames + Self.elevationToolNames, roots: programRoots, directories: ToolResolver.toolDirectories)
            .map { resolver.resolve($0.path, name: $0.name) }

        // Program folders: listing them, recorded with errno.
        var listings: [ProbeRecord] = []
        var directories: [String: Int] = [:]
        for root in programRoots {
            for directory in ToolResolver.toolDirectories {
                let path = root + "/" + directory
                let (record, names) = probe.listRecord(path)
                if record.showsAbsence && root.isEmpty == false { continue }
                listings.append(record)
                if record.showsDenial { pathProbes[path] = .denied(record.errorCode ?? EPERM) }
                if let names {
                    let executables = names.prefix(4000).filter { probe.isExecutableFile(path + "/" + $0) }.count
                    if executables > 0 { directories[path] = executables }
                }
            }
        }

        // Locations outside the sandbox: list, read one file, ask about writing. Separate facts.
        var locationPaths = Self.systemLocations
        for root in programRoots where !root.isEmpty {
            locationPaths.append(contentsOf: Self.rootLocations.map { root + $0 })
        }
        var uniqueLocations: [String] = []
        for path in locationPaths where !uniqueLocations.contains(path) { uniqueLocations.append(path) }
        var locationProbes: [LocationProbe] = []
        var locations: [LocationAccess] = []
        for path in uniqueLocations {
            let (listing, names) = probe.listRecord(path)
            if listing.showsAbsence { continue }
            if listing.showsDenial { pathProbes[path] = pathProbes[path] ?? .denied(listing.errorCode ?? EPERM) }
            var fileRead: ProbeRecord?
            if let names {
                // Read one byte of the first regular file (prefer small, well-known files).
                let preferred = ["status", "passwd", "hosts", "apt.conf"].filter(names.contains) + names.sorted()
                for name in preferred.prefix(12) {
                    let file = path + "/" + name
                    let info = probe.statRecord(file)
                    if info.succeeded, info.detail.hasPrefix(ProbedFileType.regular) {
                        fileRead = probe.readRecord(file)
                        break
                    }
                }
            }
            let write = probe.accessRecord(path, mode: W_OK)
            locationProbes.append(LocationProbe(path: path, listing: listing, fileRead: fileRead, writeCheck: write))
            locations.append(LocationAccess(
                path: path, exists: true, readable: fileRead?.succeeded ?? false,
                listable: listing.succeeded, writable: write.succeeded
            ))
        }

        // Package database (read-only; parsed for the inventory without running apt).
        var packageDatabase: String?
        var databaseProbes: [ProbeRecord] = []
        for root in programRoots {
            let path = root + "/var/lib/dpkg/status"
            let record = probe.readRecord(path)
            databaseProbes.append(record)
            if record.succeeded { packageDatabase = path; break }
        }

        let loopback = Self.loopbackPorts.map { probe.loopbackRecord($0, timeout: 0.3) }
        let ports = loopback.filter(\.succeeded).compactMap { Int($0.path.split(separator: ":").last ?? "") }

        let processCount = probe.visibleProcessCount()
        evidence.append(CapabilityEvidence(probe: "sysctl(KERN_PROC_ALL)", observation: processCount.map { "\($0) visible" } ?? "refused", positive: (processCount ?? 0) > 1, timestamp: Date()))
        let euid = probe.effectiveUserID()
        evidence.append(CapabilityEvidence(probe: "geteuid()", observation: "\(euid)", positive: euid == 0, timestamp: Date()))

        let shells = shellCandidates.filter { $0.state == .executable }.map(\.path)
        func tools(_ names: [String]) -> [DetectedTool] {
            toolCandidates.filter { names.contains($0.name) && $0.state == .executable }.map { DetectedTool(name: $0.name, path: $0.path) }
        }
        var resolvedTools: [String: String] = [:]
        for candidate in shellCandidates + toolCandidates where candidate.state == .executable && resolvedTools[candidate.name] == nil {
            resolvedTools[candidate.name] = candidate.resolvedPath ?? candidate.path
        }
        let firstShellRoot = shellCandidates.first { $0.state.exists }.map { candidate in
            programRoots.first { !$0.isEmpty && candidate.path.hasPrefix($0 + "/") } ?? ""
        }

        return UnleashedEnvironmentScan(
            environmentPrefix: firstShellRoot ?? (roots.contains { $0.layout == .rootless && $0.probe == .present } ? "/var/jb" : nil),
            shells: shells,
            executableDirectories: directories,
            packageManagers: tools(Self.packageToolNames),
            elevationTools: tools(Self.elevationToolNames),
            effectiveUserID: euid,
            loopbackServicePorts: ports,
            visibleProcessCount: processCount,
            locations: locations,
            evidence: evidence,
            operatingSystem: probe.osDescription(),
            pathProbes: pathProbes,
            roots: roots,
            indicators: indicators,
            resolvedTools: resolvedTools,
            shellCandidates: shellCandidates,
            toolCandidates: toolCandidates,
            programFolderListings: listings,
            locationProbes: locationProbes,
            loopbackProbes: loopback,
            packageDatabase: packageDatabase,
            packageDatabaseProbes: databaseProbes,
            resolverPrefix: resolverPrefix
        )
    }
}

/// Asks a jailbreak-provided prefix resolver for the bootstrap root, but only if one is already
/// loaded in this process (e.g. injected by the jailbreak). Nothing is loaded from disk.
public enum JailbreakPrefixResolver {
    public static func prefixFromLoadedResolver() -> String? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        for symbol in ["libroot_dyn_get_jbroot_prefix", "libroot_get_jbroot_prefix"] {
            guard let address = dlsym(handle, symbol) else { continue }
            typealias Function = @convention(c) () -> UnsafePointer<CChar>?
            let function = unsafeBitCast(address, to: Function.self)
            if let value = function() {
                let prefix = String(cString: value)
                return prefix.isEmpty ? nil : prefix
            }
        }
        return nil
    }
}

/// Outcomes observed when the user actually used a capability. Detection never executes
/// anything; these observations let the report move from "detected" to "verified" (or to the
/// real error) after explicit use. Each has a timestamp so stale results can be recognised.
public actor RuntimeObservations {
    public enum SpawnOutcome: Hashable, Sendable {
        case succeeded(pid: Int32)
        /// `errno` is 0 when the failure was not a spawn error (e.g. no pseudo-terminal).
        case failed(errno: Int32, message: String)
    }

    public struct Observation: Hashable, Sendable {
        public var outcome: SpawnOutcome
        public var date: Date
    }

    private var spawns: [String: Observation] = [:]
    private var loopbackSignIns: [String: Date] = [:]
    private var writes: [String: Date] = [:]

    /// A file was written and removed (or saved) in `directory` by an explicit action.
    public func recordWrite(in directory: String, at date: Date = Date()) { writes[directory] = date }
    public func verifiedWrites() -> [String: Date] { writes }

    public init() {}

    public func record(executable: String, outcome: SpawnOutcome, at date: Date = Date()) {
        spawns[executable] = Observation(outcome: outcome, date: date)
    }

    public func outcome(for executable: String) -> SpawnOutcome? { spawns[executable]?.outcome }
    public func observation(for executable: String) -> Observation? { spawns[executable] }
    public func allObservations() -> [String: Observation] { spawns }

    public func anySucceeded() -> Bool {
        spawns.values.contains { if case .succeeded = $0.outcome { true } else { false } }
    }

    /// A successful SSH sign-in with a PTY on this device's loopback service.
    public func recordLoopbackSignIn(_ endpoint: String, at date: Date = Date()) { loopbackSignIns[endpoint] = date }
    public func loopbackSignIn() -> (String, Date)? { loopbackSignIns.max { $0.value < $1.value }.map { ($0.key, $0.value) } }

    /// Forgets results (used by "Recheck"; a new test produces fresh ones).
    public func reset() {
        spawns.removeAll()
    }
}
