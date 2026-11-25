import Foundation
import XCTest
@testable import HCGDeviceLink

/// The hosting additions of Device Link 1.1: JSON produced by the Go server
/// (contracts/v1, generated with encoding/json) must decode unchanged.
final class HostingModelTests: XCTestCase {
    let servicesJSON = #"{"host":{"deviceId":"d1","name":"Dev Mac","platform":"darwin","osVersion":"27.1","architecture":"arm64","cpuModel":"Apple M4 Max","logicalCpus":16,"memoryTotalBytes":137438953472,"memoryAvailableBytes":68719476736,"loadAverage":[1.5,1.2,1],"agentVersion":"0.9.0","agentStartedAt":"2026-11-25T10:00:00.123Z","gatewayExposure":"lan","sampledAt":"2026-11-25T10:00:00.123Z"},"services":[{"id":"system-tester","productId":"hcg.system-tester","name":"HCG System Tester","version":"0.1.0","runtime":"native-process","status":"running","health":"ok","uptimeSeconds":42,"restarts":0,"lastHealthAt":"2026-11-25T10:00:00.123Z","capabilities":["dashboard","health"],"gatewayPublished":true,"openable":true}]}"#
    let diagnosticsJSON = #"{"generatedAt":"2026-11-25T10:00:00.123Z","server":{"available":true,"agentVersion":"0.9.0","startedAt":"2026-11-25T10:00:00.123Z","uptimeSeconds":42,"authority":"local-development"},"tls":{"deviceApi":"TLS 1.3","serverKeySha256":"ab","gatewayRunning":true,"gatewayExposure":"lan","gatewayCaSha256":"cd","gatewayLeafExpires":"2026-11-25T10:00:00.123Z"},"services":[{"id":"system-tester","productId":"hcg.system-tester","name":"HCG System Tester","version":"0.1.0","runtime":"native-process","status":"running","health":"ok","uptimeSeconds":42,"restarts":0,"lastHealthAt":"2026-11-25T10:00:00.123Z","capabilities":["dashboard","health"],"gatewayPublished":true,"openable":true}],"securityEvents":[{"time":"2026-11-25T10:00:00.123Z","severity":"warning","message":"Rejected"}],"failedAuthentications24h":1,"summary":["x"]}"#
    let ticketJSON = #"{"url":"https://dev-mac.local:7620/access/ticket?t=abc","expiresAt":"2026-11-25T10:00:00.123Z","caFingerprint":"cd","note":"n"}"#
    let devInvitation = "hcg1-eyJ2IjoxLCJpZCI6ImludjEiLCJzIjoic2VjIiwiaGQiOiJkMSIsImhuIjoiRGV2IE1hYyIsImhhIjoiZGV2LW1hYy5sb2NhbDo3NjEwIiwiZnAiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIiwiZXhwIjoiMjA5OS0wMS0wMVQwMDowMDowMFoiLCJhbSI6ImxvY2FsLWRldmVsb3BtZW50In0"

    func testServicesDecode() throws {
        let s = try LinkJSON.decoder().decode(LinkServices.self, from: Data(servicesJSON.utf8))
        XCTAssertEqual(s.host.cpuModel, "Apple M4 Max")
        XCTAssertEqual(s.host.memoryTotalBytes, 137_438_953_472)
        XCTAssertEqual(s.host.gatewayExposure, "lan")
        XCTAssertEqual(s.services.count, 1)
        XCTAssertEqual(s.services[0].id, "system-tester")
        XCTAssertTrue(s.services[0].isHealthy)
        XCTAssertTrue(s.services[0].openable)
        XCTAssertNotNil(s.services[0].lastHealthAt)
    }

    func testDiagnosticsAndTicketDecode() throws {
        let d = try LinkJSON.decoder().decode(LinkDiagnostics.self, from: Data(diagnosticsJSON.utf8))
        XCTAssertEqual(d.server.authority, DeviceLinkProtocol.Authority.localDevelopment)
        XCTAssertEqual(d.failedAuthentications24h, 1)
        XCTAssertEqual(d.securityEvents.first?.severity, "warning")
        XCTAssertNotNil(d.tls.gatewayLeafExpires)
        let t = try LinkJSON.decoder().decode(LinkOpenTicket.self, from: Data(ticketJSON.utf8))
        XCTAssertTrue(t.url.hasPrefix("https://"))
    }

    func testLocalDevelopmentInvitation() async throws {
        let inv = try Invitation.parse(devInvitation)
        XCTAssertTrue(inv.isLocalDevelopment)
        XCTAssertEqual(inv.hostAddress, "dev-mac.local:7610")
        let rec = PairingRecord(invitation: inv, requestId: "r1", status: .pending)
        XCTAssertTrue(rec.isLocalDevelopment)
        let back = try LinkJSON.decoder().decode(PairingRecord.self, from: LinkJSON.encoder().encode(rec))
        XCTAssertEqual(back.authMode, rec.authMode)
        XCTAssertEqual(back.serverAddress, rec.serverAddress)
        let token = try await LocalDevelopmentTokens().accessToken(forceRefresh: true)
        XCTAssertEqual(token, "")
        XCTAssertTrue(DeviceLinkError.server(status: 403, body: LinkErrorBody(error: "x", code: "authority_changed", retryable: nil, retryAfterSeconds: nil, protocol: nil, supportedVersions: nil, blockingLayer: nil)).endsLink)
    }

    func testOlderPairingRecordStillDecodes() throws {
        let old = #"{"serverAddress":"a:1","serverFingerprint":"f","serverName":"n","serverDeviceId":"d","requestId":"r","status":"approved","updatedAt":"2026-11-25T10:00:00Z"}"#
        let r = try LinkJSON.decoder().decode(PairingRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.authMode)
        XCTAssertFalse(r.isLocalDevelopment)
    }
}
