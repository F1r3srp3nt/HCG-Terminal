import Foundation
import TerminalCapabilityProvider
import TerminalCore

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

/// Everything the read-only scan observed. No field is inferred from another: each one
/// comes from its own probe, and each probe is recorded as evidence.
public struct UnleashedEnvironmentScan: Hashable, Sendable {
    /// `/var/jb` for a rootless layout, `""` when tools live at the system root, `nil` if none.
    public var environmentPrefix: String?
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

    /// Whether the app can see any part of a shell environment at all (a jailbreak prefix, or a
    /// listable directory with executables). False on a standard, sandboxed iOS install.
    public var environmentVisible: Bool {
        environmentPrefix != nil || !executableDirectories.isEmpty || !shells.isEmpty
    }

    /// Paths the system refused to let this app inspect.
    public var deniedPaths: [String] {
        pathProbes.filter { $0.value.isDenied }.map(\.key).sorted()
    }

    public var permittedLocations: [LocationAccess] { locations.filter { $0.readable || $0.writable } }

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

/// Performs the read-only Unleashed scan. Uses only `SystemProbing` (stat, access, directory
/// listing, a sysctl read and loopback TCP connects without sending data).
public struct UnleashedEnvironmentScanner: Sendable {
    /// Fixed candidate prefixes: rootless, then the system root (rootful). Relocated roots and
    /// roots the user entered are added at scan time.
    public static let prefixes = ["/var/jb", ""]
    /// Where relocated rootless bootstraps live (e.g. `/private/preboot/<UUID>/jb-XXXX/procursus`
    /// or `…/dopamine-XXXX/procursus`). Only listed if the system allows it.
    public static let prebootDirectory = "/private/preboot"
    public static let relocatedNamePrefixes = ["jb-", "dopamine-"]
    /// Files a bootstrap creates. Relative to a root.
    public static let strongIndicators = [".procursus_strapped", ".installed_dopamine", ".bootstrapped", "var/lib/dpkg/status", "etc/apt/sources.list.d"]
    /// Common but not conclusive (an app bundle can exist without a working userland).
    public static let weakIndicators = ["Applications/Sileo.app", "Applications/Zebra.app", "Applications/Cydia.app", "Applications/Filza.app"]
    public static let shellCandidates = ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh", "/bin/dash"]
    public static let binDirectories = ["/usr/bin", "/bin", "/usr/local/bin", "/usr/sbin", "/sbin"]
    public static let packageManagerCandidates = [("apt", "/usr/bin/apt"), ("apt-get", "/usr/bin/apt-get"), ("dpkg", "/usr/bin/dpkg"), ("dpkg-query", "/usr/bin/dpkg-query")]
    public static let elevationCandidates = [("sudo", "/usr/bin/sudo"), ("su", "/usr/bin/su"), ("su", "/bin/su")]
    public static let loopbackPorts = [22, 2222]
    public static let locationCandidates = [
        "/var/mobile", "/var/mobile/Documents", "/var/mobile/Library/Logs", "/var/jb", "/var/jb/etc",
        "/var/jb/var/log", "/var/log", "/private/var/tmp", "/tmp", "/etc", "/Applications",
        "/var/containers/Bundle/Application",
    ]

    private let probe: any SystemProbing
    /// Bootstrap roots the user entered (Settings → Unleashed environment). Probed read-only
    /// like the built-in candidates; never trusted without evidence.
    private let customRoots: @Sendable () -> [String]

    public init(probe: any SystemProbing, customRoots: @escaping @Sendable () -> [String] = { [] }) {
        self.probe = probe
        self.customRoots = customRoots
    }

    /// Finds candidate bootstrap roots: `/var/jb` (and where it really points), relocated roots
    /// under /private/preboot when listable, user-entered roots, and the system root.
    func candidateRoots(pathProbes: inout [String: PathProbe]) -> [EnvironmentAssessment.Root] {
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
        let roots = candidateRoots(pathProbes: &pathProbes)
        var indicators: [EnvironmentAssessment.Indicator] = []
        for root in roots where root.layout == .rootful || root.probe == .present {
            for (names, strength) in [(Self.strongIndicators, EnvironmentAssessment.Indicator.Strength.strong), (Self.weakIndicators, .weak)] {
                for name in names {
                    // `.bootstrapped` only means something at the system root (rootful).
                    if name == ".bootstrapped" && root.layout != .rootful { continue }
                    let path = root.path + "/" + name
                    let result = probe.probe(path)
                    if result != .missing { pathProbes[path] = result }
                    indicators.append(EnvironmentAssessment.Indicator(path: path, layout: root.layout, strength: strength, probe: result))
                }
            }
        }
        for indicator in indicators where indicator.probe != .missing {
            evidence.append(CapabilityEvidence(probe: "lstat(\(indicator.path))", observation: indicator.probe.description + (indicator.strength == .weak ? " (weak indicator)" : ""), positive: indicator.probe == .present))
        }
        let prefixes = roots.filter { $0.layout != .rootful && $0.probe == .present }.map(\.path) + [""]
        // Layout indicator (context only — never decisive on its own).
        let jbProbe = probe.probe("/var/jb")
        pathProbes["/var/jb"] = jbProbe
        let rootlessPrefix = jbProbe == .present && probe.isDirectory("/var/jb")
        evidence.append(CapabilityEvidence(probe: "lstat(/var/jb)", observation: rootlessPrefix ? "directory present" : jbProbe.description, positive: rootlessPrefix))
        for path in ["/usr/bin", "/bin"] {
            let result = probe.probe(path)
            pathProbes[path] = result
            evidence.append(CapabilityEvidence(probe: "lstat(\(path))", observation: result.description, positive: result == .present))
        }

        var shells: [String] = []
        var directories: [String: Int] = [:]
        var packageManagers: [DetectedTool] = []
        var elevation: [DetectedTool] = []
        var prefixWithTools: String?

        for prefix in prefixes {
            for candidate in Self.shellCandidates {
                let path = prefix + candidate
                guard !shells.contains(path) else { continue }
                if probe.isExecutableFile(path) {
                    shells.append(path)
                    if prefixWithTools == nil { prefixWithTools = prefix }
                    evidence.append(CapabilityEvidence(probe: "access(\(path), X_OK)", observation: "executable", positive: true))
                } else {
                    let result = probe.probe(path)
                    if result != .missing { pathProbes[path] = result }
                }
            }
            for directory in Self.binDirectories {
                let path = prefix + directory
                guard directories[path] == nil else { continue }
                let entries: [String]
                switch probe.listing(path) {
                case .success(let names): entries = names
                case .failure(let failure):
                    if failure.probe != .missing {
                        pathProbes[path] = failure.probe
                        evidence.append(CapabilityEvidence(probe: "list \(path)", observation: failure.probe.description, positive: false))
                    }
                    continue
                }
                let executables = entries.prefix(4000).filter { probe.isExecutableFile(path + "/" + $0) }.count
                if executables > 0 {
                    directories[path] = executables
                    evidence.append(CapabilityEvidence(probe: "list \(path)", observation: "\(executables) executables", positive: true))
                }
            }
            for (name, candidate) in Self.packageManagerCandidates where probe.isExecutableFile(prefix + candidate) {
                if !packageManagers.contains(where: { $0.path == prefix + candidate }) {
                    packageManagers.append(DetectedTool(name: name, path: prefix + candidate))
                    evidence.append(CapabilityEvidence(probe: "access(\(prefix + candidate), X_OK)", observation: "executable", positive: true))
                }
            }
            for (name, candidate) in Self.elevationCandidates where probe.isExecutableFile(prefix + candidate) {
                if !elevation.contains(where: { $0.path == prefix + candidate }) {
                    elevation.append(DetectedTool(name: name, path: prefix + candidate))
                }
            }
        }
        if shells.isEmpty {
            evidence.append(CapabilityEvidence(probe: "access(<\(Self.shellCandidates.count * Self.prefixes.count) shell candidates>, X_OK)", observation: "no executable shell found", positive: false))
        }

        let ports = Self.loopbackPorts.filter { probe.loopbackPortAccepts($0, timeout: 0.3) }
        for port in Self.loopbackPorts {
            let accepted = ports.contains(port)
            evidence.append(CapabilityEvidence(probe: "TCP connect 127.0.0.1:\(port) (no data sent)", observation: accepted ? "accepted" : "refused or filtered", positive: accepted))
        }

        let processCount = probe.visibleProcessCount()
        evidence.append(CapabilityEvidence(probe: "sysctl(KERN_PROC_ALL)", observation: processCount.map { "\($0) visible" } ?? "not permitted", positive: (processCount ?? 0) > 1))

        let euid = probe.effectiveUserID()
        evidence.append(CapabilityEvidence(probe: "geteuid()", observation: "\(euid)", positive: euid == 0))

        let locations = Self.locationCandidates.map { path -> LocationAccess in
            let result = probe.probe(path)
            if result != .missing { pathProbes[path] = pathProbes[path] ?? result }
            let exists = result == .present
            return LocationAccess(
                path: path,
                exists: exists,
                readable: exists && probe.isReadable(path),
                listable: exists && probe.listDirectory(path) != nil,
                writable: exists && probe.isWritable(path)
            )
        }

        var resolvedTools: [String: String] = [:]
        for shell in shells { resolvedTools[(shell as NSString).lastPathComponent] = resolvedTools[(shell as NSString).lastPathComponent] ?? (probe.resolvedPath(shell) ?? shell) }
        for tool in packageManagers + elevation where resolvedTools[tool.name] == nil {
            resolvedTools[tool.name] = probe.resolvedPath(tool.path) ?? tool.path
        }

        return UnleashedEnvironmentScan(
            environmentPrefix: prefixWithTools ?? (rootlessPrefix ? "/var/jb" : nil),
            shells: shells,
            executableDirectories: directories,
            packageManagers: packageManagers,
            elevationTools: elevation,
            effectiveUserID: euid,
            loopbackServicePorts: ports,
            visibleProcessCount: processCount,
            locations: locations,
            evidence: evidence,
            operatingSystem: probe.osDescription(),
            pathProbes: pathProbes,
            roots: roots,
            indicators: indicators,
            resolvedTools: resolvedTools
        )
    }
}

/// Outcomes observed when the user actually used a capability. Detection never executes
/// anything; these observations let the report move from "detected" to "verified" (or to
/// "unavailable" with the real error) after explicit use.
public actor RuntimeObservations {
    public enum SpawnOutcome: Hashable, Sendable {
        case succeeded(pid: Int32)
        /// `errno` is 0 when the failure was not a spawn error (e.g. no pseudo-terminal).
        case failed(errno: Int32, message: String)
    }

    private var spawns: [String: SpawnOutcome] = [:]

    public init() {}

    public func record(executable: String, outcome: SpawnOutcome) {
        spawns[executable] = outcome
    }

    public func outcome(for executable: String) -> SpawnOutcome? { spawns[executable] }

    public func anySucceeded() -> Bool {
        spawns.values.contains { if case .succeeded = $0 { true } else { false } }
    }
}
