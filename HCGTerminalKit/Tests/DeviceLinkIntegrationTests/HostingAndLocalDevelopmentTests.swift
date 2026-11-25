@testable import DeviceLinkIntegration
import Foundation
import HCGDeviceLink
import XCTest

/// Local development pairing, the HCG Server host and its hosted services, read-only
/// diagnostics and `authority_changed`.
@MainActor
final class HostingAndLocalDevelopmentTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-devicelink-hosting-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    static let notConfigured = HCGConnectSetup.notConfigured(HCGConnectSetup.noClientMessage)
    nonisolated static let localCode = InvitationFixture.code(authMode: DeviceLinkProtocol.Authority.localDevelopment)

    private func controller(_ server: FakeLinkServer, connect: HCGConnectSetup = notConfigured,
                            store: MemorySecretStore = MemorySecretStore()) -> DeviceLinkController {
        makeTestLinkController(folder: folder, connect: connect, store: store, server: server)
    }

    /// Paired in local development mode, approved and synced once.
    private func connectedLocally(_ server: FakeLinkServer, store: MemorySecretStore = MemorySecretStore()) async -> DeviceLinkController {
        let link = controller(server, store: store)
        await link.activate()
        await link.pair(code: Self.localCode)
        server.pairStatus = "approved"
        await link.syncNow()
        await link.syncNow()
        return link
    }

    // MARK: Local development pairing

    func testLocalDevelopmentInvitationPairsWithoutHCGConnect() async throws {
        let server = FakeLinkServer()
        let store = MemorySecretStore()
        let link = controller(server, store: store)
        await link.activate()
        XCTAssertEqual(link.state, .notConfigured(reason: HCGConnectSetup.noClientMessage))
        XCTAssertFalse(link.canPair, "a normal invitation still needs HCG Connect")

        guard case .success(let invitation) = link.previewInvitation(Self.localCode) else { return XCTFail() }
        XCTAssertTrue(invitation.isLocalDevelopment)
        XCTAssertTrue(link.canPair(invitation))
        XCTAssertTrue(server.requests.isEmpty, "previewing sends nothing")

        await link.pair(code: Self.localCode)
        guard case .pairing(let progress) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertTrue(progress.pending)
        XCTAssertTrue(link.isLocalDevelopment)
        XCTAssertEqual(link.pairing?.authMode, DeviceLinkProtocol.Authority.localDevelopment)
        // The record on disk remembers the path, so a relaunch uses it too.
        XCTAssertEqual(PairingRecordFile(url: folder.appendingPathComponent("pairing.json")).load()?.isLocalDevelopment, true)

        server.pairStatus = "approved"
        await link.syncNow()
        XCTAssertEqual(link.state, .connected(lastSync: nil))
        await link.syncNow()
        guard case .connected(.some) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertFalse(server.requests("/heartbeat").isEmpty)
        XCTAssertNil(link.account, "no HCG account is involved")
        for request in server.requests {
            XCTAssertNil(request.headers["Authorization"], "no HCG token is ever sent: \(request.url.path)")
        }

        // Relaunch: the stored pairing resumes without HCG Connect or a sign-in.
        let relaunched = controller(server, store: store)
        await relaunched.activate()
        XCTAssertEqual(relaunched.state, .connected(lastSync: nil))
        XCTAssertTrue(relaunched.isLocalDevelopment)
        let before = server.requests.count
        await relaunched.syncNow()
        guard case .connected(.some) = relaunched.state else { return XCTFail("\(relaunched.state)") }
        XCTAssertGreaterThan(server.requests.count, before)
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["Authorization"] == nil })
    }

    func testNormalInvitationKeepsTheHCGConnectPath() async throws {
        // Without HCG Connect, a normal invitation sends nothing.
        let server = FakeLinkServer()
        let unconfigured = controller(server)
        await unconfigured.activate()
        await unconfigured.pair(code: InvitationFixture.code())
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(unconfigured.notice, "Sign in with HCG Connect first. A paired device must be removed before pairing again.")

        // Signed in with HCG Connect, a normal invitation carries the HCG token and no local-development mark.
        let signedIn = makeTestLinkController(folder: folder.appendingPathComponent("b"), connect: DeviceLinkControllerTests.readyConnect,
                                              store: DeviceLinkControllerTests.signedInStore(), server: server)
        await signedIn.activate()
        await signedIn.pair(code: InvitationFixture.code())
        guard case .pairing = signedIn.state else { return XCTFail("\(signedIn.state)") }
        XCTAssertFalse(signedIn.isLocalDevelopment)
        XCTAssertNil(signedIn.pairing?.authMode)
        XCTAssertEqual(server.requests("/pair").first?.headers["Authorization"], "Bearer header.payload.signature")
    }

    func testSignedInDeviceStillSendsNoTokenToALocalDevelopmentServer() async throws {
        let server = FakeLinkServer()
        let link = controller(server, connect: DeviceLinkControllerTests.readyConnect, store: DeviceLinkControllerTests.signedInStore())
        await link.activate()
        XCTAssertNotNil(link.account)
        await link.pair(code: Self.localCode)
        server.pairStatus = "approved"
        await link.syncNow()
        await link.syncNow()
        guard case .connected(.some) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["Authorization"] == nil })
    }

    // MARK: Host, services and diagnostics

    func testHostServicesAndDiagnosticsShowWhatTheServerReturned() async throws {
        let server = FakeLinkServer()
        let link = controller(server)
        await link.activate()
        XCTAssertEqual(link.hostAvailability, .unknown)
        XCTAssertNil(link.hostSummary, "nothing is shown before the server answers")
        XCTAssertNil(link.hostedServices)

        await link.pair(code: Self.localCode)
        server.pairStatus = "approved"
        await link.syncNow()
        XCTAssertEqual(link.hostAvailability, .unknown, "approval alone is not a sync")
        await link.syncNow()

        guard case .reachable(let at) = link.hostAvailability else { return XCTFail("\(link.hostAvailability)") }
        XCTAssertEqual(at, link.lastSync)
        let host = try XCTUnwrap(link.hostSummary)
        XCTAssertEqual(host.name, "Studio Mac")
        XCTAssertEqual(HostingText.platform(host), "darwin 26.1 · arm64")
        XCTAssertEqual(HostingText.chip(host), "Apple M3 Pro · 12 cores")
        XCTAssertEqual(HostingText.memory(host), "36 GB · 12 GB available")
        XCTAssertEqual(HostingText.agentUptime(host), "2 h")
        XCTAssertEqual(HostingText.exposure(host.gatewayExposure), "Local network (approved by the owner)")
        XCTAssertNotNil(link.hostingUpdatedAt)

        let services = try XCTUnwrap(link.hostedServices)
        XCTAssertEqual(services.map(\.id), ["system-tester"])
        XCTAssertEqual(HostingText.serviceLine(services[0]), "Running · Healthy · up 2 h 5 min · 1 restart")
        XCTAssertTrue(services[0].openable)

        let diagnostics = try XCTUnwrap(link.diagnostics)
        XCTAssertEqual(diagnostics.failedAuthentications24h, 2)
        XCTAssertEqual(diagnostics.summary, ["HCG Server 0.9.0 is running.", "1 of 1 hosted services healthy."])
        XCTAssertEqual(diagnostics.securityEvents.map(\.severity), ["warning"])
        XCTAssertEqual(LinkAuthorityText.label(diagnostics.server.authority), LinkAuthorityText.localDevelopmentLabel)
        XCTAssertEqual(diagnostics.tls.gatewayCaSha256, FakeLinkServer.caFingerprint)
        XCTAssertNil(link.sectionProblems[.services])
        XCTAssertNil(link.sectionProblems[.diagnostics])
        // Read only: nothing but GETs for the hosting data, and no action is ever requested.
        XCTAssertTrue(server.requests("/services").allSatisfy { $0.method == "GET" })
        XCTAssertTrue(server.requests("/diagnostics").allSatisfy { $0.method == "GET" })
        XCTAssertFalse(server.requests.contains { $0.url.path.contains("/actions") })
    }

    func testServerWithoutHostingShowsNoHostData() async throws {
        let server = FakeLinkServer()
        server.hosting = false
        let link = await connectedLocally(server)
        guard case .connected(.some) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertNil(link.hostSummary)
        XCTAssertNil(link.hostedServices)
        XCTAssertNil(link.diagnostics)
        XCTAssertEqual(link.sectionProblems[.services], HostingText.notHosting)
        XCTAssertEqual(link.sectionProblems[.diagnostics], HostingText.notHosting)
    }

    func testDataFromAnEarlierAnswerIsDroppedWhenTheServerStopsGivingIt() async throws {
        let server = FakeLinkServer()
        let link = await connectedLocally(server)
        XCTAssertNotNil(link.hostedServices)
        server.pathFailures["/link/services"] = (403, "permission_denied", false)
        await link.syncNow()
        XCTAssertNil(link.hostedServices)
        XCTAssertNil(link.hostSummary)
        XCTAssertEqual(link.sectionProblems[.services], "Refused: permission_denied")
        XCTAssertNotNil(link.diagnostics, "the other section is unaffected")
    }

    func testHostAvailabilityReportsTheRealError() async throws {
        let server = FakeLinkServer()
        let link = await connectedLocally(server)
        server.transportFailure = .unreachable("The network connection was lost.")
        await link.syncNow()
        guard case .unreachable(let reason, let retry) = link.hostAvailability else { return XCTFail("\(link.hostAvailability)") }
        XCTAssertEqual(reason, "HCG Server could not be reached (The network connection was lost.).")
        XCTAssertGreaterThan(retry, 0)

        server.transportFailure = nil
        server.failure = (503, "hcg_unavailable", true)
        await link.syncNow()
        guard case .failing(let message, _) = link.hostAvailability else { return XCTFail("\(link.hostAvailability)") }
        XCTAssertEqual(message, "Refused: hcg_unavailable.")

        server.failure = nil
        await link.syncNow()
        guard case .reachable = link.hostAvailability else { return XCTFail("\(link.hostAvailability)") }
    }

    // MARK: Opening a hosted service

    func testOpenServiceReturnsTheHTTPSLinkAndKeepsOnlyTheCA() async throws {
        let server = FakeLinkServer()
        let link = await connectedLocally(server)
        let service = try XCTUnwrap(link.hostedServices?.first)
        let opened = await link.openService(service)
        let url = try XCTUnwrap(opened)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.absoluteString, server.ticketURL)
        XCTAssertEqual(server.requests("/services/system-tester/open").map(\.method), ["POST"])
        let ticket = try XCTUnwrap(link.openedTicket)
        XCTAssertEqual(ticket.serviceName, "HCG System Tester")
        XCTAssertEqual(ticket.caFingerprint, FakeLinkServer.caFingerprint)
        XCTAssertEqual(ticket.note, "Opens once within 60 seconds.")
        XCTAssertEqual(link.ticketCAMatchesDiagnostics, true)
        XCTAssertNil(link.serviceProblems[service.id])
        XCTAssertNil(link.openingService)
    }

    func testGatewayLocalOnlyIsExplained() async throws {
        let server = FakeLinkServer()
        server.exposure = "loopback"
        let link = await connectedLocally(server)
        let service = try XCTUnwrap(link.hostedServices?.first)
        XCTAssertFalse(service.openable)
        XCTAssertEqual(HostingText.exposure(try XCTUnwrap(link.hostSummary).gatewayExposure), "This Mac only (local network not approved)")
        let url = await link.openService(service)
        XCTAssertNil(url)
        XCTAssertEqual(link.serviceProblems[service.id], HostingText.gatewayLocalOnly)
        XCTAssertTrue(HostingText.gatewayLocalOnly.contains("owner must approve local-network exposure on the Mac"))
        XCTAssertNil(link.openedTicket)
        guard case .connected = link.state else { return XCTFail("a refused link does not end the connection: \(link.state)") }
    }

    func testALinkThatIsNotHTTPSIsNotOpened() async throws {
        let server = FakeLinkServer()
        server.ticketURL = "http://dev-mac.local:7620/access/ticket?t=single-use"
        let link = await connectedLocally(server)
        let service = try XCTUnwrap(link.hostedServices?.first)
        let url = await link.openService(service)
        XCTAssertNil(url)
        XCTAssertEqual(link.serviceProblems[service.id], "HCG Server returned a link that is not an HTTPS address. It was not opened.")
        XCTAssertNil(link.openedTicket)
    }

    // MARK: authority_changed

    func testAuthorityChangedEndsTheLinkAndOffersToPairAgain() async throws {
        let server = FakeLinkServer()
        let store = MemorySecretStore()
        let link = await connectedLocally(server, store: store)
        let oldKey = try XCTUnwrap(link.identity?.fingerprint)
        server.failure = (403, "authority_changed", false)
        await link.syncNow()

        guard case .authorityChanged(let reason) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertTrue(reason.contains("Refused: authority_changed"), reason)
        XCTAssertTrue(reason.contains("Pair again with a new invitation"), reason)
        XCTAssertEqual(link.state.title, "Pair again")
        XCTAssertEqual(link.pairing?.status, .removed)
        XCTAssertNil(link.hostSummary)
        XCTAssertNil(link.hostedServices)
        XCTAssertNil(link.diagnostics)
        XCTAssertNotEqual(link.identity?.fingerprint, oldKey, "the server refuses the old installation; a new key is used")
        XCTAssertEqual(link.hostAvailability, .unknown)

        let count = server.requests.count
        await link.syncNow()
        XCTAssertEqual(server.requests.count, count, "never retried automatically")

        // A relaunch shows the same state, not a generic removal.
        let relaunched = controller(server, store: store)
        await relaunched.activate()
        XCTAssertEqual(relaunched.state, link.state)
        XCTAssertEqual(server.requests.count, count)

        // Pairing again with a new invitation is offered and clears the note.
        guard case .success(let invitation) = relaunched.previewInvitation(Self.localCode) else { return XCTFail() }
        XCTAssertTrue(relaunched.canPair(invitation))
        server.failure = nil
        await relaunched.pair(code: Self.localCode)
        guard case .pairing = relaunched.state else { return XCTFail("\(relaunched.state)") }
        XCTAssertNil(relaunched.endNote)
        XCTAssertNil(LinkEndNote.load(besides: PairingRecordFile(url: folder.appendingPathComponent("pairing.json"))))
    }

    func testAuthorityChangedWhileOpeningAServiceEndsTheLink() async throws {
        let server = FakeLinkServer()
        let link = await connectedLocally(server)
        let service = try XCTUnwrap(link.hostedServices?.first)
        server.pathFailures["/open"] = (403, "authority_changed", false)
        let url = await link.openService(service)
        XCTAssertNil(url)
        guard case .authorityChanged = link.state else { return XCTFail("\(link.state)") }
        XCTAssertEqual(link.pairing?.status, .removed)
        XCTAssertNil(link.hostedServices)
    }

    func testAuthorityChangedWhilePairingEndsTheRequest() async throws {
        let server = FakeLinkServer()
        let link = controller(server)
        await link.activate()
        await link.pair(code: Self.localCode)
        server.pathFailures["/pair/req_1"] = (409, "authority_changed", false)
        await link.syncNow()
        guard case .authorityChanged = link.state else { return XCTFail("\(link.state)") }
    }
}

/// Pure parts: the state machine, the resting state and the wording.
final class HostingTextTests: XCTestCase {
    private func serverError(_ status: Int, _ code: String, _ message: String) -> DeviceLinkError {
        let object: [String: Any] = ["error": message, "code": code, "retryable": false]
        let body = try! JSONDecoder().decode(LinkErrorBody.self, from: JSONSerialization.data(withJSONObject: object))
        return .server(status: status, body: body)
    }

    func testAuthorityChangedIsNeverRetried() {
        var machine = LinkConnectionMachine()
        let error = serverError(403, "authority_changed", "HCG Connect is now configured")
        let outcome = machine.failed(error)
        XCTAssertNil(outcome.retryIn)
        guard case .authorityChanged(let reason) = outcome.state else { return XCTFail("\(outcome.state)") }
        XCTAssertTrue(reason.contains("HCG Connect is now configured."))
        XCTAssertFalse(outcome.state.isLinked)
    }

    func testLocalDevelopmentPairingRestsWithoutHCGConnect() throws {
        let local = try Invitation.parse(HostingAndLocalDevelopmentTests.localCode)
        var record = PairingRecord(invitation: local, requestId: "req_1", status: .approved)
        let notConfigured = HCGConnectSetup.notConfigured("no client")
        XCTAssertEqual(LinkConnectionMachine.resting(connect: notConfigured, signedIn: false, pairing: record, deviceFingerprint: "bb"),
                       .connected(lastSync: nil))
        record.status = .removed
        guard case .removed = LinkConnectionMachine.resting(connect: notConfigured, signedIn: false, pairing: record, deviceFingerprint: nil) else {
            return XCTFail()
        }
        let note = LinkEndNote(code: "authority_changed", reason: "Pair again.")
        XCTAssertEqual(LinkConnectionMachine.resting(connect: notConfigured, signedIn: false, pairing: record, deviceFingerprint: nil, ended: note),
                       .authorityChanged(reason: "Pair again."))

        // A normal pairing keeps the HCG Connect requirements.
        let normal = PairingRecord(invitation: InvitationFixture.invitation(), requestId: "req_1", status: .approved)
        XCTAssertEqual(LinkConnectionMachine.resting(connect: notConfigured, signedIn: true, pairing: normal, deviceFingerprint: nil),
                       .notConfigured(reason: "no client"))
    }

    func testAuthorityLabels() {
        XCTAssertEqual(LinkAuthorityText.localDevelopmentLabel, "LOCAL DEVELOPMENT — not an HCG account")
        XCTAssertEqual(LinkAuthorityText.label("local-development"), LinkAuthorityText.localDevelopmentLabel)
        XCTAssertEqual(LinkAuthorityText.label("hcg-connect"), "HCG Connect")
        XCTAssertEqual(LinkAuthorityText.label("not-configured"), "Not configured")
        XCTAssertEqual(LinkAuthorityText.label(nil), "Not reported")
    }

    func testFormatting() {
        XCTAssertEqual(HostingText.bytes(8 * 1_073_741_824), "8 GB")
        XCTAssertEqual(HostingText.bytes(3_221_225_472 / 2), "1.5 GB")
        XCTAssertEqual(HostingText.bytes(512 * 1_048_576), "512 MB")
        XCTAssertEqual(HostingText.duration(42), "42 s")
        XCTAssertEqual(HostingText.duration(3_900), "1 h 5 min")
        XCTAssertEqual(HostingText.duration(3 * 86_400 + 4 * 3_600 + 5), "3 d 4 h")
        XCTAssertEqual(HostingText.status("crashed"), "Crashed")
        XCTAssertEqual(HostingText.health("failing"), "Health check failing")
        XCTAssertEqual(HostingText.health("whatever"), "Health unknown")
        XCTAssertEqual(HostingText.exposure("loopback"), "This Mac only (local network not approved)")
        let gatewayLocalOnly = serverError(409, "gateway_local_only", "x")
        XCTAssertEqual(HostingText.openFailure(gatewayLocalOnly), HostingText.gatewayLocalOnly)
        let other = serverError(503, "gateway_down", "HCG Server's gateway is not running")
        XCTAssertEqual(HostingText.openFailure(other), "HCG Server's gateway is not running")
    }
}
