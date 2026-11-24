import FileWorkspace
import Foundation
import TerminalCore
import TerminalSecurity
@testable import TerminalUI
import XCTest

@MainActor
final class LaunchControllerTests: XCTestCase {
    var root: URL!
    var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-launch-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "hcg-launch-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func makeModel() -> TerminalAppModel {
        let workspace = try! FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        return TerminalAppModel(dependencies: AppDependencies.standard(
            workspace: workspace, supportDirectory: root.appendingPathComponent("support"),
            credentials: InMemoryCredentialStore(), preferences: ModePreferenceStore(defaults: defaults),
            access: .inMemory(), appearance: AppearanceStore(defaults: defaults)
        ))
    }

    private var journalDirectory: URL { root.appendingPathComponent("startup") }

    func testNormalLaunchCreatesTheModelAndBecomesReady() async {
        let journal = StartupJournal.begin(directory: journalDirectory, installCrashHandlers: false)
        let controller = LaunchController(journal: journal) { self.makeModel() }
        guard case .running(let model) = controller.stage else { return XCTFail("expected the app, not recovery") }
        XCTAssertFalse(model.safeMode)
        controller.interfaceAppeared()
        await model.bootstrap()
        controller.startupFinished()
        XCTAssertTrue(journal.isReady)
        XCTAssertNotNil(model.assessment)
        XCTAssertNil(StartupJournal.begin(directory: journalDirectory, installCrashHandlers: false).previous)
    }

    /// After a launch that died, the model is not even created until the user chooses.
    func testFailedLaunchShowsRecoveryFirstAndCreatesNothing() async {
        StartupJournal.begin(directory: journalDirectory, installCrashHandlers: false).phase("environment detection")
        let journal = StartupJournal.begin(directory: journalDirectory, installCrashHandlers: false)
        var created = 0
        let controller = LaunchController(journal: journal) { created += 1; return self.makeModel() }
        guard case .recovery(let previous) = controller.stage else { return XCTFail("expected the recovery screen") }
        XCTAssertEqual(previous.lastPhase, "environment detection")
        XCTAssertEqual(created, 0)
        XCTAssertTrue(controller.reportText.contains("environment detection"))
    }

    func testSafeModeSkipsDetectionUntilAskedAndThenRunsIt() async {
        StartupJournal.begin(directory: journalDirectory, installCrashHandlers: false).phase("environment detection")
        let journal = StartupJournal.begin(directory: journalDirectory, installCrashHandlers: false)
        let controller = LaunchController(journal: journal) { self.makeModel() }
        controller.start(safeMode: true)
        guard case .running(let model) = controller.stage else { return XCTFail("expected the app") }
        XCTAssertTrue(model.safeMode)
        await model.bootstrap()
        controller.startupFinished()
        XCTAssertTrue(model.reports.isEmpty, "Safe Mode must not run environment detection")
        XCTAssertNil(model.assessment)
        XCTAssertTrue(journal.isReady)

        await model.runSkippedStartupSteps()
        XCTAssertFalse(model.safeMode)
        XCTAssertFalse(model.reports.isEmpty)
        XCTAssertNotNil(model.assessment)
    }
}
