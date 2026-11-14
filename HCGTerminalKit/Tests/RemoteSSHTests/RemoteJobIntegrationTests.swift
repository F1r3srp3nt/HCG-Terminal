import BuildOrchestrator
import DeveloperWorkspace
import Foundation
import RemoteSSH
import TerminalCore
import TerminalSecurity
import XCTest

/// Doctor and detached build jobs over real SSH (OpenSSH on 127.0.0.1:2222). The important
/// case: the phone's connection drops mid-build; the build keeps running on the host, and a new
/// connection reattaches to it without starting it again or marking it failed.
@MainActor
final class RemoteJobIntegrationTests: XCTestCase {
    let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest")
    var knownHostsURL: URL!
    var storeURL: URL!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1 with Scripts/start-test-sshd.sh running")
        knownHostsURL = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let knownHostsURL { try? FileManager.default.removeItem(at: knownHostsURL) }
        if let storeURL { try? FileManager.default.removeItem(at: storeURL) }
    }

    func connect() async throws -> SSHConnection {
        try await SSHConnection.connect(
            endpoint: endpoint, authentication: .password("hcg-test-pass"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: KnownHostsStore(fileURL: knownHostsURL)) { _, _, _ in true }
        )
    }

    var host: HostProfile {
        HostProfile(id: endpoint.hostID, name: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest", auth: .password)
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ lines: [String]) { lock.lock(); stored += lines; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testBuildSurvivesDisconnectionAndReattachesWithoutDuplicate() async throws {
        let first = try await connect()
        let folder = "job-test-\(UUID().uuidString.prefix(6))"
        _ = try await first.run("mkdir -p \(folder)")
        let runner = HostJobRunner(store: HostJobStore(directory: storeURL), access: .inMemory())
        let plan = try BuildPlanner.custom(host: host, projectPath: "~/\(folder)", command: "echo started >> runs.txt; for i in $(seq 1 8); do echo step $i; sleep 0.5; done; echo 'Authorization: Bearer secret-token-123456' ; echo done")
        let job = await runner.create(plan)
        let firstLines = Lines()
        let follower = Task { await runner.drive(job.id, executor: first) { firstLines.add($0) } }
        try await Task.sleep(for: .seconds(1.6))
        // The phone loses its connection.
        await first.close()
        let afterDrop = await follower.value
        XCTAssertEqual(afterDrop?.state, .running, "losing the connection must not fail the job")
        XCTAssertNotNil(afterDrop?.disconnectedAt)

        try await Task.sleep(for: .seconds(1))
        let second = try await connect()
        let secondLines = Lines()
        let finished = await runner.drive(job.id, executor: second) { secondLines.add($0) }
        XCTAssertEqual(finished?.state, .succeeded)
        let steps = (firstLines.all + secondLines.all).filter { $0.hasPrefix("step ") }
        XCTAssertEqual(steps, (1...8).map { "step \($0)" }, "every line once, in order")
        XCTAssertTrue(secondLines.all.contains("Authorization: Bearer [REDACTED]"))
        // One run on the host, even though the client started following twice.
        let runs = try await second.run("cat \(folder)/runs.txt").stdoutText
        XCTAssertEqual(runs, "started\n")
        // Starting again with the same ID is refused as already started.
        let again = try await HostJobClient(executor: second).start(job)
        XCTAssertEqual(again, .alreadyStarted)
        _ = try await runner.removeEverywhere(job.id, executor: second)
        _ = try await second.run("rm -rf \(folder)")
        await second.close()
    }

    func testCancelOverSSHStopsTheHostProcess() async throws {
        let connection = try await connect()
        let folder = "job-cancel-\(UUID().uuidString.prefix(6))"
        _ = try await connection.run("mkdir -p \(folder)")
        let runner = HostJobRunner(store: HostJobStore(directory: storeURL), access: .inMemory())
        let job = await runner.create(try BuildPlanner.custom(host: host, projectPath: "~/\(folder)", command: "sleep 45; touch finished"))
        let follower = Task { await runner.drive(job.id, executor: connection) }
        try await Task.sleep(for: .seconds(1.5))
        let reply = try await runner.cancel(job.id, executor: connection)
        XCTAssertEqual(reply, "CANCELLED")
        let ended = await follower.value
        XCTAssertEqual(ended?.state, .cancelled)
        let remaining = try await connection.run("pgrep -u hcgtest -fx 'sleep 45' | wc -l; [ -f \(folder)/finished ] && echo finished || echo not-finished").stdoutText
        XCTAssertEqual(remaining.split(separator: "\n").map(String.init), ["0", "not-finished"])
        _ = try await runner.removeEverywhere(job.id, executor: connection)
        _ = try await connection.run("rm -rf \(folder)")
        await connection.close()
    }

    func testDoctorProbeOverSSHUsesTheLoginShell() async throws {
        let connection = try await connect()
        let folder = "doctor-\(UUID().uuidString.prefix(6))"
        _ = try await connection.run("mkdir -p \(folder) && printf 'all:\\n\\ttrue\\n' > \(folder)/Makefile && printf 'Package: x\\n' > \(folder)/control")
        let result = try await connection.run(DoctorProbe.command(projectPath: "~/\(folder)", project: .theos, scheme: nil, executableMakerPath: nil))
        let facts = DoctorFacts.parse(result.stdoutText)
        XCTAssertTrue(facts.isComplete, result.stderrText)
        XCTAssertEqual(facts.value("env.user"), "hcgtest")
        XCTAssertEqual(facts.value("project.dir"), "/home/hcgtest/\(folder)")
        let report = DoctorEvaluator.evaluate(facts: facts, host: host, projectPath: "~/\(folder)", project: .theos, scheme: nil)
        XCTAssertEqual(report.checks.first { $0.id == "theos" }?.presence, .notInstalled)
        XCTAssertEqual(report.checks.first { $0.id == "host" }?.status, .passed)
        _ = try await connection.run("rm -rf \(folder)")
        await connection.close()
    }
}
