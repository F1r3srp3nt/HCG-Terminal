import DeveloperWorkspace
import Diagnostics
import Foundation
import TerminalCore

public struct BuildDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable { case error, warning, note }
    public var id = UUID()
    public var severity: Severity
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var message: String
}

public struct TestSummary: Codable, Hashable, Sendable {
    public var passed: Int?
    public var failed: Int?
    public var skipped: Int?
    public var total: Int?
    public var succeeded: Bool

    public init(passed: Int?, failed: Int?, skipped: Int?, total: Int?, succeeded: Bool) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.total = total
        self.succeeded = succeeded
    }
}

public enum BuildRunStatus: Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed(exitStatus: Int32)
    case cancelled
    case couldNotStart(String)
    /// The connection was lost after the command started. It is never rerun automatically.
    case interrupted(String)

    public var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Succeeded (exit 0)"
        case .failed(let status): "Failed (exit \(status))"
        case .cancelled: "Cancelled"
        case .couldNotStart(let reason): "Could not start: \(reason)"
        case .interrupted(let reason): "Interrupted: \(reason) It was not rerun."
        }
    }

    /// The remote command's real exit status, when it reported one.
    public var exitStatus: Int32? {
        switch self {
        case .succeeded: 0
        case .failed(let status): status
        default: nil
        }
    }
}

public struct BuildRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var plan: BuildPlan
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: BuildRunStatus
    public var diagnostics: [BuildDiagnostic]
    public var testSummary: TestSummary?
    /// File name of the full log inside the log directory.
    public var logFileName: String

    public var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    public var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
}

/// Extracts compiler diagnostics and test results from Swift, Xcode and .NET output.
public enum BuildLogParser {
    // /path/File.swift:12:5: error: message
    private static let clangStyle = try! NSRegularExpression(pattern: #"^(.+?):(\d+):(?:(\d+):)?\s+(error|warning|note):\s+(.*)$"#)
    // /path/File.cs(12,5): error CS1002: message [/path/proj.csproj]
    private static let msbuildStyle = try! NSRegularExpression(pattern: #"^\s*(.+?)\((\d+),(\d+)\):\s+(error|warning)\s+([A-Z]+\d+):\s+(.*?)(?:\s+\[.*\])?$"#)

    public static func diagnostic(in line: String) -> BuildDiagnostic? {
        let range = NSRange(line.startIndex..., in: line)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: line) else { return nil }
            return String(line[r])
        }
        if let match = clangStyle.firstMatch(in: line, range: range),
           let severity = group(match, 4).flatMap(BuildDiagnostic.Severity.init(rawValue:)) {
            return BuildDiagnostic(severity: severity, file: group(match, 1), line: group(match, 2).flatMap(Int.init), column: group(match, 3).flatMap(Int.init), message: group(match, 5) ?? "")
        }
        if let match = msbuildStyle.firstMatch(in: line, range: range),
           let severity = group(match, 4).flatMap(BuildDiagnostic.Severity.init(rawValue:)) {
            return BuildDiagnostic(severity: severity, file: group(match, 1), line: group(match, 2).flatMap(Int.init), column: group(match, 3).flatMap(Int.init), message: "\(group(match, 5) ?? ""): \(group(match, 6) ?? "")")
        }
        return nil
    }

    public static func testSummary(in log: String) -> TestSummary? {
        func int(_ pattern: String, _ group: Int = 1) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).last,
                  let range = Range(match.range(at: group), in: log) else { return nil }
            return Int(log[range])
        }
        // XCTest (swift test, xcodebuild): "Executed 12 tests, with 1 failure"
        if let total = int(#"Executed (\d+) tests?, with \d+ failures?"#) {
            let failed = int(#"Executed \d+ tests?, with (\d+) failures?"#) ?? 0
            let skipped = int(#"Executed \d+ tests?, with (\d+) tests? skipped"#)
            return TestSummary(passed: total - failed - (skipped ?? 0), failed: failed, skipped: skipped, total: total, succeeded: failed == 0)
        }
        // Swift Testing: "Test run with 5 tests passed" / "Test run with 5 tests failed"
        if let total = int(#"Test run with (\d+) tests? (?:in \d+ suites? )?passed"#) {
            return TestSummary(passed: total, failed: 0, skipped: nil, total: total, succeeded: true)
        }
        if let total = int(#"Test run with (\d+) tests? (?:in \d+ suites? )?failed"#) {
            let failed = int(#"with (\d+) issues?"#)
            return TestSummary(passed: nil, failed: failed, skipped: nil, total: total, succeeded: false)
        }
        // dotnet test: "Passed!  - Failed:     0, Passed:    12, Skipped:     0, Total:    12"
        if let total = int(#"Total:\s+(\d+)"#), let failed = int(#"Failed:\s+(\d+)"#) {
            return TestSummary(passed: int(#"Passed:\s+(\d+)"#), failed: failed, skipped: int(#"Skipped:\s+(\d+)"#), total: total, succeeded: failed == 0)
        }
        if log.contains("** TEST SUCCEEDED **") { return TestSummary(passed: nil, failed: 0, skipped: nil, total: nil, succeeded: true) }
        if log.contains("** TEST FAILED **") { return TestSummary(passed: nil, failed: nil, skipped: nil, total: nil, succeeded: false) }
        return nil
    }
}

/// Runs build plans on a remote host and records them. Depends only on
/// `RemoteCommandExecuting`, so it works the same whatever the local mode is.
public actor BuildOrchestrator {
    private let logDirectory: URL
    private let historyURL: URL
    private var history: [BuildRun]

    public init(logDirectory: URL) {
        self.logDirectory = logDirectory
        self.historyURL = logDirectory.appendingPathComponent("build-history.json")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: historyURL), let decoded = try? JSONDecoder().decode([BuildRun].self, from: data) {
            history = decoded
        } else {
            history = []
        }
    }

    public func runs() -> [BuildRun] { history.sorted { $0.startedAt > $1.startedAt } }

    public func logURL(for run: BuildRun) -> URL { logDirectory.appendingPathComponent(run.logFileName) }

    public func log(for run: BuildRun) -> String {
        (try? String(contentsOf: logURL(for: run), encoding: .utf8)) ?? ""
    }

    /// Runs `plan`. `onOutput` receives log text as it arrives. Cancelling the calling task
    /// closes the remote channel.
    public func run(_ plan: BuildPlan, on executor: any RemoteCommandExecuting, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async -> BuildRun {
        let id = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let logName = "build-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: ""))-\(id.uuidString.prefix(8)).log"
        var run = BuildRun(id: id, plan: plan, startedAt: Date(), finishedAt: nil, status: .running, diagnostics: [], testSummary: nil, logFileName: logName)

        guard executor.endpoint.hostID == plan.hostID else {
            run.status = .couldNotStart("The plan belongs to \(plan.hostName), not \(executor.endpoint.displayName).")
            run.finishedAt = Date()
            record(run)
            return run
        }

        let logURL = logDirectory.appendingPathComponent(logName)
        _ = FileManager.default.createFile(atPath: logURL.path, contents: Data("$ \(plan.commandLine)\n".utf8))
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        await DiagnosticLog.shared.record(.info, "build", "Build started", metadata: ["host": plan.hostName, "command": plan.commandLine])

        var pendingLine = ""
        var fullLog = ""
        var status: Int32?
        var remotePID: Int32?
        var markerBuffer: Data? = Data() // collects the first line until the PID marker is parsed
        var receivedOutput = false
        do {
            for try await event in executor.stream(plan.remoteCommand) {
                switch event {
                case .stdout(var data), .stderr(var data):
                    if var buffer = markerBuffer {
                        // Strip the "__HCG_PID__<pid>" line the command prints first.
                        buffer.append(data)
                        guard let newline = buffer.firstIndex(of: 0x0A) else { markerBuffer = buffer; continue }
                        let first = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        if first.hasPrefix(RemoteProcessMarker.prefix) {
                            remotePID = Int32(first.dropFirst(RemoteProcessMarker.prefix.count))
                            data = Data(buffer[buffer.index(after: newline)...])
                        } else {
                            data = buffer
                        }
                        markerBuffer = nil
                        if data.isEmpty { continue }
                    }
                    receivedOutput = true
                    try? handle?.write(contentsOf: data)
                    let text = String(decoding: data, as: UTF8.self)
                    fullLog += text
                    onOutput(text)
                    pendingLine += text
                    while let newline = pendingLine.firstIndex(of: "\n") {
                        let line = String(pendingLine[..<newline])
                        pendingLine.removeSubrange(...newline)
                        if let diagnostic = BuildLogParser.diagnostic(in: line), !run.diagnostics.contains(where: { $0.file == diagnostic.file && $0.line == diagnostic.line && $0.message == diagnostic.message }) {
                            run.diagnostics.append(diagnostic)
                        }
                    }
                case .exit(let code):
                    status = code
                }
            }
            if Task.isCancelled {
                run.status = .cancelled
            } else if let status {
                run.status = status == 0 ? .succeeded : .failed(exitStatus: status)
            } else {
                run.status = .interrupted("The command ended without reporting an exit status.")
            }
        } catch {
            if Task.isCancelled {
                run.status = .cancelled
            } else if receivedOutput || remotePID != nil {
                run.status = .interrupted(error.localizedDescription)
            } else {
                run.status = .couldNotStart(error.localizedDescription)
            }
        }
        if run.status == .cancelled, let remotePID {
            // Stop the build on the host too. Runs outside the cancelled task.
            let kill = RemoteProcessMarker.killCommand(pid: remotePID)
            _ = await Task.detached { try? await executor.run(kill) }.value
            try? handle?.write(contentsOf: Data("\n[cancelled: sent TERM to remote process group \(remotePID)]\n".utf8))
            await DiagnosticLog.shared.record(.notice, "build", "Cancelled build stopped on host", metadata: ["host": plan.hostName, "pid": "\(remotePID)"])
        }
        try? handle?.close()
        if plan.action == .test { run.testSummary = BuildLogParser.testSummary(in: fullLog) }
        run.finishedAt = Date()
        record(run)
        await DiagnosticLog.shared.record(run.status == .succeeded ? .info : .warning, "build", "Build finished", metadata: ["host": plan.hostName, "status": run.status.label])
        return run
    }

    private func record(_ run: BuildRun) {
        history.removeAll { $0.id == run.id }
        history.append(run)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        try? JSONEncoder().encode(history).write(to: historyURL, options: [.atomic])
    }
}

/// A build product found on the remote host after a run.
public struct DiscoveredArtifact: Hashable, Sendable, Identifiable {
    public var remotePath: String
    public var name: String
    public var isDirectory: Bool
    public var id: String { remotePath }
}

/// Finds build products for a plan with a bounded, read-only `find`.
public enum ArtifactDiscovery {
    static func searchRoots(for plan: BuildPlan) -> [String] {
        switch plan.system {
        case .swiftPackage: [".build/\(plan.configuration.rawValue.lowercased())"]
        case .xcodeProject, .xcodeWorkspace: ["\(BuildPlanner.derivedDataPath)/Build/Products"]
        case .dotnet: ["bin/\(plan.configuration.rawValue)", "."]
        }
    }

    static func script(for plan: BuildPlan) -> String {
        let roots = searchRoots(for: plan).map(ShellQuote.quote).joined(separator: " ")
        let filter: String
        switch plan.system {
        case .swiftPackage:
            filter = "-maxdepth 1 -type f -perm -u+x ! -name '*.so' ! -name '*.dylib' ! -name '*.json'"
        case .xcodeProject, .xcodeWorkspace:
            filter = "-maxdepth 2 \\( -name '*.app' -o -name '*.ipa' -o -name '*.xcarchive' -o -name '*.framework' -o -name '*.appex' \\) -prune"
        case .dotnet:
            filter = "-maxdepth 5 -path '*/bin/*' \\( -name '*.dll' -o -name '*.exe' -o -name '*.nupkg' \\) -type f"
        }
        return RemoteShell.inDirectory(plan.projectPath, "for r in \(roots); do [ -d \"$r\" ] && find -H \"$r\" -mindepth 1 \(filter) -print 2>/dev/null; done | head -200 | while IFS= read -r p; do if [ -d \"$p\" ]; then t=d; else t=f; fi; printf '%s\\t%s\\n' \"$t\" \"$(cd \"$(dirname \"$p\")\" && pwd)/$(basename \"$p\")\"; done")
    }

    public static func discover(for plan: BuildPlan, on executor: any RemoteCommandExecuting) async throws -> [DiscoveredArtifact] {
        let result = try await executor.run(script(for: plan))
        var seen = Set<String>()
        return result.stdoutText.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, seen.insert(fields[1]).inserted else { return nil }
            return DiscoveredArtifact(remotePath: fields[1], name: (fields[1] as NSString).lastPathComponent, isDirectory: fields[0] == "d")
        }
    }
}
