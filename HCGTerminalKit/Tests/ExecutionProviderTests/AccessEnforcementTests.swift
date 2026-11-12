import Diagnostics
import FileWorkspace
import Foundation
import LocalCommandEngine
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
import TerminalTestSupport
@testable import UnleashedExecutionProvider
import VanillaExecutionProvider
import XCTest

/// Switches are enforced by the services themselves, whatever the interface does.
final class AccessEnforcementTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-access-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: Vanilla

    func testWorkspaceCommandsOffRefusesNewSessionsAndCommandsInOpenOnes() async throws {
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        let access = AccessPolicy.inMemory()
        let provider = VanillaExecutionProvider(workspace: workspace, capabilities: VanillaCapabilityProvider(workspace: workspace), access: access)
        let made = try await provider.makeSession()
        let session = try XCTUnwrap(made as? BuiltinShellSession)
        let ran = await session.runForTesting("mkdir /home/a")
        XCTAssertEqual(ran, 0)

        access.set(.workspaceCommands, enabled: false)
        let refused = await session.runForTesting("mkdir /home/b")
        XCTAssertEqual(refused, 126)
        XCTAssertFalse(workspace.exists(try WorkspacePath("/home/b")), "the refused command did not run")
        do {
            _ = try await provider.makeSession()
            XCTFail("a new session must be refused")
        } catch let denied as AccessDenied {
            XCTAssertEqual(denied.control, .workspaceCommands)
        }
        XCTAssertTrue(workspace.exists(try WorkspacePath("/home/a")), "files are kept")
    }

    func testExternalFilesOffRefusesImportAndExport() throws {
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        let source = root.appendingPathComponent("outside.txt")
        try Data("x".utf8).write(to: source)
        let off = AccessPolicy.inMemory()
        off.set(.externalFiles, enabled: false)
        XCTAssertThrowsError(try workspace.importItem(from: source, into: .home, policy: .fail, access: off)) {
            XCTAssertEqual(($0 as? AccessDenied)?.control, .externalFiles)
        }
        XCTAssertThrowsError(try workspace.exportURL(for: .home, access: off))
        XCTAssertNoThrow(try workspace.importItem(from: source, into: .home, policy: .fail, access: .inMemory()))
    }

    // MARK: Unleashed filesystem

    func testExpandedReadAndWriteAreEnforcedSeparately() async throws {
        let folder = root.appendingPathComponent("permitted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))

        let readOnly = AccessPolicy.inMemory() // default: read on, write off
        let files = HostFileSystem(roots: [folder.path], gate: nil, needsApproval: { _ in false }, access: readOnly)
        XCTAssertEqual(try files.list(folder.path).map(\.name), ["a.txt"])
        XCTAssertEqual(try files.list(folder.path).first?.writable, false, "not offered for writing while write is off")
        XCTAssertFalse(files.isWritable(folder.appendingPathComponent("a.txt").path))
        do {
            try await files.writeText("changed", to: folder.appendingPathComponent("a.txt").path)
            XCTFail("write must be refused")
        } catch let denied as AccessDenied {
            XCTAssertEqual(denied.control, .expandedFileWrite)
        }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "hello")

        readOnly.set(.expandedFileRead, enabled: false)
        XCTAssertThrowsError(try files.list(folder.path)) { XCTAssertEqual(($0 as? AccessDenied)?.control, .expandedFileRead) }
        XCTAssertThrowsError(try files.readText(folder.appendingPathComponent("a.txt").path))

        // Write on but read off: write is blocked by its prerequisite.
        readOnly.set(.expandedFileWrite, enabled: true)
        do {
            try await files.writeText("changed", to: folder.appendingPathComponent("a.txt").path)
            XCTFail("write needs read")
        } catch let denied as AccessDenied {
            XCTAssertEqual(denied, AccessDenied(control: .expandedFileWrite, blockedBy: .expandedFileRead))
        }
    }

    func testWriteTestCleansUpAndIsRefusedWhenWriteIsOff() async throws {
        let folder = root.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let off = HostFileSystem(roots: [folder.path], gate: nil, needsApproval: { _ in false }, access: .inMemory())
        let refused = await off.verifyWriteAccess(in: folder.path)
        XCTAssertFalse(refused.succeeded)
        XCTAssertTrue(refused.outcome.contains("turned off"), refused.outcome)

        let on = HostFileSystem(roots: [folder.path], gate: nil, needsApproval: { _ in false }, access: .allEnabled())
        let result = await on.verifyWriteAccess(in: folder.path)
        XCTAssertTrue(result.succeeded, result.outcome)
        XCTAssertTrue(result.outcome.contains("removed"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "no test file is left behind")
    }

    // MARK: Packages, processes, privileges

    func testPackageManagementOffRefusesListingAndChangesWithoutAsking() async throws {
        var scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.rootlessDevice).scan()
        scan.packageManagers = [DetectedTool(name: "apt", path: "/var/jb/usr/bin/apt"), DetectedTool(name: "dpkg-query", path: "/var/jb/usr/bin/dpkg-query")]
        let asked = LockedCounter()
        let access = AccessPolicy.inMemory()
        access.set(.packageManagement, enabled: false)
        let gate = AuthorizationGate(presenter: { _ in asked.increment(); return true }, access: access)
        let client = PackageManagerClient(scan: scan, gate: gate, access: access)
        do { _ = try await client.listInstalled(); XCTFail() } catch let denied as AccessDenied { XCTAssertEqual(denied.control, .packageManagement) }
        do { _ = try await client.authorizedCommand(for: .install("htop")); XCTFail() } catch let denied as AccessDenied { XCTAssertEqual(denied.control, .packageManagement) }
        XCTAssertEqual(asked.value, 0, "the user is not asked about something that is turned off")

        // Package changes run in a local shell: turning the shell off refuses them, while the
        // inventory itself does not need the shell.
        access.set(.packageManagement, enabled: true)
        access.set(.localShell, enabled: false)
        do { _ = try await client.authorizedCommand(for: .install("htop")); XCTFail() } catch let denied as AccessDenied {
            XCTAssertEqual(denied, AccessDenied(control: .localShell))
        }
        XCTAssertNoThrow(try access.require(.packageManagement))
        // The master switch blocks everything Unleashed.
        access.set(.unleashedFeatures, enabled: false)
        do { _ = try await client.listInstalled(); XCTFail() } catch let denied as AccessDenied {
            XCTAssertEqual(denied, AccessDenied(control: .packageManagement, blockedBy: .unleashedFeatures))
        }
    }

    func testPrivilegedRequestsAreRefusedWithoutAskingWhileOff() async {
        let asked = LockedCounter()
        let access = AccessPolicy.inMemory() // privileged operations default off
        let gate = AuthorizationGate(presenter: { _ in asked.increment(); return true }, access: access)
        let assessment = PrivilegeClassifier.assess("sudo reboot")
        XCTAssertEqual(assessment.requiredAccess, [.privilegedOperations])
        let request = AuthorizationRequest(title: "x", commandLine: "sudo reboot", target: .local(.unleashed), reasons: assessment.reasons, requiredAccess: assessment.requiredAccess)
        let refused = await gate.decide(request)
        XCTAssertEqual(refused, .refused(AccessDenied(control: .privilegedOperations)))
        XCTAssertEqual(asked.value, 0)
        access.set(.privilegedOperations, enabled: true)
        let approved = await gate.decide(request)
        XCTAssertEqual(approved, .approved)
        XCTAssertEqual(asked.value, 1)
        XCTAssertEqual(PrivilegeClassifier.assess("apt install htop").requiredAccess, [.packageManagement])
    }

    func testProcessInspectionOffDoesNotReadTheTable() {
        let access = AccessPolicy.inMemory()
        access.set(.processInspection, enabled: false)
        guard case .disabled(let reason) = ProcessInspector.listProcesses(access: access) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Process inspection"))
    }

    // MARK: Local shell

    func testShellOffRefusesNewSessionsAndInputToOpenOnesThenStopConfirmsExit() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        let access = AccessPolicy.inMemory()
        access.set(.localShell, enabled: false)
        let refused = LocalProcessSession(executable: "/bin/sh", arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", observations: RuntimeObservations(), gate: AuthorizationGate(access: access), access: access)
        do { try await refused.start(size: .standard); XCTFail() } catch let denied as AccessDenied { XCTAssertEqual(denied.control, .localShell) }

        access.set(.localShell, enabled: true)
        let marker = root.appendingPathComponent("ran")
        let session = LocalProcessSession(executable: "/bin/sh", arguments: [], environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "], workingDirectory: "/", observations: RuntimeObservations(), gate: AuthorizationGate(access: access), access: access)
        let events = session.events
        let notices = Task { () -> [String] in
            var seen: [String] = []
            for await event in events { if case .notice(let notice) = event { seen.append(notice.message) } }
            return seen
        }
        try await session.start(size: .standard)
        access.set(.localShell, enabled: false)
        try await session.send(text: "touch '\(marker.path)'\r")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "input is not passed to the shell while off")
        let outcome = await session.stop()
        guard case .processExited = outcome else { return XCTFail("\(outcome)") }
        let messages = await notices.value
        XCTAssertTrue(messages.contains { $0.contains("Input not sent") }, "\(messages)")
    }

    func testProviderRefusesWhenShellIsOff() async {
        let access = AccessPolicy.inMemory()
        access.set(.localShell, enabled: false)
        let observations = RuntimeObservations()
        let provider = UnleashedExecutionProvider(
            capabilities: UnleashedCapabilityProvider(probe: ScriptedProbe.rootlessDevice, observations: observations),
            observations: observations, gate: AuthorizationGate(access: access), access: access
        )
        do { _ = try await provider.makeSession(); XCTFail() } catch let denied as AccessDenied { XCTAssertEqual(denied.control, .localShell) } catch { XCTFail("\(error)") }
    }

    // MARK: Programs and explicit shell test

    func testProgramsRunBoundedWithAccurateErrors() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/echo") && FileManager.default.isExecutableFile(atPath: "/bin/sleep"))
        var scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice).scan()
        scan.executableDirectories = ["/bin": 2]
        scan.pretendShell("/bin/sh")
        let access = AccessPolicy.inMemory()
        let operations = UnleashedOperations(scan: scan, observations: RuntimeObservations(), gate: AuthorizationGate(access: access), access: access)

        let echo = try await operations.run("/bin/echo", arguments: ["hello", "HCG"])
        XCTAssertEqual(echo.stdout, "hello HCG\n")
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(echo.summary, "Exited with status 0.")

        let slow = try await operations.run("/bin/sleep", arguments: ["5"], timeout: 0.5)
        XCTAssertTrue(slow.timedOut)
        XCTAssertTrue(slow.summary.contains("time limit"))

        do { _ = try await operations.run("/usr/local/bin/not-there", arguments: []); XCTFail() } catch let error as ToolLaunchError {
            XCTAssertEqual(error, .notInEnvironment("/usr/local/bin/not-there"))
        }

        let shellTest = await operations.verifyShell()
        XCTAssertTrue(shellTest.succeeded, shellTest.outcome)

        access.set(.localShell, enabled: false)
        do { _ = try await operations.run("/bin/echo", arguments: []); XCTFail() } catch let denied as AccessDenied { XCTAssertEqual(denied.control, .localShell) }
        let refusedTest = await operations.verifyShell()
        XCTAssertFalse(refusedTest.succeeded)
    }

    func testSpawnErrnoIsTranslatedAccurately() {
        XCTAssertEqual(ToolLaunchError.from(ProcessSpawnError.spawn(executable: "/x", errno: EPERM, message: "Operation not permitted"), path: "/x"), .refusedBySystem("/x", errno: EPERM))
        XCTAssertEqual(ToolLaunchError.from(ProcessSpawnError.spawn(executable: "/x", errno: ENOEXEC, message: "Exec format error"), path: "/x"), .notARunnableProgram("/x"))
        XCTAssertTrue(ToolLaunchError.refusedBySystem("/x", errno: EPERM).localizedDescription.contains("sandbox"))
        let killed = ToolRunResult(commandLine: "/x", status: 137, stdout: "", stderr: "", timedOut: false, signal: SIGKILL, duration: 0.1)
        XCTAssertTrue(killed.summary.contains("code signature"))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
