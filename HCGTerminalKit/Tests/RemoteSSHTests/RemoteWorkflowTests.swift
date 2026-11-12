import ArtifactManager
import BuildOrchestrator
import Crypto
import DeveloperWorkspace
import FileWorkspace
import Foundation
import RemoteSSH
import TerminalCore
import TerminalSecurity
import XCTest

/// Step 4 workflow against a real OpenSSH server (Scripts/start-test-sshd.sh, HCG_SSH_TEST=1).
final class RemoteWorkflowTests: XCTestCase {
    let host = HostProfile(name: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest", auth: .password)

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1")
    }

    func connect(_ endpoint: RemoteEndpoint? = nil, password: String = "hcg-test-pass") async throws -> SSHConnection {
        try await SSHConnection.connect(
            endpoint: endpoint ?? host.endpoint, authentication: .password(password),
            hostKeyPolicy: HostKeyPolicy(knownHosts: KnownHostsStore(fileURL: nil)) { _, _, _ in true },
            timeout: .seconds(10)
        )
    }

    func testConnectionErrorsAreClassified() async throws {
        func category(_ endpoint: RemoteEndpoint, password: String = "hcg-test-pass") async -> String? {
            do { _ = try await connect(endpoint, password: password); return nil } catch let error as SSHConnectionError {
                return error.category
            } catch { return "unclassified: \(error)" }
        }
        let dns = RemoteEndpoint(hostID: UUID(), displayName: "x", hostname: "no-such-host-hcg.invalid", port: 22, username: "u")
        let refused = RemoteEndpoint(hostID: UUID(), displayName: "x", hostname: "127.0.0.1", port: 2299, username: "u")
        let dnsCategory = await category(dns)
        XCTAssertEqual(dnsCategory, "Host not found (DNS)")
        let refusedCategory = await category(refused)
        XCTAssertEqual(refusedCategory, "Connection refused")
        let authCategory = await category(host.endpoint, password: "wrong")
        XCTAssertEqual(authCategory, "Authentication failed")
        XCTAssertTrue(SSHConnectionError.connectionRefused(host: "mac", port: 22).localizedDescription.contains("Remote Login"))
    }

    func testProjectWithSpacesBuildTestFailCancelAndArtifact() async throws {
        let connection = try await connect()
        let toolchains = try await ToolchainProbe.probe(connection)
        try XCTSkipUnless(toolchains.has("swift"), "no swift on the test host")

        let project = "~/HCG Demo \(UUID().uuidString.prefix(4))/My App"
        let setup = try await connection.run(RemoteShell.login("""
        mkdir -p \(RemoteShell.quotePath(project))/Sources/HCGDemo \(RemoteShell.quotePath(project))/Tests/HCGDemoTests && cd \(RemoteShell.quotePath(project)) && \
        printf '%s\\n' 'print("hello from a path with spaces")' > Sources/HCGDemo/main.swift && \
        printf '%s\\n' 'import XCTest' 'final class T: XCTestCase { func testOK() { XCTAssertEqual(1 + 1, 2) } }' > Tests/HCGDemoTests/T.swift && \
        cat > Package.swift <<'EOF2'
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "HCGDemo", targets: [
            .executableTarget(name: "HCGDemo", path: "Sources/HCGDemo"),
            .testTarget(name: "HCGDemoTests", path: "Tests/HCGDemoTests"),
        ])
        EOF2
        """))
        XCTAssertEqual(setup.status, 0, setup.stderrText)

        // Browse: the folder with spaces lists and is recognised.
        let listing = try await RemoteProjectBrowser(executor: connection).list(project)
        XCTAssertTrue(listing.directory.hasSuffix("/My App"), listing.directory)
        XCTAssertTrue(ProjectDetector.detect(listing.entries).contains(.swiftPackage))

        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logs) }
        let orchestrator = BuildOrchestrator(logDirectory: logs)

        final class Streamed: @unchecked Sendable { var text = "" }
        let streamed = Streamed()
        let build = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: project, system: .swiftPackage, action: .build), on: connection) { streamed.text += $0 }
        let buildLog = await orchestrator.log(for: build)
        XCTAssertEqual(build.status, .succeeded, buildLog)
        XCTAssertEqual(build.status.exitStatus, 0)
        XCTAssertFalse(streamed.text.contains(RemoteProcessMarker.prefix), "the PID marker is not shown in the log")
        XCTAssertTrue(streamed.text.contains("Compiling") || streamed.text.contains("Build"), "logs streamed live")

        let passing = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: project, system: .swiftPackage, action: .test), on: connection)
        XCTAssertEqual(passing.status, .succeeded)
        XCTAssertEqual(passing.testSummary?.succeeded, true)

        // Make the test fail: the real non-zero exit status is reported.
        _ = try await connection.run("cd \(RemoteShell.quotePath(project)) && sed -i 's/1 + 1, 2/1 + 1, 3/' Tests/HCGDemoTests/T.swift")
        let failing = await orchestrator.run(try BuildPlanner.plan(host: host, projectPath: project, system: .swiftPackage, action: .test), on: connection)
        guard case .failed(let code) = failing.status else { return XCTFail("\(failing.status)") }
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(failing.testSummary?.succeeded, false)
        XCTAssertEqual(failing.testSummary?.failed, 1)

        // Artifact from the path with spaces, verified by checksum.
        let artifacts = try await ArtifactDiscovery.discover(for: build.plan, on: connection)
        let executable = try XCTUnwrap(artifacts.first { $0.name == "HCGDemo" }, "\(artifacts)")
        XCTAssertTrue(executable.remotePath.contains("/HCG Demo "), executable.remotePath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-wf-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try FileWorkspace(rootURL: root)
        let record = try await ArtifactDownloader().download(remotePath: executable.remotePath, from: connection, into: workspace, index: ArtifactIndex(workspace: workspace), buildRunID: build.id)
        XCTAssertEqual(record.verification, .remoteChecksumMatched)

        _ = try await connection.run("rm -rf \(RemoteShell.quotePath((project as NSString).deletingLastPathComponent))")
        await connection.close()
    }

    func testCancellationStopsTheRemoteProcess() async throws {
        let connection = try await connect()
        let marker = "/tmp/hcg-cancel-\(UUID().uuidString.prefix(6))"
        // A distinctive duration identifies the process; "[s]leep" keeps pgrep from matching its own shell.
        let seconds = "37.\(Int.random(in: 100...999))"
        let token = "[s]leep \(seconds)"
        let plan = try BuildPlanner.custom(host: host, projectPath: "~", command: "echo started; sleep \(seconds); touch \(marker)")
        let orchestrator = BuildOrchestrator(logDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("hcg-cancel-\(UUID().uuidString)"))
        let task = Task { await orchestrator.run(plan, on: connection) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let running = try await connection.run("pgrep -f '\(token)' | wc -l").stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertGreaterThan(Int(running) ?? 0, 0, "the remote command (login shell and sleep) runs before cancellation")
        task.cancel()
        let run = await task.value
        XCTAssertEqual(run.status, .cancelled)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try await connection.run("pgrep -f '\(token)' | wc -l; [ -e \(marker) ] && echo marker-exists || echo no-marker").stdoutText
        XCTAssertTrue(after.hasPrefix("0"), "remote process still running: \(after)")
        XCTAssertTrue(after.contains("no-marker"), "the command continued after cancel: \(after)")
        let log = await orchestrator.log(for: run)
        XCTAssertTrue(log.contains("[cancelled: sent TERM to remote process group"), log)
        await connection.close()
    }

    func testLostConnectionIsInterruptedAndNotRerun() async throws {
        let connection = try await connect()
        let plan = try BuildPlanner.custom(host: host, projectPath: "~", command: "echo begin; sleep 5; echo finished")
        let orchestrator = BuildOrchestrator(logDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("hcg-lost-\(UUID().uuidString)"))
        let task = Task { await orchestrator.run(plan, on: connection) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await connection.close() // the network drops
        let run = await task.value
        guard case .interrupted = run.status else { return XCTFail("\(run.status)") }
        XCTAssertNil(run.status.exitStatus, "no invented exit status")
        XCTAssertTrue(run.status.label.contains("not rerun"))
        let runs = await orchestrator.runs()
        XCTAssertEqual(runs.count, 1, "nothing was retried")
    }
}
