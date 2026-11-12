import FileWorkspace
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
@testable import TerminalUI
import XCTest

/// Settings changes that affect running sessions: explained first, cancellable, and applied
/// with a controlled stop that reports only what is known.
@MainActor
final class AccessTransitionTests: XCTestCase {
    var root: URL!
    var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-transition-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "hcg-test-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func makeModel(_ access: AccessPolicy) throws -> TerminalAppModel {
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        return TerminalAppModel(dependencies: AppDependencies.standard(
            workspace: workspace, supportDirectory: root.appendingPathComponent("support"),
            credentials: InMemoryCredentialStore(), preferences: ModePreferenceStore(defaults: defaults),
            access: access, appearance: AppearanceStore(defaults: defaults)
        ))
    }

    func testTurningOffWithAnOpenSessionAsksFirstAndCancelKeepsEverything() async throws {
        let access = AccessPolicy.inMemory()
        let model = try makeModel(access)
        await model.bootstrap()
        let opened = await model.openLocalSession()
        let session = try XCTUnwrap(opened)

        await model.requestAccessChange(.workspaceCommands, enabled: false)
        let request = try XCTUnwrap(model.pendingAccessChange)
        XCTAssertEqual(request.sessions.map(\.id), [session.id])
        XCTAssertTrue(access.isOn(.workspaceCommands), "nothing is applied before confirmation")

        model.cancelAccessChange()
        XCTAssertNil(model.pendingAccessChange)
        XCTAssertTrue(access.isOn(.workspaceCommands))
        XCTAssertTrue(session.isLive)
    }

    func testConfirmingStopsAffectedSessionsButKeepsThemListed() async throws {
        let access = AccessPolicy.inMemory()
        let model = try makeModel(access)
        await model.bootstrap()
        let openedLocal = await model.openLocalSession()
        let local = try XCTUnwrap(openedLocal)
        let remote = SessionModel(session: FakeRemoteSession(endpoint: RemoteEndpoint(hostID: UUID(), displayName: "Mac", hostname: "mac", username: "a")), title: "Mac", modeAtCreation: .vanilla)
        remote.attach()
        try await remote.session.start(size: .standard)
        try await Task.sleep(nanoseconds: 50_000_000)
        model.sessionsForTesting.append(remote)

        await model.requestAccessChange(.remoteSSH, enabled: false)
        let request = try XCTUnwrap(model.pendingAccessChange)
        XCTAssertEqual(request.sessions.map(\.id), [remote.id], "only SSH sessions are affected")
        XCTAssertTrue(request.sessions[0].consequence.contains("cannot confirm"))
        XCTAssertEqual(Set(request.newlyDisabled), [.remoteSSH, .remoteBuilds])

        await model.confirmAccessChange()
        XCTAssertFalse(access.isOn(.remoteSSH))
        XCTAssertFalse(remote.isLive)
        XCTAssertTrue(local.isLive, "the local session is untouched")
        XCTAssertEqual(model.sessions.count, 2, "session history is kept")
        let outcome = try XCTUnwrap(model.accessChangeOutcome)
        XCTAssertTrue(outcome.contains("not verified"), outcome)
        XCTAssertFalse(outcome.lowercased().contains("terminated"))
    }

    func testChangesWithoutRunningWorkApplyAtOnceAndWideningAsksFirst() async throws {
        let access = AccessPolicy.inMemory()
        let model = try makeModel(access)
        await model.bootstrap()
        await model.requestAccessChange(.processInspection, enabled: false)
        XCTAssertNil(model.pendingAccessChange)
        XCTAssertFalse(access.isOn(.processInspection))
        XCTAssertFalse(model.accessSettings.isOn(.processInspection))

        await model.requestAccessChange(.privilegedOperations, enabled: true)
        XCTAssertNotNil(model.pendingAccessChange?.caution)
        XCTAssertFalse(access.isOn(.privilegedOperations))
        await model.confirmAccessChange()
        XCTAssertTrue(access.isOn(.privilegedOperations))
    }

    func testStandardBuildShowsUnleashedSwitchesAsNotIncludedAndSwitchesNeverTurnThingsGreen() async throws {
        let access = AccessPolicy.allEnabled()
        let model = try makeModel(access)
        await model.bootstrap()
        guard case .notIncluded = model.detectedAvailability(for: .localShell) else { return XCTFail() }
        guard case .notIncluded = model.effectiveAvailability(for: .expandedFileWrite) else { return XCTFail() }
        XCTAssertNil(model.detectedAvailability(for: .externalFiles))
        await model.requestAccessChange(.workspaceCommands, enabled: false)
        guard case .disabledByUser = model.effectiveAvailability(for: .workspaceCommands) else { return XCTFail() }
        guard case .verified = model.detectedAvailability(for: .workspaceCommands) else { return XCTFail("detection is unchanged by the switch") }
        let opened = await model.openLocalSession()
        XCTAssertNil(opened)
        XCTAssertEqual(model.errorMessage, AccessDenied(control: .workspaceCommands).localizedDescription)
    }

    func testModeSwitchNeverDisconnectsSSH() async throws {
        let model = try makeModel(.inMemory())
        await model.bootstrap()
        let fake = FakeRemoteSession(endpoint: RemoteEndpoint(hostID: UUID(), displayName: "Mac", hostname: "mac", username: "a"))
        let remote = SessionModel(session: fake, title: "Mac", modeAtCreation: .vanilla)
        model.sessionsForTesting.append(remote)
        model.selectMode(.unleashed)
        model.selectMode(.vanilla)
        let closes = await fake.closeCount
        XCTAssertEqual(closes, 0)
    }

    func testAppearancePersists() async throws {
        let model = try makeModel(.inMemory())
        model.updateAppearance { $0.theme = .system; $0.accent = .silver; $0.reducedEffects = true; $0.terminalFontSize = 40 }
        let reloaded = AppearanceStore(defaults: defaults).settings
        XCTAssertEqual(reloaded.theme, .system)
        XCTAssertEqual(reloaded.accent, .silver)
        XCTAssertTrue(reloaded.reducedEffects)
        XCTAssertEqual(reloaded.terminalFontSize, AppearanceSettings.terminalFontRange.upperBound, "clamped")
    }
}
