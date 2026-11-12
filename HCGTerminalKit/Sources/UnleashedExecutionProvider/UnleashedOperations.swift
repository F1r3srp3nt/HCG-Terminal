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

/// An installed program found by the read-only scan.
public struct InstalledTool: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var id: String { path }
}

/// Why a program could not be launched, in terms of what actually happened.
public enum ToolLaunchError: Error, LocalizedError, Equatable {
    case notInEnvironment(String)
    case notFound(String)
    case notExecutable(String)
    case refusedBySystem(String, errno: Int32)
    case notARunnableProgram(String)
    case declined(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .notInEnvironment(let path): "\(path) is not in one of the program folders found on this device."
        case .notFound(let path): "\(path) does not exist."
        case .notExecutable(let path): "\(path) is not executable for this app (access X_OK failed)."
        case .refusedBySystem(let path, let code):
            "The system refused to start \(path) (\(PathProbe.errnoName(code))). Apps installed from Xcode, TestFlight or the App Store run in the iOS sandbox and cannot start programs; only an installation without the sandbox can."
        case .notARunnableProgram(let path): "\(path) is not a program this device can run (exec format error)."
        case .declined(let command): "Not run: approval for “\(command)” was declined."
        case .failed(let path, let message): "Could not start \(path): \(message)"
        }
    }

    static func from(_ error: Error, path: String) -> ToolLaunchError {
        if case ProcessSpawnError.spawn(_, let code, let message) = error {
            switch code {
            case EPERM, EACCES: return .refusedBySystem(path, errno: code)
            case ENOENT: return .notFound(path)
            case ENOEXEC: return .notARunnableProgram(path)
            default: return .failed(path, message)
            }
        }
        return .failed(path, error.localizedDescription)
    }
}

/// Result of a bounded, non-interactive program run.
public struct ToolRunResult: Hashable, Sendable {
    public var commandLine: String
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var signal: Int32?
    public var duration: TimeInterval

    /// What happened, without guessing.
    public var summary: String {
        if timedOut { return "Stopped after the time limit (killed)." }
        if let signal {
            if signal == SIGKILL && duration < 1.5 && stdout.isEmpty {
                return "Killed by the system right after starting (SIGKILL). On iOS this usually means the program's code signature was not accepted."
            }
            return "Ended by signal \(signal)."
        }
        return "Exited with status \(status)."
    }
}

/// Unleashed operations that act on the device: launching installed programs and the explicit
/// verifications. Every method checks the Capabilities & Access switches first, uses only the
/// permissions the device already gives this app, and never elevates.
public struct UnleashedOperations: Sendable {
    public let scan: UnleashedEnvironmentScan
    private let observations: RuntimeObservations
    private let gate: AuthorizationGate
    private let access: AccessPolicy

    public init(scan: UnleashedEnvironmentScan, observations: RuntimeObservations, gate: AuthorizationGate, access: AccessPolicy = .shared) {
        self.scan = scan
        self.observations = observations
        self.gate = gate
        self.access = access
    }

    // MARK: Programs

    /// Programs in the scanned program folders (read-only listing, bounded).
    public func installedTools(probe: any SystemProbing = LiveSystemProbe(), limit: Int = 3000) -> [InstalledTool] {
        var tools: [InstalledTool] = []
        var names: Set<String> = []
        for directory in scan.executableDirectories.keys.sorted() {
            guard case .success(let entries) = probe.listing(directory) else { continue }
            for name in entries.sorted() where !names.contains(name) {
                let path = directory + "/" + name
                if probe.isExecutableFile(path) {
                    names.insert(name)
                    tools.append(InstalledTool(name: name, path: path))
                    if tools.count >= limit { return tools }
                }
            }
        }
        return tools.sorted { $0.name < $1.name }
    }

    /// Checks that `path` is an executable inside a scanned program folder.
    func validate(_ path: String) throws -> String {
        let standardized = (path as NSString).standardizingPath
        guard scan.executableDirectories.keys.contains((standardized as NSString).deletingLastPathComponent) else {
            throw ToolLaunchError.notInEnvironment(path)
        }
        var info = stat()
        guard stat(standardized, &info) == 0 else { throw ToolLaunchError.notFound(path) }
        guard posixAccess(standardized, X_OK) == 0 else { throw ToolLaunchError.notExecutable(path) }
        return standardized
    }

    /// Commands that need approval are offered to the user first (or refused when the matching
    /// switch is off).
    private func authorize(_ commandLine: String) async throws {
        let assessment = PrivilegeClassifier.assess(commandLine)
        guard assessment.requiresAuthorization else { return }
        let decision = await gate.decide(AuthorizationRequest(
            title: "Run a privileged program?", commandLine: commandLine, target: .local(.unleashed),
            reasons: assessment.reasons, requiredAccess: assessment.requiredAccess
        ))
        switch decision {
        case .approved: return
        case .declined: throw ToolLaunchError.declined(commandLine)
        case .refused(let denied): throw denied
        }
    }

    /// Starts a program interactively in its own pseudo-terminal session.
    public func launchSession(_ path: String, arguments: [String], environment: [String: String]) async throws -> LocalProcessSession {
        try access.require(.localShell)
        let executable = try validate(path)
        try await authorize(([executable] + arguments).joined(separator: " "))
        return LocalProcessSession(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: nil, observations: observations, gate: gate, access: access
        )
    }

    /// Runs a program to completion with a time limit and returns its output.
    public func run(_ path: String, arguments: [String], timeout: TimeInterval = 20) async throws -> ToolRunResult {
        try access.require(.localShell)
        let executable = try validate(path)
        let commandLine = ([executable] + arguments).joined(separator: " ")
        try await authorize(commandLine)
        let started = Date()
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                executable: executable, arguments: arguments,
                environment: ["PATH": scan.searchPath.joined(separator: ":"), "LANG": "en_US.UTF-8", "TERM": "dumb"],
                outputLimit: 1024 * 1024, timeout: timeout
            )
        } catch {
            let launchError = ToolLaunchError.from(error, path: executable)
            if case ProcessSpawnError.spawn(_, let code, let message) = error {
                await observations.record(executable: executable, outcome: .failed(errno: code, message: message))
            }
            throw launchError
        }
        await observations.record(executable: executable, outcome: .succeeded(pid: result.pid))
        return ToolRunResult(
            commandLine: commandLine, status: result.status, stdout: result.stdoutText, stderr: result.stderrText,
            timedOut: result.timedOut, signal: result.terminatingSignal, duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: Explicit verification

    /// Runs the detected shell once with a fixed, harmless command and a 5-second limit. Only
    /// when the user asks. Records the real outcome so the report can say "verified" — or the
    /// real error.
    public func verifyShell() async -> EnvironmentAssessment.Operation {
        let name = "Shell test"
        if let refusal = access.denial(.localShell) { return .init(name: name, outcome: refusal, succeeded: false) }
        guard let shell = scan.shells.first else {
            return .init(name: name, outcome: "No shell was found by the read-only scan; nothing was run.", succeeded: false)
        }
        do {
            let result = try await ProcessRunner.run(
                executable: shell, arguments: ["-c", "printf 'HCG_SHELL_OK\\n'; id -u"],
                environment: ["PATH": scan.searchPath.joined(separator: ":"), "LANG": "C"],
                outputLimit: 4096, timeout: 5
            )
            let ok = result.status == 0 && result.stdoutText.contains("HCG_SHELL_OK")
            if ok {
                await observations.record(executable: shell, outcome: .succeeded(pid: result.pid))
                let uid = result.stdoutText.split(separator: "\n").last.map(String.init) ?? "?"
                return .init(name: name, outcome: "\(shell) ran and printed the expected output (uid \(uid)).", succeeded: true)
            }
            let detail = result.timedOut ? "it did not finish within 5 seconds and was killed" : "exit status \(result.status)\(result.terminatingSignal.map { ", signal \($0)" } ?? "")"
            return .init(name: name, outcome: "\(shell) started but did not complete the test (\(detail)).", succeeded: false)
        } catch {
            if case ProcessSpawnError.spawn(_, let code, let message) = error {
                await observations.record(executable: shell, outcome: .failed(errno: code, message: message))
            }
            return .init(name: name, outcome: ToolLaunchError.from(error, path: shell).localizedDescription, succeeded: false)
        }
    }
}

public extension HostFileSystem {
    /// Writes, reads back and removes one temporary file in `directory`. Only when the user asks,
    /// only with the write switch on, inside a permitted location, and with approval for system
    /// and jailbreak locations. The temporary file is always removed; the result says whether
    /// removal was confirmed.
    func verifyWriteAccess(in directory: String) async -> EnvironmentAssessment.Operation {
        let name = "Write test in \(directory)"
        do {
            let target = try check(directory)
            try requireWritableDirectory(target)
            let file = (target as NSString).appendingPathComponent(".hcg-write-check-\(UUID().uuidString.prefix(8))")
            try await authorizeChange("Write test file", path: file, command: "write and remove \(file)")
            let payload = "hcg write check \(Date().timeIntervalSince1970)"
            let fd = open(file, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else {
                return .init(name: name, outcome: "Could not create a test file: \(String(cString: strerror(errno))).", succeeded: false)
            }
            let written = payload.withCString { pointer in write(fd, pointer, strlen(pointer)) }
            close(fd)
            defer { unlink(file) }
            let readBack = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            unlink(file)
            let removed = !FileManager.default.fileExists(atPath: file)
            let ok = written == payload.utf8.count && readBack == payload
            let cleanup = removed ? "The test file was removed." : "The test file could not be removed: \(file)."
            return .init(name: name, outcome: (ok ? "Created, wrote and read back a test file. " : "The file did not read back correctly. ") + cleanup, succeeded: ok && removed)
        } catch {
            return .init(name: name, outcome: error.localizedDescription, succeeded: false)
        }
    }
}
