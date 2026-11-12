import Foundation
import TerminalCore
import XCTest

final class AccessPolicyTests: XCTestCase {
    func testDefaultsAreReadOnlyExpandedAccessAndNoPrivilegedOperations() {
        let policy = AccessPolicy.inMemory()
        XCTAssertFalse(policy.isEnabled(.expandedFileWrite))
        XCTAssertFalse(policy.isEnabled(.privilegedOperations))
        for control in AccessControl.allCases where ![.expandedFileWrite, .privilegedOperations].contains(control) {
            XCTAssertTrue(policy.isEnabled(control), control.rawValue)
        }
    }

    func testDisablingAPrerequisiteDisablesDependents() throws {
        let policy = AccessPolicy.allEnabled()
        XCTAssertEqual(Set(policy.newlyDisabled(ifSetting: .localShell, to: false)), [.localShell, .packageManagement, .privilegedOperations])
        XCTAssertEqual(Set(policy.newlyDisabled(ifSetting: .remoteSSH, to: false)), [.remoteSSH, .remoteBuilds])
        XCTAssertEqual(Set(policy.newlyDisabled(ifSetting: .expandedFileRead, to: false)), [.expandedFileRead, .expandedFileWrite])
        policy.set(.localShell, enabled: false)
        XCTAssertTrue(policy.isOn(.packageManagement), "the user's own choice is kept")
        XCTAssertFalse(policy.isEnabled(.packageManagement), "but it is not in effect")
        XCTAssertThrowsError(try policy.require(.packageManagement)) { error in
            XCTAssertEqual(error as? AccessDenied, AccessDenied(control: .packageManagement, blockedBy: .localShell))
            XCTAssertTrue(error.localizedDescription.contains("needs"))
        }
        policy.set(.localShell, enabled: true)
        XCTAssertNoThrow(try policy.require(.packageManagement))
    }

    func testSettingsPersistAndUnknownKeysSurvive() throws {
        let suite = "hcg-access-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AccessPolicy(storage: UserDefaultsAccessStorage(defaults: defaults))
        first.set(.remoteSSH, enabled: false)
        first.set(.expandedFileWrite, enabled: true)
        let reloaded = AccessPolicy(storage: UserDefaultsAccessStorage(defaults: defaults))
        XCTAssertFalse(reloaded.isOn(.remoteSSH))
        XCTAssertTrue(reloaded.isOn(.expandedFileWrite))
        XCTAssertTrue(reloaded.isOn(.workspaceCommands), "unset keys use the default")

        var future = reloaded.settings
        future.values["someFutureSwitch"] = true
        let storage = MemoryAccessStorage(future)
        let policy = AccessPolicy(storage: storage)
        policy.set(.processInspection, enabled: false)
        XCTAssertEqual(storage.load().values["someFutureSwitch"], true)
    }

    func testObserversAndReset() {
        let policy = AccessPolicy.inMemory()
        let seen = LockedBox<[Bool]>([])
        let token = policy.observe { settings in seen.mutate { $0.append(settings.isOn(.remoteSSH)) } }
        policy.set(.remoteSSH, enabled: false)
        policy.resetToDefaults()
        policy.removeObserver(token)
        policy.set(.remoteSSH, enabled: false)
        XCTAssertEqual(seen.value, [false, true])
    }

    func testEveryControlExplainsBothStatesAndActiveSessions() {
        for control in AccessControl.allCases {
            XCTAssertFalse(control.whenOn.isEmpty)
            XCTAssertFalse(control.whenOff.isEmpty)
            XCTAssertFalse(control.activeSessionEffect.isEmpty)
            XCTAssertNotEqual(control.whenOn, control.whenOff)
        }
        XCTAssertTrue(AccessControl.remoteSSH.activeSessionEffect.contains("cannot confirm"), "remote termination is never claimed")
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
