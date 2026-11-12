import FileWorkspace
import Foundation
@testable import LocalCommandEngine
import TerminalCore
import TerminalTestSupport
import XCTest

final class ShellEscapingTests: XCTestCase {
    func testEscapeRoundTripsThroughParser() throws {
        for name in ["My Folder", "it's", "a&b;c", "$HOME", "x*y?", "tab\there", "back\\slash", "(paren)"] {
            let line = "cat " + ShellEscaping.escape(name)
            let words = try CommandParser.parse(line, environment: ["HOME": "/home"]).items[0].pipeline.commands[0].arguments
            XCTAssertEqual(words, ["cat", name], line)
            XCTAssertFalse(try CommandParser.parse(line).items[0].pipeline.commands[0].words[1].globbable && Glob.hasPattern(name), "escaped glob characters stay literal")
        }
    }

    func testCurrentWordRespectsEscapesAndQuotes() {
        XCTAssertEqual(ShellEscaping.currentWord("cd My\\ Fo").word, "My\\ Fo")
        XCTAssertFalse(ShellEscaping.currentWord("cd My\\ Fo").isCommand)
        XCTAssertEqual(ShellEscaping.currentWord("ec").isCommand, true)
        XCTAssertEqual(ShellEscaping.currentWord("ls; ca").isCommand, true)
        let quoted = ShellEscaping.currentWord("cat \"My Fo")
        XCTAssertEqual(quoted.word, "\"My Fo")
        XCTAssertEqual(quoted.quote, "\"")
        XCTAssertEqual(ShellEscaping.unescape("\"My Fo"), "My Fo")
        XCTAssertEqual(ShellEscaping.unescape("My\\ Fo"), "My Fo")
    }

    func testHints() {
        XCTAssertTrue(CommandSuggestions.hints(for: "lss", registry: .standard).first?.contains("ls") ?? false)
        XCTAssertTrue(CommandSuggestions.hints(for: "git", registry: .standard).contains { $0.contains("Remote Host") })
        XCTAssertTrue(CommandSuggestions.hints(for: "vim", registry: .standard).contains { $0.contains("Files") })
        XCTAssertEqual(CommandSuggestions.hints(for: "zzzzzz", registry: .standard), ["Type `help` for the built-in commands."])
    }
}

final class StandardTerminalSessionTests: XCTestCase {
    var root: URL!
    var workspace: FileWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-std-\(UUID().uuidString)")
        workspace = try FileWorkspace(rootURL: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeSession() -> BuiltinShellSession {
        BuiltinShellSession(
            configuration: BuiltinShellConfiguration(
                target: .local(.vanilla), workspace: workspace, environment: [:], banner: "", promptLabel: "hcg",
                promptColor: "", sessionDescription: [], capabilityDescription: { "" },
                persistence: ShellPersistence(workspace: workspace)
            ),
            external: RefusingExternalCommandHandler(policyDescription: "", explanation: "It is not an HCG built-in command.")
        )
    }

    /// Types `text` and returns everything echoed until `done` is true.
    private func type(_ session: BuiltinShellSession, _ text: String, until done: @escaping @Sendable (String) -> Bool) async throws -> String {
        let events = session.events
        let collector = Task { await collectOutput(events, seconds: 10, until: done) }
        try await session.send(text: text)
        let output = await collector.value
        XCTAssertFalse(output.timedOut, "timed out: \(output.text.debugDescription)")
        return output.text
    }

    func testTabCompletesNamesWithSpacesEscaped() async throws {
        try workspace.createDirectory(WorkspacePath("/home/My Folder"))
        try workspace.write("x", to: WorkspacePath("/home/My Folder/read me.txt"))
        let session = makeSession()
        try await session.start(size: .standard)
        _ = try await type(session, "cd My\t", until: { $0.contains("My\\ Folder/") })
        _ = try await type(session, "\r", until: { $0.contains("$ ") })
        let status = await session.runForTesting("pwd > /tmp/where.txt")
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try workspace.readText(WorkspacePath("/tmp/where.txt")), "/home/My Folder\n")
        // Inside an open quote: completes without escaping and closes the quote.
        let echoed = try await type(session, "cat \"rea\t", until: { $0.contains("read me.txt\" ") })
        XCTAssertTrue(echoed.contains("read me.txt\" "), echoed)
        await session.close()
    }

    func testHistoryAndDirectoryPersistAcrossSessions() async throws {
        try workspace.createDirectory(WorkspacePath("/home/project"))
        let first = makeSession()
        _ = await first.runForTesting("cd project")
        // runForTesting bypasses submit; type a command to exercise history persistence.
        try await first.start(size: .standard)
        _ = try await type(first, "echo remembered-command\r", until: { $0.contains("remembered-command\r\n") && $0.hasSuffix("$ ") })
        await first.close()

        let persistence = ShellPersistence(workspace: workspace)
        XCTAssertEqual(persistence.loadHistory().last, "echo remembered-command")
        XCTAssertEqual(persistence.lastDirectory()?.string, "/home/project")

        let second = makeSession()
        try await second.start(size: .standard)
        // Up-arrow recalls the previous session's command.
        let recalled = try await type(second, "\u{1B}[A", until: { $0.contains("echo remembered-command") })
        XCTAssertTrue(recalled.contains("project"), "prompt shows the restored folder: \(recalled)")
        _ = try await type(second, "\u{15}history -c\r", until: { $0.hasSuffix("$ ") && $0.contains("history -c") })
        XCTAssertEqual(ShellPersistence(workspace: workspace).loadHistory(), [])
        await second.close()
    }

    func testMissingRestoredDirectoryFallsBackToHome() async throws {
        try workspace.createDirectory(WorkspacePath("/home/gone"))
        ShellPersistence(workspace: workspace).saveDirectory(try WorkspacePath("/home/gone"))
        try workspace.remove(WorkspacePath("/home/gone"))
        let session = makeSession()
        _ = await session.runForTesting("pwd > /tmp/p.txt")
        XCTAssertEqual(try workspace.readText(WorkspacePath("/tmp/p.txt")), "/home\n")
    }

    func testUnknownCommandExplainsAndSuggests() async throws {
        let session = makeSession()
        try await session.start(size: .standard)
        let text = try await type(session, "lss\r", until: { $0.contains("help") && $0.hasSuffix("$ ") })
        XCTAssertTrue(text.contains("hcg: lss: It is not an HCG built-in command."), text)
        XCTAssertTrue(text.contains("Did you mean: ls"), text)
        let help = try await type(session, "help cd\r", until: { $0.contains("Examples:") && $0.hasSuffix("$ ") })
        XCTAssertTrue(help.contains("cd \"My Folder\""), help)
        await session.close()
    }
}
