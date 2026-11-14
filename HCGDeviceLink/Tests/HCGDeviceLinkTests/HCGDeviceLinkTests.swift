import Foundation
import XCTest
@testable import HCGDeviceLink
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Unit and cross-language tests (no network). These are MOCK tests: the
// transport below is a scripted stand-in for HCG Server. Real-server tests
// live in HCG-Server's Go suite and the macOS end-to-end job.

struct Vectors: Decodable {
    struct Canonical: Decodable {
        let method, escapedPath, rawQuery, installationId, timestamp, nonce, organisation, accessToken, bodyBase64, expected: String
    }
    let privateKeyRawHex, publicKeySPKIBase64, keyFingerprint, goSignature, certificateDERBase64, certificateFingerprint: String
    let invitationCode, invitationId, invitationHostAddress: String
    let canonical: Canonical

    static func load() throws -> Vectors {
        let url = Bundle.module.url(forResource: "devicelink-v1", withExtension: "json", subdirectory: "Vectors")!
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
}

func hexData(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

final class CrossLanguageTests: XCTestCase {
    func testCanonicalSignatureAndFingerprintsMatchGo() throws {
        let v = try Vectors.load()
        let c = v.canonical
        let canon = CanonicalRequest(method: c.method, escapedPath: c.escapedPath, rawQuery: c.rawQuery, installationId: c.installationId,
                                     timestamp: c.timestamp, nonce: c.nonce, organisation: c.organisation, accessToken: c.accessToken,
                                     body: Data(base64Encoded: c.bodyBase64)!)
        XCTAssertEqual(canon.string, c.expected)
        let signer = try SoftwareSigner(rawRepresentation: hexData(v.privateKeyRawHex))
        XCTAssertEqual(signer.publicKeyBase64, v.publicKeySPKIBase64)
        XCTAssertEqual(signer.fingerprint, v.keyFingerprint)
        // Go's signature verifies in Swift.
        XCTAssertTrue(LinkCrypto.verify(spki: signer.publicKeySPKI, signatureDER: LinkCrypto.base64URLDecode(v.goSignature)!,
                                        message: Data(c.expected.utf8)))
        // Swift's signature (verified by Go in internal/devicelink/vectors_test.go).
        let sig = try signer.sign(Data(c.expected.utf8))
        XCTAssertTrue(LinkCrypto.verify(spki: signer.publicKeySPKI, signatureDER: sig, message: Data(c.expected.utf8)))

        // The pin the transport computes from a certificate equals Go's fingerprint.
        let spki = CertificateSPKI.extract(fromCertificateDER: Data(base64Encoded: v.certificateDERBase64)!)
        XCTAssertNotNil(spki)
        XCTAssertEqual(spki.map { LinkCrypto.fingerprint(spki: $0) }, v.certificateFingerprint)
        XCTAssertNil(CertificateSPKI.extract(fromCertificateDER: Data([0x30, 0x03, 0x02, 0x01, 0x01])))

        // A report produced by this client must pass the server's validation (checked by Go).
        let report = DiagnosticReport.make(
            reportId: "6b0c3a1e-2f4d-4c6b-9a8e-1d2c3b4a5f60", kind: "security-lab.exposure-check", title: "Exposure Check — 1 finding",
            origin: .init(app: "hcg.sentinel", appVersion: "1.0", installationId: c.installationId, deviceName: "Vector iPhone", module: "exposureCheck", moduleVersion: "1.0.0"),
            createdAt: Date(timeIntervalSince1970: 1_794_650_000), completedAt: Date(timeIntervalSince1970: 1_794_650_060),
            summary: .init(status: "completed", highestSeverity: "medium", findingCount: 1), scope: ["https://admin:hunter2@example.test/"],
            findings: [.init(title: "Version banner exposed", severity: "medium", confidence: "high", basis: "verified", location: "https://example.test/",
                             evidence: ["Server: nginx/1.18.0", "Authorization: Bearer abcdefghijklmnop123"], explanation: "Banner reveals version.",
                             remediation: "Hide the version.")],
            checks: [.init(title: "TLS", outcome: "passed", detail: nil)], limitations: ["Checked from one network."], notTested: [],
            sharedAt: Date(timeIntervalSince1970: 1_794_650_100))
        let encoded = try report.encoded()
        XCTAssertEqual(ReportValidator.problems(report, encoded: encoded), [])
        if let out = ProcessInfo.processInfo.environment["HCG_WRITE_SWIFT_VECTORS"] {
            var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out))) as! [String: Any]
            obj["swiftSignature"] = LinkCrypto.base64URL(sig)
            obj["swiftReport"] = try JSONSerialization.jsonObject(with: encoded)
            obj["swiftReportSender"] = c.installationId
            try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }

    func testInvitationParsing() throws {
        let v = try Vectors.load()
        let inv = try Invitation.parse("  " + v.invitationCode.prefix(20) + "\n" + v.invitationCode.dropFirst(20) + " ")
        XCTAssertEqual(inv.invitationId, v.invitationId)
        XCTAssertEqual(inv.hostAddress, v.invitationHostAddress)
        XCTAssertEqual(inv.fingerprint, v.certificateFingerprint)
        XCTAssertEqual(inv.baseURL?.absoluteString, "https://" + v.invitationHostAddress)
        XCTAssertThrowsError(try Invitation.parse("hello")) { XCTAssertEqual($0 as? Invitation.Problem, .notAnInvitation) }
        XCTAssertThrowsError(try Invitation.parse("hcg1-!!!")) { XCTAssertEqual($0 as? Invitation.Problem, .corrupted) }
        XCTAssertThrowsError(try Invitation.parse(v.invitationCode, now: Date(timeIntervalSince1970: 2_500_000_000))) {
            XCTAssertEqual($0 as? Invitation.Problem, .expired)
        }
    }
}

final class ReportTests: XCTestCase {
    func testRedaction() {
        let r = ReportRedactor.standard
        XCTAssertEqual(r.redact("Authorization: Bearer abc.def-123456"), "Authorization: Bearer [REDACTED]")
        XCTAssertEqual(r.redact("https://user:pw@host.test/x"), "https://[REDACTED]@host.test/x")
        XCTAssertEqual(r.redact("password=hunter2&x=1"), "password=[REDACTED]&x=1")
        XCTAssertEqual(r.redact("\"api_key\": \"sk-123\""), "\"api_key\": \"[REDACTED]\"")
        XCTAssertTrue(r.redact("-----BEGIN EC PRIVATE KEY-----\nMHcCAQ\n-----END EC PRIVATE KEY-----").contains("[REDACTED PRIVATE KEY]"))
        XCTAssertEqual(r.redact("Basic connectivity is fine"), "Basic connectivity is fine")
        let strict = ReportRedactor.strict
        XCTAssertEqual(strict.redact("Gateway 192.168.1.1, BSSID aa:bb:cc:dd:ee:ff, ana@example.test"),
                       "Gateway [REDACTED IP], BSSID [REDACTED MAC], [REDACTED EMAIL]")
        XCTAssertEqual(ReportRedactor.standard.redact("Gateway 192.168.1.1"), "Gateway 192.168.1.1")
    }

    func testValidatorCatchesWhatTheServerRefuses() throws {
        var report = DiagnosticReport.make(reportId: LinkCrypto.uuid(), kind: "network-check", title: "Check", origin: .init(app: "hcg.sentinel", appVersion: "1", installationId: LinkCrypto.uuid(), deviceName: "x"),
                                           createdAt: Date(), completedAt: nil, summary: .init(status: "completed", highestSeverity: nil, findingCount: 0),
                                           scope: [], findings: [], checks: [], limitations: [], notTested: [])
        XCTAssertEqual(ReportValidator.problems(report, encoded: try report.encoded()), [])
        report.limitations = ["eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl"] // bypassing make() on purpose
        XCTAssertEqual(ReportValidator.problems(report, encoded: try report.encoded()), ["the report still contains a JWT-shaped token"])
        report.limitations = []
        report.redaction.applied = false
        XCTAssertEqual(ReportValidator.problems(report, encoded: try report.encoded()), ["report is not marked redacted"])
    }

    func testRendererIsPlainText() throws {
        let hostile = "[click](javascript:alert(1)) <script>x</script> $(rm -rf ~) `id`"
        let second = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) // the wire format carries whole seconds
        let report = DiagnosticReport.make(reportId: LinkCrypto.uuid(), kind: "network-check", title: hostile,
                                           origin: .init(app: "hcg.sentinel", appVersion: "1", installationId: LinkCrypto.uuid(), deviceName: "x"),
                                           createdAt: second, completedAt: nil, summary: .init(status: "completed", highestSeverity: nil, findingCount: 1),
                                           scope: [hostile], findings: [.init(title: hostile, severity: "low", confidence: nil, basis: nil, location: nil, evidence: [hostile], explanation: nil, remediation: hostile)],
                                           checks: [], limitations: [], notTested: [], sharedAt: second)
        let text = ReportTextRenderer.text(report)
        // The hostile strings come through verbatim as text: not interpreted, not dropped.
        XCTAssertTrue(text.contains(hostile))
        let decoded = try DiagnosticReport.decode(try report.encoded())
        XCTAssertEqual(decoded, report)
    }

    func testGoTimestampsDecode() {
        XCTAssertNotNil(LinkJSON.parseDate("2026-11-14T10:00:00.123456789Z"))
        XCTAssertNotNil(LinkJSON.parseDate("2026-11-14T10:00:00Z"))
        XCTAssertNotNil(LinkJSON.parseDate("2026-11-14T11:00:00.5+01:00"))
        XCTAssertNil(LinkJSON.parseDate("yesterday"))
    }
}

// MARK: - Client behaviour against a scripted transport (MOCK)

final class ScriptedTransport: LinkTransport, @unchecked Sendable {
    var replies: [(LinkHTTPRequest) throws -> LinkHTTPResponse] = []
    var seen: [LinkHTTPRequest] = []
    let spki: Data
    let lock = NSLock()

    init(spki: Data) { self.spki = spki }

    private func take(_ request: LinkHTTPRequest) -> ((LinkHTTPRequest) throws -> LinkHTTPResponse)? {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        return replies.isEmpty ? nil : replies.removeFirst()
    }

    func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse {
        let reply = take(request)
        // Every request must carry a valid signature over the canonical string.
        let h = request.headers
        let canon = CanonicalRequest(method: request.method, escapedPath: request.url.path, rawQuery: request.url.query ?? "",
                                     installationId: h["HCG-Link-Installation"]!, timestamp: h["HCG-Link-Timestamp"]!, nonce: h["HCG-Link-Nonce"]!,
                                     organisation: h["HCG-Link-Organisation"] ?? "", accessToken: String((h["Authorization"] ?? "").dropFirst(7)), body: request.body)
        guard LinkCrypto.verify(spki: spki, signatureDER: LinkCrypto.base64URLDecode(h["HCG-Link-Signature"]!)!, message: Data(canon.string.utf8)) else {
            return LinkHTTPResponse(status: 401, headers: [:], body: Data(#"{"error":"bad","code":"bad_signature"}"#.utf8))
        }
        guard let r = reply else { throw TransportFailure.unreachable("no scripted reply") }
        return try r(request)
    }
}

actor CountingTokens: AccessTokenProvider {
    var refreshes = 0
    var token = "tok-1"
    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes += 1; token = "tok-\(refreshes + 1)" }
        return token
    }
}

func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> LinkHTTPResponse {
    LinkHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

final class ClientTests: XCTestCase {
    func makeClient() -> (DeviceLinkClient, ScriptedTransport, CountingTokens) {
        let signer = SoftwareSigner()
        let t = ScriptedTransport(spki: signer.publicKeySPKI)
        let tokens = CountingTokens()
        let c = DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: URL(string: "https://127.0.0.1:7610")!,
                                                                        serverFingerprint: String(repeating: "a", count: 64),
                                                                        installationId: LinkCrypto.uuid()),
                                 signer: signer, transport: t, tokens: tokens)
        return (c, t, tokens)
    }

    let devicesJSON = #"{"protocol":"hcg.devicelink/1","host":{"deviceId":"d","name":"Mac","fingerprint":"f"},"self":"s","installations":[],"onlineWindowSeconds":45}"#

    func testTokenExpiredRefreshesOnceAndRetries() async throws {
        let (c, t, tokens) = makeClient()
        t.replies = [{ _ in json(401, #"{"error":"expired","code":"token_expired"}"#) }, { _ in json(200, self.devicesJSON) }]
        _ = try await c.devices()
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(t.seen.map { $0.headers["Authorization"] }, ["Bearer tok-1", "Bearer tok-2"])
        XCTAssertNotEqual(t.seen[0].headers["HCG-Link-Nonce"], t.seen[1].headers["HCG-Link-Nonce"], "a retry is a new request with a new nonce")
    }

    func testStaleClockIsCorrectedFromServerDate() async throws {
        let (c, t, _) = makeClient()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let server = Date().addingTimeInterval(600)
        t.replies = [{ _ in json(401, #"{"error":"stale","code":"stale_request"}"#, headers: ["Date": f.string(from: server)]) },
                     { _ in json(200, self.devicesJSON) }]
        _ = try await c.devices()
        let ts = Double(t.seen[1].headers["HCG-Link-Timestamp"]!)!
        XCTAssertEqual(ts, server.timeIntervalSince1970, accuracy: 5)
    }

    func testRevocationEndsTheLinkAndIsNotRetryable() async {
        let (c, t, _) = makeClient()
        t.replies = [{ _ in json(403, #"{"error":"removed","code":"device_revoked","retryable":false,"protocol":"hcg.devicelink/1"}"#) }]
        do {
            _ = try await c.inbox()
            XCTFail("expected an error")
        } catch let e as DeviceLinkError {
            XCTAssertEqual(e.code, "device_revoked")
            XCTAssertTrue(e.endsLink)
            XCTAssertFalse(e.isRetryable)
        } catch { XCTFail("\(error)") }
    }

    func testOfflineShareIsResentWithTheSameMessageIdAndBytes() async throws {
        let (c, t, _) = makeClient()
        let report = DiagnosticReport.make(reportId: LinkCrypto.uuid(), kind: "network-check", title: "Check", origin: .init(app: "hcg.sentinel", appVersion: "1", installationId: LinkCrypto.uuid(), deviceName: "x"),
                                           createdAt: Date(), completedAt: nil, summary: .init(status: "completed", highestSeverity: nil, findingCount: 0),
                                           scope: [], findings: [], checks: [], limitations: [], notTested: [])
        t.replies = [{ _ in throw TransportFailure.unreachable("offline") }]
        do {
            _ = try await c.share(report, to: LinkCrypto.uuid())
            XCTFail("expected offline")
        } catch let e as DeviceLinkError { XCTAssertTrue(e.isRetryable) }
        let pending = await c.pendingMessageIds
        XCTAssertEqual(pending.count, 1)
        t.replies = [{ r in
            json(200, #"{"messageId":"\#(pending[0])","status":"queued","duplicate":true,"recipientState":"offline","queuedAt":"2026-11-14T10:00:00Z","expiresAt":"2026-11-21T10:00:00Z"}"#)
        }]
        let results = await c.resendPending()
        XCTAssertNotNil(try? results[pending[0]]?.get())
        XCTAssertEqual(t.seen.count, 2)
        XCTAssertEqual(t.seen[0].body, t.seen[1].body, "a resend must be byte-identical so the server de-duplicates it")
        let left = await c.pendingMessageIds
        XCTAssertEqual(left, [])
    }

    func testUnredactedReportNeverLeavesTheDevice() async {
        let (c, t, _) = makeClient()
        var report = DiagnosticReport.make(reportId: LinkCrypto.uuid(), kind: "network-check", title: "Check", origin: .init(app: "hcg.sentinel", appVersion: "1", installationId: LinkCrypto.uuid(), deviceName: "x"),
                                           createdAt: Date(), completedAt: nil, summary: .init(status: "completed", highestSeverity: nil, findingCount: 0),
                                           scope: [], findings: [], checks: [], limitations: [], notTested: [])
        report.scope = ["Bearer abcdefghijkl123456"]
        do {
            _ = try await c.share(report, to: LinkCrypto.uuid())
            XCTFail("expected refusal")
        } catch let e as DeviceLinkError { XCTAssertEqual(e.code, "invalid_request") } catch { XCTFail("\(error)") }
        XCTAssertTrue(t.seen.isEmpty)
    }

    func testReconnectPolicy() {
        let p = ReconnectPolicy()
        XCTAssertEqual(p.delay(afterFailures: 1, random: 0), 1)
        XCTAssertEqual(p.delay(afterFailures: 4, random: 0), 8)
        XCTAssertEqual(p.delay(afterFailures: 20, random: 0), 60)
        XCTAssertEqual(p.delay(afterFailures: 20, random: 1), 72, accuracy: 0.001)
        XCTAssertEqual(p.delay(afterFailures: 1, retryAfter: 30, random: 0), 30)
    }
}

// MARK: - HCG Connect (MOCK token endpoint)

final class HCGConnectTests: XCTestCase {
    func testPKCEMatchesRFC7636() {
        XCTAssertEqual(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testNotConfiguredUntilHCGIssuesAClient() throws {
        let none = HCGConnectConfiguration(contractVersion: "hcg.sentinel.connect/1", clientId: nil, redirectUri: nil)
        XCTAssertNotNil(none.problem(expectedContract: "hcg.sentinel.connect/1"))
        XCTAssertThrowsError(try HCGConnectAuth(configuration: none, expectedContract: "hcg.sentinel.connect/1").begin())
        let placeholder = HCGConnectConfiguration(contractVersion: "hcg.sentinel.connect/1", clientId: "<issued by HCG>", redirectUri: "x:/cb")
        XCTAssertNotNil(placeholder.problem(expectedContract: "hcg.sentinel.connect/1"))
        let other = HCGConnectConfiguration(contractVersion: "hcg.terminal.connect/1", clientId: UUID().uuidString, redirectUri: "x:/cb")
        XCTAssertNotNil(other.problem(expectedContract: "hcg.sentinel.connect/1"))
        XCTAssertThrowsError(try HCGConnectConfiguration.load(Data(#"{"contractVersion":"hcg.sentinel.connect/1","clientSecret":"x"}"#.utf8)))
        XCTAssertThrowsError(try HCGConnectConfiguration.load(Data(#"{"contractVersion":"hcg.sentinel.connect/1","typo":1}"#.utf8)))
        let ok = try HCGConnectConfiguration.load(Data(#"{"contractVersion":"hcg.sentinel.connect/1","clientId":"11111111-1111-4111-8111-111111111111","redirectUri":"com.example.app:/oauth/callback"}"#.utf8))
        XCTAssertNil(ok.problem(expectedContract: "hcg.sentinel.connect/1"))
        XCTAssertEqual(ok.tokenEndpoint, HCGConnectConfiguration.defaultIssuer + "/oauth/token")
    }

    static func jwt(_ claims: [String: Any]) -> String {
        let h = LinkCrypto.base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "ES256"]))
        let c = LinkCrypto.base64URL(try! JSONSerialization.data(withJSONObject: claims))
        return "\(h).\(c).c2ln"
    }

    func testSignInFlowChecksStateNonceAndClient() async throws {
        let clientId = "11111111-1111-4111-8111-111111111111"
        let cfg = HCGConnectConfiguration(contractVersion: "hcg.sentinel.connect/1", clientId: clientId, redirectUri: "com.example.app:/oauth/callback")
        final class Box: @unchecked Sendable { var nonce = ""; var forms: [String] = [] }
        let box = Box()
        let auth = HCGConnectAuth(configuration: cfg, expectedContract: "hcg.sentinel.connect/1") { req in
            box.forms.append(String(decoding: req.httpBody ?? Data(), as: UTF8.self))
            let at = HCGConnectTests.jwt(["sub": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "client_id": clientId, "email": "a@example.test"])
            let id = HCGConnectTests.jwt(["nonce": box.nonce, "aud": clientId, "iss": cfg.issuer])
            let body = try JSONSerialization.data(withJSONObject: ["access_token": at, "refresh_token": "r1", "id_token": id, "expires_in": 3600])
            return (body, 200)
        }
        let attempt = try auth.begin()
        box.nonce = attempt.nonce
        let items = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, clientId)
        XCTAssertNil(items.first { $0.name.contains("secret") })

        await XCTAssertThrowsErrorAsync(try await auth.complete(attempt, callback: URL(string: "com.example.app:/oauth/callback?code=c&state=wrong")!))
        let tokens = try await auth.complete(attempt, callback: URL(string: "com.example.app:/oauth/callback?code=c&state=\(attempt.state)")!)
        XCTAssertEqual(tokens.subject, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertTrue(box.forms.last!.contains("code_verifier=\(attempt.pkce.verifier)"))
        box.nonce = "other"
        await XCTAssertThrowsErrorAsync(try await auth.complete(attempt, callback: URL(string: "com.example.app:/oauth/callback?code=c&state=\(attempt.state)")!))
    }

    func testSessionEndsWhenRefreshIsRefused() async throws {
        let cfg = HCGConnectConfiguration(contractVersion: "hcg.sentinel.connect/1", clientId: "11111111-1111-4111-8111-111111111111", redirectUri: "x:/cb")
        let auth = HCGConnectAuth(configuration: cfg, expectedContract: "hcg.sentinel.connect/1") { _ in
            (Data(#"{"error":"refresh_token_already_used"}"#.utf8), 400)
        }
        let store = SecretTokenStore(store: MemorySecretStore())
        let session = HCGConnectSession(auth: auth, store: store)
        try await session.signedIn(HCGConnectTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(10), subject: "s", email: nil, clientId: cfg.clientId!))
        await XCTAssertThrowsErrorAsync(try await session.accessToken(forceRefresh: false))
        let current = await session.current
        XCTAssertNil(current)
        XCTAssertNil(store.load())
    }

    func testInstallationIdentityPersists() throws {
        let store = MemorySecretStore()
        let a = try InstallationIdentity.loadOrCreate(store: store)
        let b = try InstallationIdentity.loadOrCreate(store: store)
        XCTAssertEqual(a.installationId, b.installationId)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        InstallationIdentity.reset(store: store)
        let c = try InstallationIdentity.loadOrCreate(store: store)
        XCTAssertNotEqual(a.installationId, c.installationId)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expr: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expr()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
