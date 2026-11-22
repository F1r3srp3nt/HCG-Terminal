#if os(Linux) || os(macOS)
import Foundation
import TerminalCore
@testable import UnleashedExecutionProvider
import XCTest

/// The real `hcg-pty-helper`, compiled from Unleashed-Helper/hcg-pty-helper.c, on a terminal
/// opened the way Darwin opens it (no controlling terminal). Without the helper Ctrl-C is just a
/// character; with it the terminal driver interrupts the foreground program, `/dev/tty` opens and
/// window-size changes reach the program, as on a desktop terminal.
final class PTYHelperTests: XCTestCase {
    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Unleashed-Helper/hcg-pty-helper.c")

    var helper: String!
    var directory: URL!

    override func setUpWithError() throws {
        let compiler = ["/usr/bin/cc", "/usr/bin/clang", "/usr/bin/gcc"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(compiler != nil, "no C compiler")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pty helper \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        helper = directory.appendingPathComponent(PTYHelper.name).path
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: compiler!)
        cc.arguments = ["-Wall", "-Werror", "-O2", "-o", helper, Self.source.path]
        try cc.run()
        cc.waitUntilExit()
        XCTAssertEqual(cc.terminationStatus, 0, "the helper must compile cleanly")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func add(_ new: [UInt8]) { lock.lock(); bytes += new; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }

    func waitFor(_ output: Output, _ marker: String, seconds: Double = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if output.text.contains(marker) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return output.text.contains(marker)
    }

    static let script = """
    if ( : < /dev/tty ) 2>/dev/null; then echo HAS-CTTY; else echo NO-CTTY; fi
    trap 'echo GOT-INT; exit 0' INT
    trap 'echo "WINCH $(stty size)"' WINCH
    echo "PWD=$(pwd)"
    echo READY
    i=0; while [ $i -lt 40 ]; do sleep 0.1; i=$((i+1)); done
    echo NO-INT
    """

    func run(helper: String?) async throws -> Output {
        let process = try PTYProcess.spawn(
            executable: "/bin/sh", arguments: ["-c", Self.script], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: directory.path, size: TerminalSize(columns: 80, rows: 24), workingDirectoryStrategy: .fileAction,
            controllingTerminalHelper: helper, openWithoutControllingTerminal: true
        )
        let output = Output()
        process.startReading(onData: { output.add($0) }, onExit: { _ in })
        let ready = await waitFor(output, "READY")
        XCTAssertTrue(ready, output.text)
        process.resize(TerminalSize(columns: 100, rows: 40))
        try await Task.sleep(for: .milliseconds(400))
        try process.write([0x03]) // Ctrl-C
        _ = await waitFor(output, "INT")
        process.terminate()
        return output
    }

    func testWithoutTheHelperThereIsNoControllingTerminal() async throws {
        let output = try await run(helper: nil)
        XCTAssertTrue(output.text.contains("NO-CTTY"), output.text)
        XCTAssertTrue(output.text.contains("NO-INT"), "Ctrl-C cannot interrupt without a controlling terminal: \(output.text)")
        XCTAssertFalse(output.text.contains("GOT-INT"))
    }

    func testTheHelperGivesJobControlSignalsAndTheWorkingDirectory() async throws {
        let output = try await run(helper: helper)
        XCTAssertTrue(output.text.contains("HAS-CTTY"), output.text)
        XCTAssertTrue(output.text.contains("PWD=\(directory.path)"), "the helper's -C sets the directory: \(output.text)")
        XCTAssertTrue(output.text.contains("WINCH 40 100"), "a resize reaches the program: \(output.text)")
        XCTAssertTrue(output.text.contains("GOT-INT"), "Ctrl-C interrupts the foreground program: \(output.text)")
        XCTAssertFalse(output.text.contains("NO-INT"))
    }

    func testTheHelperReportsAMissingProgram() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: helper)
        probe.arguments = ["--", "/nonexistent/hcg-shell"]
        let pipe = Pipe()
        probe.standardError = pipe
        try probe.run()
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 127)
        XCTAssertTrue(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("cannot run /nonexistent/hcg-shell"))
    }

    func testLocatorUsesTheBundleOrTheOverride() throws {
        XCTAssertEqual(PTYHelper.bundled(environment: [:], bundlePath: directory.path), helper)
        XCTAssertNil(PTYHelper.bundled(environment: [:], bundlePath: "/nonexistent"))
        XCTAssertNil(PTYHelper.bundled(environment: ["HCG_PTY_HELPER": ""], bundlePath: directory.path), "an empty override turns it off")
        XCTAssertEqual(PTYHelper.bundled(environment: ["HCG_PTY_HELPER": helper], bundlePath: "/nonexistent"), helper)
    }
}
#endif
