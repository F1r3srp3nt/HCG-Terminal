import Crypto
import Foundation
import RemoteSSH
import TerminalCore
import TerminalSecurity
import TerminalTestSupport
import XCTest

/// Integration tests against a real OpenSSH server. Start one with
/// `Scripts/start-test-sshd.sh`, then run with `HCG_SSH_TEST=1`.
final class RemoteSSHIntegrationTests: XCTestCase {
    let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest")
    let password = "hcg-test-pass"
    var knownHostsURL: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1 with Scripts/start-test-sshd.sh running")
        knownHostsURL = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if let knownHostsURL { try? FileManager.default.removeItem(at: knownHostsURL) }
    }

    final class ApprovalLog: @unchecked Sendable {
        var prompts: [PresentedHostKey] = []
    }

    func policy(approve: Bool, log: ApprovalLog = ApprovalLog()) -> HostKeyPolicy {
        HostKeyPolicy(knownHosts: KnownHostsStore(fileURL: knownHostsURL)) { _, _, key in
            log.prompts.append(key)
            return approve
        }
    }

    func connect(approve: Bool = true, log: ApprovalLog = ApprovalLog(), authentication: SSHAuthentication? = nil) async throws -> SSHConnection {
        try await SSHConnection.connect(endpoint: endpoint, authentication: authentication ?? .password(password), hostKeyPolicy: policy(approve: approve, log: log))
    }

    func testUnknownHostKeyNeedsExplicitApproval() async throws {
        let log = ApprovalLog()
        do {
            _ = try await connect(approve: false, log: log)
            XCTFail("must not connect without approval")
        } catch let error as SSHConnectionError {
            guard case .hostKeyNotTrusted = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(log.prompts.count, 1)
        XCTAssertEqual(log.prompts.first?.algorithm, "ssh-ed25519")
        if let expected = try? String(contentsOfFile: "/tmp/hcg-test-sshd/host_ed25519.pub", encoding: .utf8),
           let key = PresentedHostKey(openSSHLine: expected) {
            XCTAssertEqual(log.prompts.first?.fingerprint, key.fingerprint, "fingerprint shown to the user must match OpenSSH")
        }
    }

    func testApprovedKeyIsRememberedAndChangedKeyIsRefused() async throws {
        let first = ApprovalLog()
        let connection = try await connect(log: first)
        await connection.close()
        XCTAssertEqual(first.prompts.count, 1)

        let second = ApprovalLog()
        let again = try await connect(log: second)
        await again.close()
        XCTAssertEqual(second.prompts.count, 0, "trusted key must not prompt again")

        // Replace the stored key with a different one: the connection must be refused without a prompt.
        let store = KnownHostsStore(fileURL: knownHostsURL)
        try await store.forget(host: "127.0.0.1", port: 2222)
        try await store.trust(host: "127.0.0.1", port: 2222, key: PresentedHostKey(algorithm: "ssh-ed25519", blob: Data(repeating: 7, count: 51)))
        let third = ApprovalLog()
        do {
            _ = try await connect(log: third)
            XCTFail("changed key must be refused")
        } catch let error as SSHConnectionError {
            guard case .hostKeyChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(third.prompts.count, 0)
    }

    func testWrongPasswordFails() async throws {
        do {
            _ = try await connect(authentication: .password("wrong"))
            XCTFail("must fail")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    func testExecCollectsStdoutStderrAndStatus() async throws {
        let connection = try await connect()
        let result = try await connection.run("echo out; echo err >&2; exit 3")
        XCTAssertEqual(result.stdoutText, "out\n")
        XCTAssertEqual(result.stderrText, "err\n")
        XCTAssertEqual(result.status, 3)
        await connection.close()
    }

    func testEd25519KeyAuthentication() async throws {
        let credentials = InMemoryCredentialStore()
        let metadata = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadata) }
        let manager = SSHKeyManager(credentials: credentials, metadataURL: metadata)
        let record = try manager.generateEd25519(comment: "hcg-terminal-test")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/home/hcgtest/.ssh/authorized_keys"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((record.publicKeyLine + "\n").utf8))
        try handle.close()

        let connection = try await connect(authentication: .key(try manager.privateKey(for: record.id)))
        let result = try await connection.run("whoami")
        XCTAssertEqual(result.stdoutText, "hcgtest\n")
        await connection.close()
    }

    /// A key made by ssh-keygen, protected by a passphrase, imported and used to sign in. Covers
    /// every ECDSA curve the app accepts, plus Ed25519.
    func testImportedPassphraseKeysSignIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = SSHKeyManager(credentials: InMemoryCredentialStore(), metadataURL: folder.appendingPathComponent("keys.json"))
        for (type, bits) in [("ecdsa", "256"), ("ecdsa", "384"), ("ecdsa", "521"), ("ed25519", "")] {
            let path = folder.appendingPathComponent("\(type)\(bits)").path
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", type, "-N", "import pass", "-a", "4", "-C", "imported@test", "-f", path] + (bits.isEmpty ? [] : ["-b", bits])
            try keygen.run()
            keygen.waitUntilExit()
            let imported = try OpenSSHKeyImport.parse(try String(contentsOfFile: path, encoding: .utf8), passphrase: "import pass")
            let record = try manager.importKey(imported, comment: imported.comment)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/home/hcgtest/.ssh/authorized_keys"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((record.publicKeyLine + "\n").utf8))
            try handle.close()

            let connection = try await connect(authentication: .key(try manager.privateKey(for: record.id)))
            let result = try await connection.run("echo signed-in-with-\(type)\(bits)")
            XCTAssertEqual(result.stdoutText, "signed-in-with-\(type)\(bits)\n", record.algorithm)
            await connection.close()
        }
    }

    func testPTYShellSessionSizeResizeAndIndependentClose() async throws {
        let connection = try await connect()
        let first = try await connection.openSession(size: TerminalSize(columns: 80, rows: 24))
        let second = try await connection.openSession(size: .standard)
        XCTAssertEqual(first.target, .remote(endpoint))
        XCTAssertEqual(first.backend, .sshShell)

        let firstEvents = first.events
        let output = Task { () -> String in
            let collected = await collectOutput(firstEvents) { $0.contains("RESIZED-30x100") }
            XCTAssertFalse(collected.timedOut, "timed out: \(collected.text.debugDescription)")
            return collected.text
        }
        try await first.send(text: "stty size; echo MARK-$((2+3))\r")
        try await Task.sleep(nanoseconds: 500_000_000)
        await first.resize(TerminalSize(columns: 100, rows: 30))
        try await Task.sleep(nanoseconds: 200_000_000)
        try await first.send(text: "echo RESIZED-$(stty size | tr ' ' x)\r")
        let text = await output.value
        XCTAssertTrue(text.contains("24 80"), text)
        XCTAssertTrue(text.contains("MARK-5"), text)
        XCTAssertTrue(text.contains("RESIZED-30x100"), text)

        // Closing one session leaves the other session and the connection usable.
        await first.close()
        let secondEvents = second.events
        let secondOutput = Task { () -> String in
            let collected = await collectOutput(secondEvents) { $0.contains("STILL-7") }
            XCTAssertFalse(collected.timedOut, "timed out: \(collected.text.debugDescription)")
            return collected.text
        }
        try await second.send(text: "echo STILL-$((3+4))\r")
        let secondText = await secondOutput.value
        XCTAssertTrue(secondText.contains("STILL-7"))
        let exec = try await connection.run("echo exec-ok")
        XCTAssertEqual(exec.stdoutText, "exec-ok\n")
        await second.close()
        await connection.close()
    }

    func testCommandSessionReportsExitStatus() async throws {
        let connection = try await connect()
        let session = try await connection.openSession(size: .standard, command: "printf 'claude-placeholder\\n'; exit 4")
        guard case .sshCommand = session.backend else { return XCTFail() }
        let collected = await collectOutput(session.events)
        XCTAssertFalse(collected.timedOut, "timed out: \(collected.text.debugDescription)")
        let state = collected.finalState
        let text = collected.text
        XCTAssertTrue(text.contains("claude-placeholder"))
        XCTAssertEqual(state, .exited(status: 4))
        await connection.close()
    }
}
