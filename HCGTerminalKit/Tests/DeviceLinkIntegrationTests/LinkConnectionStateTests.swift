@testable import DeviceLinkIntegration
import Foundation
import HCGDeviceLink
import XCTest

final class LinkConnectionStateTests: XCTestCase {
    private func serverError(_ status: Int, _ code: String, retryable: Bool? = nil, retryAfter: Int? = nil) -> DeviceLinkError {
        var object: [String: Any] = ["error": "Refused (\(code))", "code": code]
        if let retryable { object["retryable"] = retryable }
        if let retryAfter { object["retryAfterSeconds"] = retryAfter }
        let body = try! JSONDecoder().decode(LinkErrorBody.self, from: JSONSerialization.data(withJSONObject: object))
        return .server(status: status, body: body)
    }

    func testErrorsThatEndTheLinkStopSyncing() {
        for code in ["device_revoked", "unknown_installation", "wrong_account", "app_mismatch", "access_revoked"] {
            var machine = LinkConnectionMachine()
            let outcome = machine.failed(serverError(403, code))
            XCTAssertNil(outcome.retryIn, code)
            guard case .removed(let reason) = outcome.state else { return XCTFail("\(code): \(outcome.state)") }
            XCTAssertFalse(reason.isEmpty)
        }
        var machine = LinkConnectionMachine()
        let pin = machine.failed(.transport(.pinMismatch))
        XCTAssertNil(pin.retryIn)
        guard case .removed = pin.state else { return XCTFail("\(pin.state)") }
    }

    func testEndedHCGSessionAsksToSignInAgain() {
        var machine = LinkConnectionMachine()
        let outcome = machine.failed(serverError(401, "hcg_session_ended"))
        XCTAssertNil(outcome.retryIn)
        guard case .signInEnded(let reason) = outcome.state else { return XCTFail("\(outcome.state)") }
        XCTAssertTrue(reason.contains("Sign in"))
    }

    func testNotSignedInStops() {
        var machine = LinkConnectionMachine()
        let outcome = machine.failed(.notSignedIn("Sign in"))
        XCTAssertEqual(outcome.state, .signedOut)
        XCTAssertNil(outcome.retryIn)
    }

    func testRetryableErrorsBackOffExponentiallyAndSuccessResets() {
        var machine = LinkConnectionMachine()
        let delays = (0..<8).map { _ in machine.failed(.transport(.unreachable("timed out")), random: 0).retryIn }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 60, 60])
        guard case .offline(let retry, let reason) = machine.failed(.transport(.unreachable("timed out")), random: 0).state else { return XCTFail() }
        XCTAssertEqual(retry, 60)
        XCTAssertTrue(reason.contains("could not be reached"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(machine.succeeded(at: now), .connected(lastSync: now))
        XCTAssertEqual(machine.failures, 0)
        XCTAssertEqual(machine.failed(serverError(503, "hcg_unavailable", retryable: true), random: 0).retryIn, 1)
    }

    func testRetryAfterIsHonoured() {
        var machine = LinkConnectionMachine()
        XCTAssertEqual(machine.failed(serverError(503, "hcg_unavailable", retryable: true, retryAfter: 30), random: 0).retryIn, 30)
    }

    func testJitterStaysWithinTwentyPercent() {
        var machine = LinkConnectionMachine()
        _ = machine.failed(.transport(.unreachable("x")), random: 0)
        _ = machine.failed(.transport(.unreachable("x")), random: 0)
        let high = machine.failed(.transport(.unreachable("x")), random: 1).retryIn ?? 0
        XCTAssertEqual(high, 4 * 1.2, accuracy: 0.0001)
    }

    func testNonRetryableErrorsWaitTheLongestInterval() {
        var machine = LinkConnectionMachine()
        let outcome = machine.failed(serverError(403, "permission_denied", retryable: false), random: 0)
        XCTAssertEqual(outcome.retryIn, 60)
        guard case .offline = outcome.state else { return XCTFail("\(outcome.state)") }
    }

    func testRestingStates() throws {
        let fp = InvitationFixture.serverFingerprint
        let invitation = InvitationFixture.invitation()
        let ready = HCGConnectSetup.ready(HCGConnectConfiguration(contractVersion: HCGConnectSetup.contract, clientId: UUID().uuidString, redirectUri: "hcgterminal://cb"))

        XCTAssertEqual(LinkConnectionMachine.resting(connect: .notConfigured("no client"), signedIn: true, pairing: nil, deviceFingerprint: nil),
                       .notConfigured(reason: "no client"))
        XCTAssertEqual(LinkConnectionMachine.resting(connect: ready, signedIn: false, pairing: nil, deviceFingerprint: nil), .signedOut)
        XCTAssertEqual(LinkConnectionMachine.resting(connect: ready, signedIn: true, pairing: nil, deviceFingerprint: nil), .notPaired(note: nil))

        let pending = PairingRecord(invitation: invitation, requestId: "req_1", status: .pending)
        XCTAssertEqual(LinkConnectionMachine.resting(connect: ready, signedIn: true, pairing: pending, deviceFingerprint: "bb"),
                       .pairing(PairingProgress(pending: true, requestId: "req_1", serverName: "Studio Mac", serverFingerprint: fp, deviceFingerprint: "bb")))
        var approved = pending
        approved.status = .approved
        XCTAssertEqual(LinkConnectionMachine.resting(connect: ready, signedIn: true, pairing: approved, deviceFingerprint: "bb"), .connected(lastSync: nil))
        var rejected = pending
        rejected.status = .rejected
        guard case .notPaired(let note?) = LinkConnectionMachine.resting(connect: ready, signedIn: true, pairing: rejected, deviceFingerprint: nil) else {
            return XCTFail()
        }
        XCTAssertTrue(note.contains("rejected"))
    }

    func testStateTexts() {
        XCTAssertEqual(LinkConnectionState.connected(lastSync: nil).title, "Connected")
        XCTAssertTrue(LinkConnectionState.offline(retryIn: 4.2, reason: "Unreachable.").detail.contains("Retrying in 5 s"))
        XCTAssertTrue(LinkConnectionState.connected(lastSync: nil).isLinked)
        XCTAssertFalse(LinkConnectionState.signedOut.isLinked)
    }
}

final class HCGConnectSetupTests: XCTestCase {
    func testShippedFileHasNoClientAndIsNotConfigured() throws {
        // HCGTerminal/Resources/hcg-connect.json, as shipped in both apps.
        let shipped = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HCGTerminal/Resources/hcg-connect.json")
        guard FileManager.default.fileExists(atPath: shipped.path) else {
            throw XCTSkip("The repository checkout is not visible to this test process (\(shipped.path)).")
        }
        let data = try Data(contentsOf: shipped)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["clientId"], "No HCG Connect client ID has been issued; none may be shipped")
        XCTAssertEqual(object["contractVersion"] as? String, HCGConnectSetup.contract)
        XCTAssertEqual(HCGConnectSetup.evaluate(data), .notConfigured(HCGConnectSetup.noClientMessage))
        XCTAssertEqual(HCGConnectSetup.load(candidates: [shipped]), .notConfigured(HCGConnectSetup.noClientMessage))
    }

    func testMissingFileIsNotConfigured() {
        let nowhere = URL(fileURLWithPath: "/nonexistent/hcg-connect.json")
        XCTAssertEqual(HCGConnectSetup.load(candidates: [nowhere]), .notConfigured(HCGConnectSetup.noClientMessage))
        XCTAssertEqual(HCGConnectSetup.load(candidates: []), .notConfigured(HCGConnectSetup.noClientMessage))
        XCTAssertTrue(HCGConnectSetup.noClientMessage.contains("Nothing is contacted"))
    }

    func testSecretsAndUnknownKeysAreRefused() {
        let secret = Data(#"{"contractVersion":"hcg.terminal.connect/1","clientId":"4f1e7c1a-0000-4000-8000-000000000001","clientSecret":"x"}"#.utf8)
        guard case .notConfigured(let why) = HCGConnectSetup.evaluate(secret) else { return XCTFail() }
        XCTAssertTrue(why.contains("secret"))
        let unknown = Data(#"{"contractVersion":"hcg.terminal.connect/1","extra":1}"#.utf8)
        guard case .notConfigured = HCGConnectSetup.evaluate(unknown) else { return XCTFail() }
    }

    func testWrongContractIsRefused() {
        let data = Data(#"{"contractVersion":"hcg.sentinel.connect/1","clientId":"4f1e7c1a-0000-4000-8000-000000000001","redirectUri":"x://cb"}"#.utf8)
        guard case .notConfigured(let why) = HCGConnectSetup.evaluate(data) else { return XCTFail() }
        XCTAssertTrue(why.contains("hcg.sentinel.connect/1"))
    }

    func testIssuedClientIsReady() {
        let data = Data(#"{"contractVersion":"hcg.terminal.connect/1","clientId":"4f1e7c1a-0000-4000-8000-000000000001","redirectUri":"hcgterminal://oauth"}"#.utf8)
        guard case .ready(let configuration) = HCGConnectSetup.evaluate(data) else { return XCTFail() }
        XCTAssertEqual(configuration.issuer, HCGConnectConfiguration.defaultIssuer)
    }

    func testKeychainServiceSeparatesVariants() {
        XCTAssertEqual(DeviceLinkEnvironment.keychainService(bundleIdentifier: "com.hakmicapitalgroup.hcgterminal"),
                       "com.hakmicapitalgroup.hcgterminal.devicelink")
        XCTAssertNotEqual(DeviceLinkEnvironment.keychainService(bundleIdentifier: "com.hakmicapitalgroup.hcgterminal.unleashed"),
                          DeviceLinkEnvironment.keychainService(bundleIdentifier: "com.hakmicapitalgroup.hcgterminal"))
    }
}
