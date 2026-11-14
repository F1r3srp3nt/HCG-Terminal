#if os(macOS) || os(Linux)
import BuildOrchestrator
import DeveloperWorkspace
import Diagnostics
import Foundation
import TerminalCore
import TerminalTestSupport
import XCTest

/// Detached jobs, run for real with the local /bin/sh (HOME points at a scratch folder).
@MainActor
final class HostJobTests: XCTestCase {
    var root: URL!
    var home: String { root.appendingPathComponent("home").path }
    var project: String { root.appendingPathComponent("home/My Project").path }
    var executor: LocalShellExecutor!
    var host: HostProfile!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hostjobs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        executor = LocalShellExecutor(home: home)
        host = HostProfile(id: executor.endpoint.hostID, name: "Local", hostname: "localhost", username: "me", auth: .password)
    }

    override func tearDown() async throws {
        // Stop anything a failed test left running.
        _ = try? await executor.run("pkill -f \(ShellQuote.quote(root.path)) 2>/dev/null; true")
        try? FileManager.default.removeItem(at: root)
    }

    func runner() -> HostJobRunner {
        HostJobRunner(store: HostJobStore(directory: root.appendingPathComponent("store")), access: AccessPolicy.inMemory())
    }

    func plan(_ command: String, system: BuildSystem? = nil) throws -> BuildPlan {
        var plan = try BuildPlanner.custom(host: host, projectPath: project, command: command)
        if let system { plan.system = system }
        return plan
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ lines: [String]) { lock.lock(); stored += lines; lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testJobRunsDetachedAndReportsItsRealExitStatus() async throws {
        let runner = runner()
        let collected = Collected()
        let job = await runner.create(try plan("echo building in \"$PWD\"; echo token=abcdef123456; echo 'x.c:1:2: error: boom' >&2; exit 3"))
        let finished = await runner.drive(job.id, executor: executor) { collected.add($0) }
        XCTAssertEqual(finished?.state, .failed(exitStatus: 3))
        XCTAssertTrue(collected.lines.contains("building in \(project)"), "\(collected.lines)")
        // Redacted before it reached the console and the local log.
        XCTAssertTrue(collected.lines.contains("token=[REDACTED]"))
        let log = await runner.store.log(for: finished!)
        XCTAssertFalse(log.contains("abcdef123456"))
        XCTAssertTrue(log.contains("[hcg] PATH="), "the job records the environment it used")
        XCTAssertEqual(finished?.firstFailure?.line, "x.c:1:2: error: boom")
        XCTAssertEqual(finished?.firstFailure?.kind, "compiler")
    }

    func testStartingTheSameJobAgainNeverRunsItTwice() async throws {
        let counter = root.appendingPathComponent("count").path
        let job = await runner().create(try plan("echo run >> \(ShellQuote.quote(counter)); sleep 1"))
        let client = HostJobClient(executor: executor)
        let first = try await client.start(job)
        let second = try await client.start(job) // e.g. a retry after the reply was lost
        XCTAssertEqual(first, .started)
        XCTAssertEqual(second, .alreadyStarted)
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertEqual(try String(contentsOfFile: counter, encoding: .utf8), "run\n")
    }

    func testSecondBuildOfTheSameProjectIsRefusedWhileOneRuns() async throws {
        let runner = runner()
        let first = await runner.create(try plan("sleep 3"))
        let client = HostJobClient(executor: executor)
        _ = try await client.start(first)
        let second = await runner.create(try plan("echo second"))
        let refused = await runner.drive(second.id, executor: executor)
        guard case .couldNotStart(let reason)? = refused?.state else { return XCTFail("\(String(describing: refused?.state))") }
        XCTAssertTrue(reason.contains(first.shortID), reason)
        // After the first finishes, the lock is released.
        _ = await runner.drive(first.id, executor: executor)
        let third = await runner.create(try plan("echo third"))
        let done = await runner.drive(third.id, executor: executor)
        XCTAssertEqual(done?.state, .succeeded)
    }

    func testCancelStopsTheProcessGroupOnTheHost() async throws {
        let runner = runner()
        let marker = root.appendingPathComponent("after").path
        let job = await runner.create(try plan("sleep 30; touch \(ShellQuote.quote(marker))"))
        let follower = Task { await runner.drive(job.id, executor: executor) }
        try await Task.sleep(for: .seconds(1.5))
        let reply = try await runner.cancel(job.id, executor: executor)
        XCTAssertEqual(reply, "CANCELLED")
        let finished = await follower.value
        XCTAssertEqual(finished?.state, .cancelled)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the build command must not continue after cancel")
        let left = try await executor.run("pgrep -fx 'sleep 30' | wc -l").stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(left, "0")
    }

    func testFollowingResumesAtTheSavedOffsetWithoutRepeatingLines() async throws {
        let runner = runner()
        let job = await runner.create(try plan("for i in 1 2 3 4 5 6; do echo line $i; sleep 0.5; done"))
        let firstPass = Collected()
        // Follow briefly, then drop the follower as if the phone lost its connection.
        let follower = Task { await runner.drive(job.id, executor: executor) { firstPass.add($0) } }
        try await Task.sleep(for: .seconds(1.3))
        follower.cancel()
        let interrupted = await follower.value
        XCTAssertEqual(interrupted?.state, .running, "a dropped connection is not a failure")
        XCTAssertNotNil(interrupted?.disconnectedAt)
        // Reattach: the rest arrives, nothing twice, nothing started again.
        let secondPass = Collected()
        let finished = await runner.drive(job.id, executor: executor) { secondPass.add($0) }
        XCTAssertEqual(finished?.state, .succeeded)
        let all = (firstPass.lines + secondPass.lines).filter { $0.hasPrefix("line ") }
        XCTAssertEqual(all, (1...6).map { "line \($0)" })
        let log = await runner.store.log(for: finished!)
        XCTAssertEqual(log.components(separatedBy: "\n").filter { $0.hasPrefix("line ") }.count, 6)
    }

    func testTheosStyleBuildListsItsPackageWithChecksum() async throws {
        let runner = runner()
        let fakeMake = root.appendingPathComponent("fake-make.sh").path
        try "#!/bin/sh\nmkdir -p packages\nprintf 'deb-bytes' > packages/com.example.tweak_1.0_iphoneos-arm64.deb\necho '==> Done'\n".write(toFile: fakeMake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeMake)
        var plan = try BuildPlanner.plan(host: host, projectPath: project, system: .theos, action: .build, configuration: .release, gnuMake: fakeMake)
        XCTAssertTrue(plan.commandLine.hasSuffix("package FINALPACKAGE=1"))
        plan.hostID = host.id
        let job = await runner.create(plan)
        let finished = await runner.drive(job.id, executor: executor)
        XCTAssertEqual(finished?.state, .succeeded)
        let artifact = try XCTUnwrap(finished?.artifacts.first)
        XCTAssertEqual(artifact.kind, .deb)
        XCTAssertEqual(artifact.size, 9)
        // sha256("deb-bytes")
        let expected = try await executor.run("printf 'deb-bytes' | sha256sum | cut -d' ' -f1").stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(artifact.sha256, expected)
        XCTAssertEqual(artifact.jobID, job.id)
        XCTAssertTrue(artifact.remotePath.contains(".hcg-terminal/jobs/\(job.id.uuidString.lowercased())/artifacts/"))
    }

    func testRemovingAJobDeletesItsHostFolder() async throws {
        let runner = runner()
        let job = await runner.create(try plan("echo hi"))
        _ = await runner.drive(job.id, executor: executor)
        let jobDir = "\(home)/.hcg-terminal/jobs/\(job.id.uuidString.lowercased())"
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir))
        let removed = try await runner.removeEverywhere(job.id, executor: executor)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobDir))
        let gone = await runner.store.job(job.id)
        XCTAssertNil(gone)
    }

    func testReconcileAfterAppRestartFindsTheRunningJob() async throws {
        let directory = root.appendingPathComponent("store")
        let first = HostJobRunner(store: HostJobStore(directory: directory), access: AccessPolicy.inMemory())
        let job = await first.create(try plan("sleep 2; echo done"))
        _ = try await HostJobClient(executor: executor).start(job)
        // "Relaunch": a new store reads the saved job; the host still has it.
        let relaunched = HostJobRunner(store: HostJobStore(directory: directory), access: AccessPolicy.inMemory())
        let reconciled = try await relaunched.reconcile(job.id, executor: executor)
        XCTAssertEqual(reconciled?.state, .running)
        let finished = await relaunched.drive(job.id, executor: executor)
        XCTAssertEqual(finished?.state, .succeeded)
    }
}
#endif
