import Diagnostics
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Creates Local Unleashed sessions. This module is linked only by the Unleashed app target;
/// the standard (Vanilla) build uses `UnleashedNotIncludedCapabilityProvider` instead.
public struct UnleashedExecutionProvider: LocalExecutionProvider {
    public let mode: ExecutionMode = .unleashed
    public let capabilities: UnleashedCapabilityProvider
    public let observations: RuntimeObservations
    public let gate: AuthorizationGate
    public let access: AccessPolicy

    public init(capabilities: UnleashedCapabilityProvider, observations: RuntimeObservations, gate: AuthorizationGate, access: AccessPolicy = .shared) {
        self.capabilities = capabilities
        self.observations = observations
        self.gate = gate
        self.access = access
    }

    public func availableBackend() async -> SessionBackend? {
        let scan = capabilities.scan()
        if let shell = scan.shells.first {
            if case .failed? = await observations.outcome(for: shell) {
                return scan.loopbackServicePorts.first.map { .loopbackService(host: "127.0.0.1", port: $0) }
            }
            return .localProcess(executable: shell)
        }
        return scan.loopbackServicePorts.first.map { .loopbackService(host: "127.0.0.1", port: $0) }
    }

    /// Creates a direct process session. Loopback terminal services are opened through
    /// RemoteSSH by the interface layer (with target Local Unleashed), because they need
    /// the service's own credentials.
    public func makeSession() async throws -> any TerminalSession {
        try access.require(.localShell)
        let scan = capabilities.scan()
        guard let shell = scan.shells.first else {
            throw ExecutionError.modeUnavailable(.unleashed, reason: "No local shell can be started in this environment.")
        }
        if case .failed(_, let message)? = await observations.outcome(for: shell) {
            throw ExecutionError.modeUnavailable(.unleashed, reason: message)
        }
        return LocalProcessSession(
            executable: shell,
            environment: Self.environment(for: scan, shell: shell),
            workingDirectory: Self.homeDirectory(scan: scan),
            observations: observations,
            gate: gate,
            access: access
        )
    }

    static func homeDirectory(scan: UnleashedEnvironmentScan) -> String? {
        if let home = ProcessInfo.processInfo.environment["HOME"], FileManager.default.fileExists(atPath: home) {
            // Inside an iOS app this is the app container; prefer the mobile user's home when readable.
            if let mobile = scan.locations.first(where: { $0.path == "/var/mobile" && $0.listable }) { return mobile.path }
            return home
        }
        return scan.locations.first(where: { $0.path == "/var/mobile" && $0.listable })?.path
    }

    /// A minimal, explicit environment for spawned shells. Nothing secret is passed.
    public static func environment(for scan: UnleashedEnvironmentScan, shell: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": scan.searchPath.joined(separator: ":"),
            "SHELL": shell,
            "HCG_TERMINAL_MODE": "unleashed",
        ]
        if let home = homeDirectory(scan: scan) { environment["HOME"] = home }
        if let user = inherited["USER"] ?? inherited["LOGNAME"] { environment["USER"] = user }
        if let tmp = inherited["TMPDIR"] { environment["TMPDIR"] = tmp }
        return environment
    }
}

// MARK: - Package management

public struct InstalledPackage: Hashable, Sendable, Identifiable {
    public var name: String
    public var version: String
    public var status: String
    public var id: String { name }
}

public enum PackageAction: Hashable, Sendable {
    case install(String)
    case remove(String)
    case refreshIndexes

    public var title: String {
        switch self {
        case .install(let name): "Install \(name)"
        case .remove(let name): "Remove \(name)"
        case .refreshIndexes: "Refresh package lists"
        }
    }
}

public enum PackageManagerError: Error, LocalizedError, Equatable {
    case notAvailable
    case invalidPackageName(String)
    case declined
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable: "No supported package manager was found."
        case .invalidPackageName(let name): "“\(name)” is not a valid package name."
        case .declined: "Not run: authorization was declined."
        case .failed(let message): message
        }
    }
}

/// Interacts with apt/dpkg exactly as installed. Listing is read-only. Changes are never run
/// automatically: `authorizedCommand(for:)` returns a command line only after the user
/// explicitly approves it, and the interface runs it in a visible Local Unleashed session so
/// any password prompt from the tools themselves is shown to the user.
public struct PackageManagerClient: Sendable {
    public let scan: UnleashedEnvironmentScan
    private let gate: AuthorizationGate
    private let access: AccessPolicy

    public init(scan: UnleashedEnvironmentScan, gate: AuthorizationGate, access: AccessPolicy = .shared) {
        self.scan = scan
        self.gate = gate
        self.access = access
    }

    public var isAvailable: Bool { !scan.packageManagers.isEmpty }

    private func tool(_ name: String) -> DetectedTool? { scan.packageManagers.first { $0.name == name } }

    public func listInstalled() async throws -> [InstalledPackage] {
        try access.require(.packageManagement)
        guard let query = tool("dpkg-query") ?? tool("dpkg") else { throw PackageManagerError.notAvailable }
        let arguments = query.name == "dpkg-query"
            ? ["-W", "-f", "${Package}\\t${Version}\\t${db:Status-Abbrev}\\n"]
            : ["-l"]
        let result = try await ProcessRunner.run(
            executable: query.path, arguments: arguments,
            environment: ["PATH": scan.searchPath.joined(separator: ":"), "LANG": "C"]
        )
        guard result.status == 0 else { throw PackageManagerError.failed(result.stderrText.isEmpty ? "exit \(result.status)" : result.stderrText) }
        if query.name == "dpkg-query" {
            return result.stdoutText.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3 else { return nil }
                return InstalledPackage(name: fields[0], version: fields[1], status: fields[2].trimmingCharacters(in: .whitespaces))
            }
        }
        return result.stdoutText.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, fields[0].count == 2 else { return nil }
            return InstalledPackage(name: fields[1], version: fields[2], status: fields[0])
        }
    }

    public static func isValidPackageName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first), name.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-.")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The command line for an action, exactly as it would be typed. No `sudo` is added.
    public func commandLine(for action: PackageAction) throws -> String {
        guard let apt = tool("apt-get") ?? tool("apt") else { throw PackageManagerError.notAvailable }
        switch action {
        case .install(let name), .remove(let name):
            guard Self.isValidPackageName(name) else { throw PackageManagerError.invalidPackageName(name) }
            let verb = if case .install = action { "install" } else { "remove" }
            return "\(apt.path) \(verb) \(name)"
        case .refreshIndexes:
            return "\(apt.path) update"
        }
    }

    /// Asks the user. Returns the command line only if they explicitly approved it.
    public func authorizedCommand(for action: PackageAction) async throws -> String {
        try access.require(.packageManagement)
        let command = try commandLine(for: action)
        let request = AuthorizationRequest(
            title: action.title,
            commandLine: command,
            target: .local(.unleashed),
            reasons: ["Changes installed packages on this device.", "Runs with the permissions the device grants to this app; apt may refuse without root."],
            requiredAccess: [.packageManagement]
        )
        switch await gate.decide(request) {
        case .approved: break
        case .declined: throw PackageManagerError.declined
        case .refused(let denied): throw denied
        }
        await DiagnosticLog.shared.record(.notice, "packages", "Package action authorized", metadata: ["action": action.title])
        return command
    }
}

// MARK: - Permitted locations and logs

public enum LocationBrowserError: Error, LocalizedError, Equatable {
    case notPermitted(String)
    case unreadable(String)
    case notWritable(String, String)
    case approvalDeclined(String)
    case alreadyExists(String)
    case invalidName(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let path): "\(path) is not inside a location this device lets HCG Terminal access."
        case .unreadable(let path): "\(path) could not be read."
        case .notWritable(let path, let reason): "\(path) is not writable for this app (\(reason)). HCG Terminal does not change permissions."
        case .approvalDeclined(let path): "Not changed: approval for \(path) was declined."
        case .alreadyExists(let name): "“\(name)” already exists."
        case .invalidName(let name): "“\(name)” is not a valid name."
        case .failed(let path, let reason): "\(path): \(reason)"
        }
    }
}

public struct HostFileEntry: Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var writable: Bool
    public var id: String { path }
}

/// Filesystem access outside the app sandbox, limited to the locations the read-only scan found
/// listable. Reads and writes run with the app's actual permissions:
/// - every path is resolved (symlinks included) and must stay inside a permitted location;
/// - writes require `access(W_OK)` on the target directory at the moment of writing;
/// - writes under protected system or jailbreak locations need explicit approval each time;
/// - nothing ever uses sudo, changes permissions or remounts anything.
public struct HostFileSystem: Sendable {
    public let roots: [String]
    private let gate: AuthorizationGate?
    /// Which paths need approval before a change. Defaults to system and jailbreak locations.
    private let needsApproval: @Sendable (String) -> Bool
    private let access: AccessPolicy

    public init(scan: UnleashedEnvironmentScan, gate: AuthorizationGate? = nil, access: AccessPolicy = .shared) {
        self.init(roots: scan.permittedLocations.filter(\.listable).map(\.path), gate: gate, access: access)
    }

    public init(
        roots: [String], gate: AuthorizationGate?,
        needsApproval: @escaping @Sendable (String) -> Bool = HostFileSystem.requiresApproval,
        access: AccessPolicy = .shared
    ) {
        self.roots = roots.map { Self.resolve($0) }
        self.gate = gate
        self.needsApproval = needsApproval
        self.access = access
    }

    /// Whether reading / writing is allowed by the user's switches (not by the device).
    public var readEnabled: Bool { access.isEnabled(.expandedFileRead) }
    public var writeEnabled: Bool { access.isEnabled(.expandedFileWrite) }

    public static let logDirectories = ["/var/log", "/private/var/log", "/var/jb/var/log", "/var/mobile/Library/Logs", "/var/mobile/Library/Logs/CrashReporter"]

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).standardizingPath).resolvingSymlinksInPath().path
    }

    /// Resolves `path` (and, for a new item, its parent) and checks it stays inside a root.
    func check(_ path: String) throws -> String {
        let standardized = (path as NSString).standardizingPath
        let exists = FileManager.default.fileExists(atPath: standardized)
        let resolved = exists
            ? Self.resolve(standardized)
            : (Self.resolve((standardized as NSString).deletingLastPathComponent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
        guard roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else {
            throw LocationBrowserError.notPermitted(path)
        }
        return resolved
    }

    /// Whether a change at `path` needs explicit approval (system and jailbreak locations).
    public static func requiresApproval(_ path: String) -> Bool {
        PrivilegeClassifier.assess("rm \(path)").requiresAuthorization
    }

    /// Writable for this app right now: the write switch is on and `access(W_OK)` succeeds.
    public func isWritable(_ path: String) -> Bool {
        guard writeEnabled, let resolved = try? check(path) else { return false }
        return posixAccess(resolved, W_OK) == 0
    }

    public func list(_ path: String) throws -> [HostFileEntry] {
        try access.require(.expandedFileRead)
        let directory = try check(path)
        let canWrite = writeEnabled
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory) } catch {
            throw LocationBrowserError.unreadable(directory)
        }
        return names.sorted().map { name in
            let full = (directory as NSString).appendingPathComponent(name)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
            return HostFileEntry(
                path: full, name: name,
                isDirectory: (attributes[.type] as? FileAttributeType) == .typeDirectory,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attributes[.modificationDate] as? Date,
                writable: canWrite && posixAccess(full, W_OK) == 0
            )
        }
    }

    /// Reads at most `maxBytes` from the end of a file (log inspection).
    public func readTail(_ path: String, maxBytes: Int = 256 * 1024) throws -> String {
        try access.require(.expandedFileRead)
        let file = try check(path)
        guard let handle = FileHandle(forReadingAtPath: file) else { throw LocationBrowserError.unreadable(file) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public func readText(_ path: String, limit: Int = 2 * 1024 * 1024) throws -> String {
        try access.require(.expandedFileRead)
        let file = try check(path)
        guard let handle = FileHandle(forReadingAtPath: file) else { throw LocationBrowserError.unreadable(file) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { throw LocationBrowserError.unreadable("\(file) (not UTF-8 text)") }
        return text
    }

    // MARK: Writing

    func authorizeChange(_ title: String, path: String, command: String) async throws {
        guard needsApproval(path) else { return }
        guard let gate else { throw LocationBrowserError.approvalDeclined(path) }
        let request = AuthorizationRequest(
            title: title, commandLine: command, target: .local(.unleashed),
            reasons: ["\(path) is a system or jailbreak location; changing it can break the device's environment.", "Runs with this app's own permissions; nothing is elevated."],
            requiredAccess: [.expandedFileWrite]
        )
        switch await gate.decide(request) {
        case .approved: return
        case .declined: throw LocationBrowserError.approvalDeclined(path)
        case .refused(let denied): throw denied
        }
    }

    func requireWritableDirectory(_ directory: String) throws {
        try access.require(.expandedFileWrite)
        guard posixAccess(directory, W_OK) == 0 else {
            throw LocationBrowserError.notWritable(directory, String(cString: strerror(errno)))
        }
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw LocationBrowserError.invalidName(name)
        }
        return trimmed
    }

    public func writeText(_ text: String, to path: String) async throws {
        let file = try check(path)
        try requireWritableDirectory((file as NSString).deletingLastPathComponent)
        if FileManager.default.fileExists(atPath: file), posixAccess(file, W_OK) != 0 {
            throw LocationBrowserError.notWritable(file, String(cString: strerror(errno)))
        }
        try await authorizeChange("Write a file", path: file, command: "write \(file)")
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: file), options: [.atomic]) } catch {
            throw LocationBrowserError.failed(file, error.localizedDescription)
        }
    }

    @discardableResult
    public func createDirectory(named name: String, in directory: String) async throws -> String {
        let parent = try check(directory)
        let path = (parent as NSString).appendingPathComponent(try validName(name))
        guard !FileManager.default.fileExists(atPath: path) else { throw LocationBrowserError.alreadyExists(name) }
        try requireWritableDirectory(parent)
        try await authorizeChange("Create a folder", path: path, command: "mkdir \(path)")
        do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) } catch {
            throw LocationBrowserError.failed(path, error.localizedDescription)
        }
        return path
    }

    @discardableResult
    public func rename(_ path: String, to newName: String) async throws -> String {
        let source = try check(path)
        let destination = ((source as NSString).deletingLastPathComponent as NSString).appendingPathComponent(try validName(newName))
        guard !FileManager.default.fileExists(atPath: destination) else { throw LocationBrowserError.alreadyExists(newName) }
        try requireWritableDirectory((source as NSString).deletingLastPathComponent)
        try await authorizeChange("Rename", path: source, command: "mv \(source) \(destination)")
        do { try FileManager.default.moveItem(atPath: source, toPath: destination) } catch {
            throw LocationBrowserError.failed(source, error.localizedDescription)
        }
        return destination
    }

    public func delete(_ path: String) async throws {
        let target = try check(path)
        guard !roots.contains(target) else { throw LocationBrowserError.notPermitted("\(target) (a permitted location itself)") }
        try requireWritableDirectory((target as NSString).deletingLastPathComponent)
        try await authorizeChange("Delete", path: target, command: "rm -r \(target)")
        do { try FileManager.default.removeItem(atPath: target) } catch {
            throw LocationBrowserError.failed(target, error.localizedDescription)
        }
    }

    /// Log directories among the permitted roots.
    public var logRoots: [String] {
        Self.logDirectories.filter { candidate in roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") } }
    }
}

/// Earlier name of the read-only part of `HostFileSystem`.
public typealias PermittedLocationBrowser = HostFileSystem

/// `access(2)`, named so it is not shadowed by the `access` policy property.
@inline(__always)
func posixAccess(_ path: String, _ mode: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.access(path, mode)
    #else
    return Glibc.access(path, mode)
    #endif
}
