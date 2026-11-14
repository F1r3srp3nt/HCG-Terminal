#if canImport(Darwin)
import Foundation
import XCTest
@testable import HCGDeviceLink

/// END-TO-END against a REAL HCG Server agent over real TLS with key pinning.
/// Identities come from hcgmock (a STAND-IN for HCG Connect / ERP), started by
/// `go run ./cmd/hcg-devicelink-fixture -out <file>`; set HCG_DEVICELINK_FIXTURE
/// to that file. Skipped otherwise. Runs on macOS (the pinned transport uses
/// Security.framework).
final class EndToEndTests: XCTestCase {
    struct Fixture: Decodable {
        let peerAddress, fingerprint, adminUrl, adminToken, otherAccountToken: String
        let invitations: [String]
        let tokens: [String: String]
    }

    struct StaticToken: AccessTokenProvider {
        let token: String
        func accessToken(forceRefresh: Bool) async throws -> String { token }
    }

    func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["HCG_DEVICELINK_FIXTURE"] else {
            throw XCTSkip("HCG_DEVICELINK_FIXTURE not set (run cmd/hcg-devicelink-fixture)")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func admin(_ f: Fixture, _ method: String, _ path: String) async throws -> Data {
        var r = URLRequest(url: URL(string: f.adminUrl + "/api/v1/link" + path)!)
        r.httpMethod = method
        r.setValue("Bearer " + f.adminToken, forHTTPHeaderField: "Authorization")
        let (data, status): (Data, Int) = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: r) { d, resp, err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0)) }
            }.resume()
        }
        XCTAssertEqual(status, 200, String(decoding: data, as: UTF8.self))
        return data
    }

    func makeClient(_ f: Fixture, app: String, token: String, pin: String? = nil) -> (DeviceLinkClient, InstallationIdentity) {
        let id = try! InstallationIdentity.loadOrCreate(store: MemorySecretStore(), preferSecureEnclave: false)
        let cfg = DeviceLinkConfiguration(baseURL: URL(string: "https://" + f.peerAddress)!, serverFingerprint: pin ?? f.fingerprint, installationId: id.installationId)
        return (DeviceLinkClient(configuration: cfg, signer: id.signer, transport: PinnedSessionTransport(fingerprint: pin ?? f.fingerprint),
                                 tokens: StaticToken(token: token)), id)
    }

    func info(_ id: InstallationIdentity, name: String, app: String, variant: String?, caps: [LinkCapability]) -> LinkInstallationInfo {
        LinkInstallationInfo(installationId: id.installationId, deviceId: nil, name: name, platform: "macOS test", app: app, appVersion: "e2e",
                             variant: variant, publicKey: id.signer.publicKeyBase64, capabilities: caps)
    }

    func approve(_ f: Fixture, _ requestId: String) async throws {
        _ = try await admin(f, "POST", "/pairings/\(requestId)/approve")
    }

    func testMilestoneWorkflowAgainstRealServer() async throws {
        let f = try fixture()
        // Pinning: a wrong pin never reaches the server.
        let (wrong, wrongId) = makeClient(f, app: "hcg.sentinel", token: f.tokens["hcg.sentinel"]!, pin: String(repeating: "0", count: 64))
        do {
            _ = try await wrong.devices()
            XCTFail("wrong pin must fail")
        } catch let e as DeviceLinkError { XCTAssertEqual(e.code, "pin_mismatch") }
        _ = wrongId

        // 1–2. Two signed-in apps pair explicitly; the owner approves both.
        let (sentinel, sid) = makeClient(f, app: "hcg.sentinel", token: f.tokens["hcg.sentinel"]!)
        let (terminal, tid) = makeClient(f, app: "hcg.terminal", token: f.tokens["hcg.terminal"]!)
        let inv1 = try Invitation.parse(f.invitations[0])
        let inv2 = try Invitation.parse(f.invitations[1])
        let p1 = try await sentinel.pair(invitation: inv1, info: info(sid, name: "E2E Sentinel", app: "hcg.sentinel", variant: nil,
                                                                       caps: [LinkCapability(id: LinkCapabilityID.reportSend, state: .available)]))
        XCTAssertEqual(p1.keyFingerprint, sid.fingerprint)
        try await approve(f, p1.requestId)
        let p2 = try await terminal.pair(invitation: inv2, info: info(tid, name: "E2E Terminal", app: "hcg.terminal", variant: "vanilla",
                                                                       caps: [LinkCapability(id: LinkCapabilityID.reportReceive, state: .available),
                                                                              LinkCapability(id: LinkCapabilityID.terminalPrivileged, state: .unavailable, reason: "Vanilla build")]))
        try await approve(f, p2.requestId)
        let polled = try await terminal.pairingStatus(requestId: p2.requestId)
        XCTAssertEqual(polled.status, "approved")

        // 3. Identities, state, capabilities.
        _ = try await terminal.heartbeat(capabilities: nil)
        let devices = try await sentinel.devices()
        XCTAssertEqual(devices.selfInstallationId, sid.installationId)
        let t = try XCTUnwrap(devices.installations.first { $0.installationId == tid.installationId })
        XCTAssertEqual(t.state, .online)
        XCTAssertTrue(t.supports(LinkCapabilityID.reportReceive))
        XCTAssertEqual(t.capability(LinkCapabilityID.terminalPrivileged)?.state, .unavailable)

        // 4. Share a redacted report with the selected device.
        let report = DiagnosticReport.make(reportId: LinkCrypto.uuid(), kind: "network-check", title: "Check My Network — E2E",
                                           origin: .init(app: "hcg.sentinel", appVersion: "e2e", installationId: sid.installationId, deviceName: "E2E Sentinel"),
                                           createdAt: Date(), completedAt: Date(), summary: .init(status: "completed", highestSeverity: nil, findingCount: 0),
                                           scope: ["password=hunter2"], findings: [], checks: [.init(title: "DNS", outcome: "passed", detail: nil)],
                                           limitations: ["E2E"], notTested: [])
        let receipt = try await sentinel.share(report, to: tid.installationId)
        XCTAssertEqual(receipt.status, "queued")
        XCTAssertEqual(receipt.recipientState, "online")

        // 5. Open it in Terminal.
        let inbox = try await terminal.inbox()
        XCTAssertEqual(inbox.map(\.messageId), [receipt.messageId])
        let opened = try await terminal.open(messageId: receipt.messageId)
        XCTAssertEqual(opened.report.title, "Check My Network — E2E")
        XCTAssertEqual(opened.report.scope, ["password=[REDACTED]"])
        try await terminal.acknowledge(messageId: receipt.messageId, opened: true)
        let outbox = try await sentinel.outbox()
        XCTAssertEqual(outbox.first?.status, "opened")

        // Wrong account on an existing installation.
        let impostor = DeviceLinkClient(configuration: terminal.configuration, signer: tid.signer,
                                        transport: PinnedSessionTransport(fingerprint: f.fingerprint), tokens: StaticToken(token: f.otherAccountToken))
        do {
            _ = try await impostor.inbox()
            XCTFail("wrong account")
        } catch let e as DeviceLinkError { XCTAssertEqual(e.code, "wrong_account") }

        // 6. Revoke Terminal; further access is rejected.
        _ = try await admin(f, "POST", "/installations/\(tid.installationId)/revoke")
        do {
            _ = try await terminal.inbox()
            XCTFail("revoked")
        } catch let e as DeviceLinkError {
            XCTAssertEqual(e.code, "device_revoked")
            XCTAssertTrue(e.endsLink)
        }
        do {
            _ = try await sentinel.share(report, to: tid.installationId)
            XCTFail("revoked recipient")
        } catch let e as DeviceLinkError { XCTAssertEqual(e.code, "unknown_recipient") }
    }
}
#endif
