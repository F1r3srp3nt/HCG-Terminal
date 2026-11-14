@testable import DeviceLinkIntegration
import Foundation
import HCGDeviceLink
import TerminalCapabilityProvider
import TerminalCore
import XCTest

/// Builds `hcg1-…` invitation codes the way HCG Server does.
enum InvitationFixture {
    static let serverFingerprint = String(repeating: "5e", count: 32)

    static func code(expires: Date = Date().addingTimeInterval(600)) -> String {
        let payload: [String: Any] = [
            "v": 1, "id": "inv_test", "s": "single-use-secret", "hd": "dev_host", "hn": "Studio Mac",
            "ha": "192.168.1.10:7610", "fp": serverFingerprint, "exp": LinkJSON.formatDate(expires),
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "hcg1-" + LinkCrypto.base64URL(data)
    }

    static func invitation() -> Invitation { try! Invitation.parse(code()) }
}

/// A scripted HCG Server: answers Device Link paths and records every request.
final class FakeLinkServer: LinkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [LinkHTTPRequest] = []
    var pairStatus = "pending"
    /// When set, every request is answered with this error.
    var failure: (status: Int, code: String, retryable: Bool)?
    var installationFingerprint = ""

    var requests: [LinkHTTPRequest] { lock.withLock { _requests } }
    func requests(_ suffix: String) -> [LinkHTTPRequest] { requests.filter { $0.url.path.hasSuffix(suffix) } }

    static let time = "2026-11-14T10:00:00Z"

    func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse {
        lock.withLock { _requests.append(request) }
        if let failure = lock.withLock({ self.failure }) {
            return json(failure.status, #"{"error":"Refused: \#(failure.code)","code":"\#(failure.code)","retryable":\#(failure.retryable),"protocol":"hcg.devicelink/1"}"#)
        }
        let path = request.url.path
        let host = #"{"deviceId":"dev_host","name":"Studio Mac","fingerprint":"\#(InvitationFixture.serverFingerprint)"}"#
        switch (request.method, path) {
        case ("POST", "/peer/v1/link/pair"):
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let installation = body["installation"] as! [String: Any]
            let spki = Data(base64Encoded: installation["publicKey"] as! String)!
            let fp = LinkCrypto.fingerprint(spki: spki)
            lock.withLock { installationFingerprint = fp }
            return json(202, #"{"requestId":"req_1","status":"pending","host":\#(host),"keyFingerprint":"\#(fp)","expiresAt":"2026-11-14T10:30:00Z"}"#)
        case ("GET", "/peer/v1/link/pair/req_1"):
            let fp = lock.withLock { installationFingerprint }
            return json(200, #"{"requestId":"req_1","status":"\#(pairStatus)","host":\#(host),"keyFingerprint":"\#(fp)","expiresAt":"2026-11-14T10:30:00Z"}"#)
        case ("POST", "/peer/v1/link/heartbeat"):
            return json(200, #"{"state":"online","lastSeenAt":"\#(Self.time)","serverTime":"\#(Self.time)"}"#)
        case ("GET", "/peer/v1/link/devices"):
            let me = request.headers[DeviceLinkProtocol.Header.installation] ?? ""
            // The server's view of this installation claims everything is verified: it must not matter.
            let claimed = #"[{"id":"terminal.privileged","state":"verified","verifiedAt":"\#(Self.time)","evidence":"server says so"},{"id":"terminal.local.shell","state":"verified"}]"#
            return json(200, #"""
            {"protocol":"hcg.devicelink/1","host":\#(host),"self":"\#(me)","boundary":null,"onlineWindowSeconds":45,
             "installations":[
              {"installationId":"\#(me)","name":"This iPhone","platform":"iOS 18","app":"hcg.terminal","appVersion":"1.0","variant":"vanilla",
               "keyFingerprint":"aa","protocolVersions":[1],"capabilities":\#(claimed),"account":{"subject":"sub"},"pairedAt":"\#(Self.time)",
               "lastSeenAt":"\#(Self.time)","state":"online"},
              {"installationId":"0b6c2b8e-0000-4000-8000-000000000002","name":"Ana's iPhone","platform":"iOS 18","app":"hcg.sentinel","appVersion":"1.4.0",
               "variant":"vanilla","keyFingerprint":"bb","protocolVersions":[1],"capabilities":[{"id":"report.send","state":"available"}],
               "account":{"subject":"sub"},"pairedAt":"\#(Self.time)","state":"never-seen"}]}
            """#)
        case ("GET", "/peer/v1/link/approvals"):
            return json(200, #"{"approvals":[],"executionEnabled":true,"note":"Action execution is disabled in this milestone."}"#)
        case ("GET", "/peer/v1/link/inbox"):
            return json(200, #"{"messages":[\#(header(status: "queued"))]}"#)
        case ("GET", "/peer/v1/link/messages/m1"):
            let report = #"""
            {"schema":"hcg.diagnostic-report/1","reportId":"7d0c1c5e-0000-4000-8000-000000000003","kind":"security-lab.exposure-check",
             "title":"Exposure Check","origin":{"app":"hcg.sentinel","appVersion":"1.4.0","installationId":"0b6c2b8e-0000-4000-8000-000000000002","deviceName":"Ana's iPhone"},
             "createdAt":"\#(Self.time)","redaction":{"policy":"hcg.redaction/1","applied":true},
             "summary":{"status":"completed","highestSeverity":"medium","findingCount":1},"scope":["https://example.test"],
             "findings":[{"title":"Run this: `rm -rf ~` [click](https://evil.test)","severity":"medium","evidence":["$(reboot)"]}],
             "checks":[],"limitations":[],"notTested":[]}
            """#
            let envelope = String(header(status: "delivered").dropLast()) + #","report":\#(report)}"#
            return json(200, envelope)
        case ("POST", "/peer/v1/link/messages/m1/ack"):
            let state = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["state"] as? String
            return json(200, header(status: state == "opened" ? "opened" : "delivered"))
        case ("POST", "/peer/v1/link/unregister"):
            return json(200, #"{"status":"revoked"}"#)
        default:
            return json(404, #"{"error":"not found","code":"not_found"}"#)
        }
    }

    private func header(status: String) -> String {
        #"""
        {"messageId":"m1","type":"report.share","from":{"installationId":"0b6c2b8e-0000-4000-8000-000000000002","name":"Ana's iPhone","app":"hcg.sentinel"},
         "to":{"installationId":"me","name":"This iPhone","app":"hcg.terminal"},"title":"Exposure Check","createdAt":"\#(Self.time)",
         "queuedAt":"\#(Self.time)","expiresAt":"2026-11-21T10:00:00Z","status":"\#(status)","size":512}
        """#
    }

    private func json(_ status: Int, _ body: String) -> LinkHTTPResponse {
        LinkHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }
}

/// A clock that only moves when the controller sleeps.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
final class DeviceLinkControllerTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-devicelink-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    static let readyConnect = HCGConnectSetup.ready(HCGConnectConfiguration(
        contractVersion: HCGConnectSetup.contract, clientId: "4f1e7c1a-0000-4000-8000-000000000001", redirectUri: "hcgterminal://oauth"))

    /// A store holding unexpired HCG Connect tokens (no network needed to use them).
    static func signedInStore() -> MemorySecretStore {
        let store = MemorySecretStore()
        let tokens = #"{"accessToken":"header.payload.signature","refreshToken":"r","expiresAt":"2099-01-01T00:00:00Z","subject":"6f0a5a52-0000-4000-8000-000000000009","email":"owner@example.test","clientId":"4f1e7c1a-0000-4000-8000-000000000001"}"#
        try! store.write("hcg-connect.tokens", Data(tokens.utf8))
        return store
    }

    private func makeController(connect: HCGConnectSetup = readyConnect, store: MemorySecretStore = signedInStore(), server: FakeLinkServer,
                                variant: TerminalLinkVariant = .vanilla, reports: [ExecutionMode: CapabilityReport] = [:],
                                clock: TestClock = TestClock()) -> DeviceLinkController {
        let environment = DeviceLinkEnvironment(
            variant: variant, appVersion: "1.0", secrets: store,
            pairingFile: PairingRecordFile(url: folder.appendingPathComponent("pairing.json")),
            connect: connect, makeTransport: { _ in server },
            describeDevice: { LinkDeviceDescription(name: "This iPhone", platform: "iOS 18.1", deviceId: nil) },
            now: { clock.now() },
            // Sleeping advances the test clock by the requested time, after a short real pause.
            sleep: { seconds in
                try await Task.sleep(nanoseconds: 2_000_000)
                clock.advance(seconds)
            },
            preferSecureEnclave: false
        )
        let access = AccessPolicy.allEnabled()
        let controller = DeviceLinkController(environment: environment) {
            TerminalLinkCapabilities.advertised(distribution: variant, reports: reports, access: access)
        }
        controller.automaticSync = false
        return controller
    }

    func testNotConfiguredContactsNothing() async {
        let server = FakeLinkServer()
        let controller = makeController(connect: .notConfigured(HCGConnectSetup.noClientMessage), store: MemorySecretStore(), server: server)
        await controller.activate()
        XCTAssertEqual(controller.state, .notConfigured(reason: HCGConnectSetup.noClientMessage))
        XCTAssertFalse(controller.canPair)
        XCTAssertThrowsError(try controller.beginSignIn())
        await controller.pair(code: InvitationFixture.code())
        await controller.syncNow()
        XCTAssertTrue(server.requests.isEmpty)
        // The local identity is still shown.
        XCTAssertNotNil(controller.identity)
        XCTAssertEqual(controller.identity?.keyKind, "software")
    }

    func testSignedOutCannotPair() async {
        let server = FakeLinkServer()
        let controller = makeController(store: MemorySecretStore(), server: server)
        await controller.activate()
        XCTAssertEqual(controller.state, .signedOut)
        await controller.pair(code: InvitationFixture.code())
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testPairApproveSyncOpenAndRemove() async throws {
        let server = FakeLinkServer()
        let controller = makeController(server: server)
        await controller.activate()
        XCTAssertEqual(controller.account?.email, "owner@example.test")
        XCTAssertEqual(controller.state, .notPaired(note: nil))

        // Preview shows what to compare; nothing is sent.
        guard case .success(let preview) = controller.previewInvitation(InvitationFixture.code()) else { return XCTFail() }
        XCTAssertEqual(preview.hostName, "Studio Mac")
        XCTAssertTrue(server.requests.isEmpty)

        await controller.pair(code: InvitationFixture.code())
        let identity = try XCTUnwrap(controller.identity)
        guard case .pairing(let progress) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(progress.pending)
        XCTAssertEqual(progress.serverFingerprint, InvitationFixture.serverFingerprint)
        XCTAssertEqual(progress.deviceFingerprint, identity.fingerprint)
        XCTAssertEqual(server.installationFingerprint, identity.fingerprint)
        let pairBody = try JSONSerialization.jsonObject(with: server.requests("/pair")[0].body) as! [String: Any]
        let installation = pairBody["installation"] as! [String: Any]
        XCTAssertEqual(installation["app"] as? String, "hcg.terminal")
        XCTAssertEqual(installation["variant"] as? String, "vanilla")

        await controller.syncNow()
        guard case .pairing = controller.state else { return XCTFail("still pending: \(controller.state)") }
        server.pairStatus = "approved"
        await controller.syncNow()
        XCTAssertEqual(controller.state, .connected(lastSync: nil))
        XCTAssertEqual(controller.pairing?.status, .approved)

        await controller.syncNow()
        guard case .connected(let last?) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(controller.lastSync, last)
        XCTAssertEqual(controller.remoteDevices.map(\.name), ["Ana's iPhone"])
        XCTAssertEqual(controller.inbox.map(\.messageId), ["m1"])
        XCTAssertEqual(controller.approvals?.approvals.count, 0)
        // A queued message is acknowledged as received (never opened automatically).
        let acks = server.requests("/messages/m1/ack").compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: String] }
        XCTAssertEqual(acks, [["state": "received"]])

        // The heartbeat carried this app's own advertisement, not what the server listed.
        let heartbeat = try JSONSerialization.jsonObject(with: try XCTUnwrap(server.requests("/heartbeat").last).body) as! [String: Any]
        let sent = try LinkJSON.decoder().decode([LinkCapability].self, from: JSONSerialization.data(withJSONObject: heartbeat["capabilities"]!))
        XCTAssertEqual(sent, controller.advertisedCapabilities)
        XCTAssertEqual(sent.first { $0.id == LinkCapabilityID.terminalPrivileged }?.state, .unavailable)

        // A report is data: rendered as plain lines, nothing interpreted.
        let opened = try await controller.openReport(controller.inbox[0])
        let lines = opened.sections.flatMap { [$0.title] + $0.lines }
        XCTAssertTrue(lines.contains("Finding 1: Run this: `rm -rf ~` [click](https://evil.test)"))
        XCTAssertTrue(lines.contains("Evidence: $(reboot)"))
        await controller.markOpened("m1")
        XCTAssertEqual(controller.inbox.first?.status, "opened")

        await controller.unregister()
        XCTAssertEqual(server.requests("/unregister").count, 1)
        XCTAssertNil(server.requests("/unregister")[0].headers["Authorization"], "unregister needs only the installation key")
        XCTAssertNil(controller.pairing)
        XCTAssertNil(PairingRecordFile(url: folder.appendingPathComponent("pairing.json")).load())
        XCTAssertNotEqual(controller.identity?.fingerprint, identity.fingerprint, "a new key is used after removal")
        XCTAssertEqual(controller.state, .notPaired(note: nil))
    }

    func testServerDataCannotChangeAdvertisedCapabilities() async throws {
        let server = FakeLinkServer()
        let reports: [ExecutionMode: CapabilityReport] = [.unleashed: ReportFixtures.unleashed(.availableUntested("found"))]
        let controller = makeController(server: server, variant: .unleashed, reports: reports)
        await controller.activate()
        await controller.pair(code: InvitationFixture.code())
        server.pairStatus = "approved"
        await controller.syncNow()
        let before = controller.advertisedCapabilities
        // The server lists this installation with "verified" privileged access and says
        // execution is enabled; neither changes anything here.
        await controller.syncNow()
        await controller.syncNow()
        XCTAssertEqual(controller.advertisedCapabilities, before)
        XCTAssertFalse(controller.advertisedCapabilities.contains { $0.id == LinkCapabilityID.terminalPrivileged && $0.state.isUsable })
        for request in server.requests("/heartbeat") {
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let sent = try LinkJSON.decoder().decode([LinkCapability].self, from: JSONSerialization.data(withJSONObject: body["capabilities"]!))
            XCTAssertEqual(sent, before)
        }
    }

    func testRevokedInstallationStopsSyncing() async {
        let server = FakeLinkServer()
        let controller = makeController(server: server)
        await controller.activate()
        await controller.pair(code: InvitationFixture.code())
        server.pairStatus = "approved"
        await controller.syncNow()
        server.failure = (403, "device_revoked", false)
        await controller.syncNow()
        guard case .removed(let reason) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(reason.contains("Pair again"))
        let count = server.requests.count
        await controller.syncNow()
        XCTAssertEqual(server.requests.count, count, "nothing is sent after the link ended")
        // Returning to the screen does not retry: the removal is remembered.
        XCTAssertEqual(controller.pairing?.status, .removed)
        await controller.activate()
        guard case .removed = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(server.requests.count, count)
        XCTAssertTrue(controller.canPair, "pairing again with a new invitation is allowed")
    }

    func testEndedHCGSessionSignsOutLocally() async {
        let server = FakeLinkServer()
        let controller = makeController(server: server)
        await controller.activate()
        await controller.pair(code: InvitationFixture.code())
        server.pairStatus = "approved"
        await controller.syncNow()
        server.failure = (401, "hcg_session_ended", false)
        await controller.syncNow()
        guard case .signInEnded = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertNil(controller.account)
        await controller.activate()
        XCTAssertEqual(controller.state, .signedOut)
    }

    func testSyncLoopBacksOffAndStopsWhenTheLinkEnds() async throws {
        let server = FakeLinkServer()
        let controller = makeController(server: server)
        controller.automaticSync = true
        await controller.activate()
        await controller.pair(code: InvitationFixture.code())
        server.pairStatus = "approved"
        try await waitUntil { controller.lastSync != nil }
        XCTAssertTrue(controller.isSyncing)

        server.failure = (503, "hcg_unavailable", true)
        try await waitUntil { if case .offline = controller.state { true } else { false } }
        server.failure = (403, "device_revoked", false)
        try await waitUntil { !controller.isSyncing }
        guard case .removed = controller.state else { return XCTFail("\(controller.state)") }
    }

    func testPermissionProblemForOneSectionDoesNotEndTheConnection() async {
        final class Partial: LinkTransport, @unchecked Sendable {
            let inner = FakeLinkServer()
            func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse {
                if request.url.path.hasSuffix("/approvals") {
                    return LinkHTTPResponse(status: 403, headers: [:], body: Data(#"{"error":"Actions are not configured.","code":"permission_not_configured","retryable":false}"#.utf8))
                }
                return try await inner.send(request)
            }
        }
        let partial = Partial()
        let environment = DeviceLinkEnvironment(
            variant: .vanilla, appVersion: "1.0", secrets: Self.signedInStore(),
            pairingFile: PairingRecordFile(url: folder.appendingPathComponent("pairing.json")),
            connect: Self.readyConnect, makeTransport: { _ in partial },
            describeDevice: { LinkDeviceDescription(name: "This iPhone", platform: "iOS 18.1", deviceId: nil) }, preferSecureEnclave: false
        )
        let controller = DeviceLinkController(environment: environment)
        controller.automaticSync = false
        await controller.activate()
        await controller.pair(code: InvitationFixture.code())
        partial.inner.pairStatus = "approved"
        await controller.syncNow()
        await controller.syncNow()
        guard case .connected = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(controller.sectionProblems[.approvals], "Actions are not configured.")
        XCTAssertNil(controller.sectionProblems[.inbox])
    }

    func testForgetLocallyKeepsNothing() async {
        let server = FakeLinkServer()
        let controller = makeController(server: server)
        await controller.activate()
        await controller.pair(code: InvitationFixture.code())
        let old = controller.identity?.installationId
        controller.forgetLocally()
        XCTAssertNil(controller.pairing)
        XCTAssertNotEqual(controller.identity?.installationId, old)
        XCTAssertEqual(controller.state, .notPaired(note: nil))
        XCTAssertTrue(server.requests("/unregister").isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not reached in \(timeout) s")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
