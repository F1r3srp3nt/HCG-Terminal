import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HCGDeviceLink
import Observation

/// This installation's identity, as shown on the Connected Devices screen.
public struct LocalLinkIdentity: Equatable, Sendable {
    public var installationId: String
    public var fingerprint: String
    /// "secure-enclave" or "software".
    public var keyKind: String

    public var shortInstallationId: String { String(installationId.prefix(8)) }
    public var displayFingerprint: String { LinkCrypto.displayFingerprint(fingerprint) }
    public var keyKindLabel: String { keyKind == "secure-enclave" ? "Secure Enclave P-256" : "Software P-256 (Keychain, this device only)" }
}

/// The signed-in HCG Connect account (from the token, as HCG Connect issued it).
public struct LinkAccountSummary: Equatable, Sendable {
    public var subject: String
    public var email: String?
}

/// A shared report fetched for viewing. It is data: the viewer renders `sections` as plain
/// text, and nothing in it is executed, opened or passed to a shell.
public struct OpenedLinkReport: Equatable, Sendable, Identifiable {
    public var header: LinkMessageHeader
    public var report: DiagnosticReport
    public var sections: [ReportTextRenderer.Section]
    public var id: String { header.messageId }
}

/// Parts of the screen that can fail on their own (for example a missing ERP permission for
/// one operation) without ending the connection.
public enum LinkSection: String, Sendable, CaseIterable {
    case devices, inbox, approvals
    /// The HCG Server host and the services it hosts (`link/services`).
    case services
    /// Read-only server diagnostics (`link/diagnostics`).
    case diagnostics
}

struct NoAccessToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String {
        throw HCGConnectError.notConfigured("Not signed in to HCG Connect.")
    }
}

/// Drives HCG Device Link for the Connected Devices screen: identity, HCG Connect sign-in,
/// pairing, and the foreground sync loop (heartbeat every 20 s, inbox every 10 s, back-off on
/// retryable errors, stop when the link ends). With each heartbeat it also reads the HCG Server
/// host, its hosted services and its read-only diagnostics.
///
/// Two pairing paths exist. A normal invitation uses HCG Connect (sign-in and tokens). An
/// invitation from a server in local development pairing mode (`Invitation.isLocalDevelopment`)
/// uses `LocalDevelopmentTokens` (no HCG token is ever sent); the pairing record remembers that,
/// and the screen labels it "LOCAL DEVELOPMENT — not an HCG account".
///
/// Remote action execution stays disabled: this controller never requests or runs an action,
/// and offers no remote shell.
///
/// Nothing received from the server is executed or changes what this app may do locally. The
/// capabilities sent with each heartbeat come from `capabilityProvider`, which the app computes
/// from its own verified capability reports.
@MainActor
@Observable
public final class DeviceLinkController {
    public let environment: DeviceLinkEnvironment
    /// This app's own advertisement (`TerminalLinkCapabilities.advertised`). Never fed by server data.
    @ObservationIgnored public var capabilityProvider: @MainActor () -> [LinkCapability]

    public private(set) var state: LinkConnectionState
    public private(set) var identity: LocalLinkIdentity?
    public private(set) var identityProblem: String?
    public private(set) var account: LinkAccountSummary?
    public private(set) var pairing: PairingRecord?
    public private(set) var devices: LinkDevices?
    public private(set) var inbox: [LinkMessageHeader] = []
    public private(set) var approvals: LinkApprovals?
    public private(set) var sectionProblems: [LinkSection: String] = [:]
    /// The server's computer, as the last successful `link/services` answer described it.
    public private(set) var hostSummary: LinkHostSummary?
    /// The services HCG Server hosts (nil until loaded; empty when it hosts none).
    public private(set) var hostedServices: [LinkHostedService]?
    /// When `hostSummary` and `hostedServices` were last loaded (this device's clock).
    public private(set) var hostingUpdatedAt: Date?
    /// Read-only, redacted server diagnostics.
    public private(set) var diagnostics: LinkDiagnostics?
    /// Why opening a hosted service failed, by service ID.
    public private(set) var serviceProblems: [String: String] = [:]
    /// The service whose single-use link is being requested.
    public private(set) var openingService: String?
    /// The last service opened in the system browser (the link itself is not kept).
    public private(set) var openedTicket: OpenedServiceTicket?
    /// Why the server ended the link, when it was `authority_changed` (shown after a relaunch too).
    public private(set) var endNote: LinkEndNote?
    public private(set) var lastSync: Date?
    /// The outcome of the last action the person took (pairing, removal, sign-in).
    public var notice: String?
    public private(set) var isBusy = false
    public private(set) var isSyncing = false
    /// `activate()` has run once (before that, the state is a guess from the configuration only).
    public private(set) var hasLoaded = false

    @ObservationIgnored private var installation: InstallationIdentity?
    @ObservationIgnored private var session: HCGConnectSession?
    @ObservationIgnored private var client: DeviceLinkClient?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var machine = LinkConnectionMachine()
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var syncGeneration = 0
    /// The error behind the current `offline` state (to tell "unreachable" from "answered with an error").
    @ObservationIgnored private var lastFailure: DeviceLinkError?
    /// Whether `activate()` and pairing start the foreground sync loop (tests drive `syncNow()`).
    @ObservationIgnored public var automaticSync = true

    public init(environment: DeviceLinkEnvironment, capabilityProvider: @escaping @MainActor () -> [LinkCapability] = { [] }) {
        self.environment = environment
        self.capabilityProvider = capabilityProvider
        if let problem = environment.connect.problem {
            state = .notConfigured(reason: problem)
        } else {
            state = .signedOut
        }
    }

    /// What this installation advertises now (recomputed from local reports each time).
    public var advertisedCapabilities: [LinkCapability] { capabilityProvider() }

    public var signedIn: Bool { account != nil }

    /// The pairing was made in HCG Server's local development mode: no HCG account, this server only.
    public var isLocalDevelopment: Bool { pairing?.isLocalDevelopment == true }

    /// Whether the server answered the last sync round, from real requests only.
    public var hostAvailability: HostAvailability {
        switch state {
        case .connected:
            if let lastSync { return .reachable(at: lastSync) }
            return .unknown
        case .offline(let retry, let reason):
            switch lastFailure {
            case .server?, .invalidResponse?: return .failing(reason: reason, retryIn: retry)
            default: return .unreachable(reason: reason, retryIn: retry)
            }
        default:
            return .unknown
        }
    }

    /// The last opened link's CA matches the CA the server's diagnostics report (nil when either is unknown).
    public var ticketCAMatchesDiagnostics: Bool? {
        guard let ticket = openedTicket, let ca = diagnostics?.tls.gatewayCaSha256, !ca.isEmpty else { return nil }
        return ticket.caFingerprint.lowercased() == ca.lowercased()
    }

    /// Other installations of the server's boundary (this one is shown separately).
    public var remoteDevices: [LinkInstallation] {
        guard let devices else { return [] }
        return devices.installations.filter { $0.installationId != devices.selfInstallationId && $0.installationId != identity?.installationId }
    }

    // MARK: - Lifecycle

    /// Loads the identity, the session and the pairing record, then starts syncing when paired.
    /// Call when the screen appears and when the app returns to the foreground.
    public func activate() async {
        if !activated {
            activated = true
            hasLoaded = true
            loadIdentity()
            pairing = environment.pairingFile.load()
            endNote = LinkEndNote.load(besides: environment.pairingFile)
            if let configuration = environment.connect.configuration {
                let auth = HCGConnectAuth(configuration: configuration, expectedContract: HCGConnectSetup.contract, send: environment.connectSend)
                session = HCGConnectSession(auth: auth, store: SecretTokenStore(store: environment.secrets), now: environment.now)
            }
        }
        await refreshAccount()
        // A running loop owns the state (for example "offline, retrying"); otherwise start from
        // what is stored.
        if syncTask == nil { resetToResting() }
        startSyncIfNeeded()
    }

    /// Stops syncing (screen hidden or app in the background). Nothing is sent while stopped.
    public func deactivate() {
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
    }

    private func loadIdentity() {
        do {
            let id = try InstallationIdentity.loadOrCreate(store: environment.secrets, preferSecureEnclave: environment.preferSecureEnclave)
            installation = id
            identity = LocalLinkIdentity(installationId: id.installationId, fingerprint: id.fingerprint, keyKind: id.keyKind)
            identityProblem = nil
        } catch {
            installation = nil
            identity = nil
            identityProblem = "The installation key could not be created or read from the Keychain (\(error.localizedDescription))."
        }
    }

    private func refreshAccount() async {
        guard let session, let tokens = await session.current else {
            account = nil
            return
        }
        account = LinkAccountSummary(subject: tokens.subject, email: tokens.email)
    }

    private func resetToResting() {
        state = LinkConnectionMachine.resting(connect: environment.connect, signedIn: signedIn, pairing: pairing,
                                              deviceFingerprint: identity?.fingerprint, ended: endNote)
        if case .connected = state, let lastSync { state = .connected(lastSync: lastSync) }
    }

    private func startSyncIfNeeded() {
        guard activated, automaticSync, syncTask == nil else { return }
        switch state {
        case .pairing, .connected, .offline: break
        default: return
        }
        guard makeClient() != nil else { return }
        isSyncing = true
        syncGeneration += 1
        let generation = syncGeneration
        syncTask = Task { [weak self] in
            await self?.runSync()
            self?.syncFinished(generation)
        }
    }

    private func syncFinished(_ generation: Int) {
        guard generation == syncGeneration else { return }
        syncTask = nil
        isSyncing = false
    }

    @discardableResult
    private func makeClient() -> DeviceLinkClient? {
        if let client { return client }
        guard let pairing, let installation, let base = pairing.baseURL else { return nil }
        guard let transport = environment.makeTransport(pairing.serverFingerprint) else {
            state = .notConfigured(reason: "Device Link has no pinned network transport on this platform. Nothing is contacted.")
            return nil
        }
        let made = DeviceLinkClient(
            configuration: DeviceLinkConfiguration(baseURL: base, serverFingerprint: pairing.serverFingerprint, installationId: installation.installationId),
            signer: installation.signer, transport: transport, tokens: tokens(localDevelopment: pairing.isLocalDevelopment), now: environment.now
        )
        client = made
        return made
    }

    /// Local development: never an HCG token (the server refuses one). Otherwise HCG Connect.
    private func tokens(localDevelopment: Bool) -> any AccessTokenProvider {
        if localDevelopment { return LocalDevelopmentTokens() }
        if let session { return session }
        return NoAccessToken()
    }

    // MARK: - HCG Connect

    /// Starts a sign-in (the view opens `url` in an ASWebAuthenticationSession).
    public func beginSignIn() throws -> SignInAttempt {
        guard let configuration = environment.connect.configuration else {
            throw HCGConnectError.notConfigured(environment.connect.problem ?? HCGConnectSetup.noClientMessage)
        }
        return try HCGConnectAuth(configuration: configuration, expectedContract: HCGConnectSetup.contract, send: environment.connectSend).begin()
    }

    /// Finishes a sign-in with the callback URL. Tokens are kept only in the Keychain.
    public func completeSignIn(_ attempt: SignInAttempt, callback: URL) async {
        guard let session, let configuration = environment.connect.configuration else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let auth = HCGConnectAuth(configuration: configuration, expectedContract: HCGConnectSetup.contract, send: environment.connectSend)
            let tokens = try await auth.complete(attempt, callback: callback, now: environment.now())
            try await session.signedIn(tokens)
            notice = "Signed in to HCG Connect."
        } catch let error as HCGConnectError {
            notice = error.description
        } catch {
            notice = "Sign-in failed: \(error.localizedDescription)"
        }
        await refreshAccount()
        machine = LinkConnectionMachine()
        resetToResting()
        startSyncIfNeeded()
    }

    /// Local sign-out (HCG Connect has no revocation endpoint). Syncing stops.
    public func signOut() async {
        deactivate()
        await session?.signOut()
        account = nil
        resetToResting()
        notice = "Signed out of HCG Connect on this device."
        // A local-development pairing does not use the sign-in and keeps syncing.
        startSyncIfNeeded()
    }

    // MARK: - Pairing

    /// Parses an invitation code for the comparison step. Nothing is sent.
    public func previewInvitation(_ code: String) -> Result<Invitation, Invitation.Problem> {
        do { return .success(try Invitation.parse(code, now: environment.now())) } catch let problem as Invitation.Problem {
            return .failure(problem)
        } catch {
            return .failure(.corrupted)
        }
    }

    /// Whether a normal (HCG Connect) invitation can be used now.
    public var canPair: Bool { canPair(localDevelopment: false) }

    /// Whether this invitation can be used now. A local-development invitation needs no HCG
    /// Connect configuration or sign-in; any other invitation does.
    public func canPair(_ invitation: Invitation) -> Bool { canPair(localDevelopment: invitation.isLocalDevelopment) }

    private func canPair(localDevelopment: Bool) -> Bool {
        guard identity != nil else { return false }
        if !localDevelopment {
            guard signedIn, environment.connect.configuration != nil else { return false }
        }
        if let pairing { return pairing.status != .approved && pairing.status != .pending }
        return true
    }

    /// Sends the pairing request for an invitation code. The server's owner approves it after
    /// comparing this installation's key fingerprint.
    public func pair(code: String) async {
        let invitation: Invitation
        switch previewInvitation(code) {
        case .success(let parsed): invitation = parsed
        case .failure(let problem):
            notice = problem.description
            return
        }
        guard canPair(invitation), let installation else {
            notice = invitation.isLocalDevelopment
                ? "A paired device must be removed before pairing again."
                : "Sign in with HCG Connect first. A paired device must be removed before pairing again."
            return
        }
        guard let base = invitation.baseURL else {
            notice = Invitation.Problem.incomplete.description
            return
        }
        guard let transport = environment.makeTransport(invitation.fingerprint) else {
            notice = "Device Link has no pinned network transport on this platform. Nothing was sent."
            return
        }
        isBusy = true
        defer { isBusy = false }
        let candidate = DeviceLinkClient(
            configuration: DeviceLinkConfiguration(baseURL: base, serverFingerprint: invitation.fingerprint, installationId: installation.installationId),
            signer: installation.signer, transport: transport, tokens: tokens(localDevelopment: invitation.isLocalDevelopment), now: environment.now
        )
        let device = environment.describeDevice()
        let info = LinkInstallationInfo(
            installationId: installation.installationId, deviceId: device.deviceId, name: device.name, platform: device.platform,
            app: LinkAppNames.terminal, appVersion: environment.appVersion, variant: environment.variant.wireValue,
            publicKey: installation.signer.publicKeyBase64, capabilities: advertisedCapabilities
        )
        do {
            let status = try await candidate.pair(invitation: invitation, info: info)
            guard status.keyFingerprint.lowercased() == installation.fingerprint else {
                notice = "HCG Server recorded a different key fingerprint than this device's. Nothing more was sent; do not approve the request."
                return
            }
            let record = PairingRecord(invitation: invitation, requestId: status.requestId, status: Self.recordStatus(status.status), at: environment.now())
            // The record keeps the invitation's `authMode`, so every later request uses the same path.
            try? environment.pairingFile.save(record)
            pairing = record
            client = candidate
            clearServerData()
            setEndNote(nil)
            machine = LinkConnectionMachine()
            notice = record.status == .approved ? "Paired with \(record.serverName)." : "Pairing request sent to \(record.serverName)."
            resetToResting()
            startSyncIfNeeded()
        } catch let error as DeviceLinkError {
            notice = "Pairing failed: \(error.description)"
        } catch {
            notice = "Pairing failed: \(error.localizedDescription)"
        }
    }

    static func recordStatus(_ status: String) -> PairingRecord.Status {
        switch status {
        case "approved": .approved
        case "rejected": .rejected
        case "expired": .expired
        default: .pending
        }
    }

    // MARK: - Sync

    /// One sync round now (pull to refresh). Does nothing unless paired.
    public func syncNow() async {
        guard let client = makeClient() else { return }
        switch state {
        case .pairing:
            _ = await pollPairing(client)
        case .connected, .offline:
            _ = await syncRound(client, heartbeat: true, inbox: true)
        default:
            break
        }
    }

    private func runSync() async {
        var nextHeartbeat = Date.distantPast
        var nextInbox = Date.distantPast
        while !Task.isCancelled, let client {
            let delay: TimeInterval?
            switch state {
            case .pairing:
                delay = await pollPairing(client)
                nextHeartbeat = .distantPast
                nextInbox = .distantPast
            case .connected, .offline:
                let now = environment.now()
                let doHeartbeat = now >= nextHeartbeat
                let doInbox = now >= nextInbox
                let failure = doHeartbeat || doInbox ? await syncRound(client, heartbeat: doHeartbeat, inbox: doInbox) : nil
                if let retry = failure {
                    delay = retry
                    nextHeartbeat = .distantPast
                    nextInbox = .distantPast
                } else if case .connected = state {
                    if doHeartbeat { nextHeartbeat = now.addingTimeInterval(DeviceLinkProtocol.heartbeatInterval) }
                    if doInbox { nextInbox = now.addingTimeInterval(DeviceLinkProtocol.inboxInterval) }
                    delay = max(0.5, min(nextHeartbeat, nextInbox).timeIntervalSince(environment.now()))
                } else {
                    delay = nil
                }
            default:
                delay = nil
            }
            guard let delay, !Task.isCancelled else { return }
            do { try await environment.sleep(delay) } catch { return }
        }
    }

    /// Polls the pairing request once. Returns the delay before the next poll, or nil to stop.
    private func pollPairing(_ client: DeviceLinkClient) async -> TimeInterval? {
        guard var record = pairing else { return nil }
        do {
            let status = try await client.pairingStatus(requestId: record.requestId)
            let newStatus = Self.recordStatus(status.status)
            if newStatus != record.status {
                record.status = newStatus
                record.updatedAt = environment.now()
                try? environment.pairingFile.save(record)
                pairing = record
            }
            machine = LinkConnectionMachine()
            resetToResting()
            switch newStatus {
            case .pending: return 3
            case .approved:
                notice = "\(record.serverName) approved this device."
                return 0
            default: return nil
            }
        } catch let error as DeviceLinkError {
            let outcome = machine.failed(error)
            if outcome.retryIn == nil {
                state = outcome.state
                await linkEnded()
                return nil
            }
            notice = "Could not check the pairing request: \(error.description)"
            return outcome.retryIn
        } catch {
            return ReconnectPolicy().maximum
        }
    }

    /// One heartbeat and/or inbox round. Returns a retry delay after a failure, nil otherwise
    /// (the state says whether syncing goes on).
    private func syncRound(_ client: DeviceLinkClient, heartbeat: Bool, inbox doInbox: Bool) async -> TimeInterval? {
        do {
            if heartbeat {
                // The advertisement is computed locally, right now; never copied from a response.
                _ = try await client.heartbeat(capabilities: advertisedCapabilities)
                try await section(.devices) { self.devices = try await client.devices() }
                try await section(.approvals) { self.approvals = try await client.approvals() }
                try await section(.services) {
                    let answer = try await client.services()
                    self.hostSummary = answer.host
                    self.hostedServices = answer.services
                    self.hostingUpdatedAt = self.environment.now()
                }
                try await section(.diagnostics) { self.diagnostics = try await client.diagnostics() }
            }
            if doInbox || heartbeat {
                try await section(.inbox) {
                    let messages = try await client.inbox()
                    self.inbox = messages
                    for message in messages where message.status == "queued" {
                        _ = try? await client.acknowledge(messageId: message.messageId, opened: false)
                    }
                }
            }
            let now = environment.now()
            lastSync = now
            lastFailure = nil
            state = machine.succeeded(at: now)
            return nil
        } catch let error as DeviceLinkError {
            lastFailure = error
            let outcome = machine.failed(error)
            state = outcome.state
            if outcome.retryIn == nil { await linkEnded() }
            return outcome.retryIn
        } catch {
            let wrapped = DeviceLinkError.invalidResponse(error.localizedDescription)
            lastFailure = wrapped
            let outcome = machine.failed(wrapped)
            state = outcome.state
            return outcome.retryIn
        }
    }

    /// Runs one optional part of a round: errors that end the link or are worth retrying are
    /// rethrown; anything else (for example a permission for that operation) is shown on its section.
    private func section(_ part: LinkSection, _ body: () async throws -> Void) async throws {
        do {
            try await body()
            sectionProblems[part] = nil
        } catch let error as DeviceLinkError where !error.endsLink && !error.isRetryable && error.code != "not_signed_in" {
            switch part {
            case .services:
                // Show nothing rather than an earlier answer the server no longer gives.
                hostSummary = nil
                hostedServices = nil
                hostingUpdatedAt = nil
                sectionProblems[part] = HostingText.sectionFailure(error)
            case .diagnostics:
                diagnostics = nil
                sectionProblems[part] = HostingText.sectionFailure(error)
            default:
                sectionProblems[part] = error.description
            }
        }
    }

    /// Drops everything the server sent (devices, reports, host, services, diagnostics).
    private func clearServerData() {
        devices = nil
        inbox = []
        approvals = nil
        hostSummary = nil
        hostedServices = nil
        hostingUpdatedAt = nil
        diagnostics = nil
        serviceProblems = [:]
        openedTicket = nil
        sectionProblems = [:]
        lastFailure = nil
    }

    private func setEndNote(_ note: LinkEndNote?) {
        endNote = note
        LinkEndNote.save(note, besides: environment.pairingFile)
    }

    /// The server ended the link: remember it, so returning to the screen does not retry.
    /// A removed installation stays removed until the person pairs again; an ended HCG session
    /// signs out locally, so the next attempt needs a fresh sign-in.
    /// `authority_changed` is handled the same way, and its reason is kept for the next launch.
    private func linkEnded() async {
        switch state {
        case .removed, .authorityChanged:
            if var record = pairing {
                record.status = .removed
                record.updatedAt = environment.now()
                try? environment.pairingFile.save(record)
                pairing = record
            }
            if case .authorityChanged(let reason) = state {
                setEndNote(LinkEndNote(code: "authority_changed", reason: reason))
            }
            client = nil
            clearServerData()
            // The key is bound to a registration the server no longer accepts; pairing again
            // uses a new installation ID and key.
            InstallationIdentity.reset(store: environment.secrets)
            loadIdentity()
        case .signInEnded:
            let ended = state
            await session?.signOut()
            account = nil
            state = ended
        default:
            break
        }
    }

    // MARK: - Reports

    /// Fetches a shared report for viewing. The caller renders it as plain text only.
    public func openReport(_ header: LinkMessageHeader) async throws -> OpenedLinkReport {
        guard let client else { throw DeviceLinkError.invalidRequest("This device is not paired.") }
        let (fresh, report) = try await client.open(messageId: header.messageId)
        return OpenedLinkReport(header: fresh, report: report, sections: ReportTextRenderer.sections(report))
    }

    /// Records that the report was shown. Idempotent on the server.
    public func markOpened(_ messageId: String) async {
        guard let client else { return }
        if let updated = try? await client.acknowledge(messageId: messageId, opened: true),
           let index = inbox.firstIndex(where: { $0.messageId == messageId }) {
            inbox[index] = updated
        }
    }

    // MARK: - Hosted services

    /// Asks HCG Server for a single-use, 60-second link to one hosted service and returns it for
    /// the system browser (Safari verifies the gateway with the HCG Server Local CA). Returns nil,
    /// with the reason in `serviceProblems`, when nothing should be opened. The link is not kept.
    public func openService(_ service: LinkHostedService) async -> URL? {
        guard let client, state.isLinked else {
            serviceProblems[service.id] = "This device is not connected to HCG Server."
            return nil
        }
        openingService = service.id
        defer { openingService = nil }
        do {
            let ticket = try await client.openService(service.id)
            guard let url = URL(string: ticket.url), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
                serviceProblems[service.id] = "HCG Server returned a link that is not an HTTPS address. It was not opened."
                return nil
            }
            serviceProblems[service.id] = nil
            openedTicket = OpenedServiceTicket(serviceId: service.id, serviceName: service.name, caFingerprint: ticket.caFingerprint,
                                               note: ticket.note, expiresAt: ticket.expiresAt, openedAt: environment.now())
            return url
        } catch let error as DeviceLinkError {
            if error.endsLink {
                lastFailure = error
                state = machine.failed(error).state
                await linkEnded()
                deactivate()
            } else {
                serviceProblems[service.id] = HostingText.openFailure(error)
            }
            return nil
        } catch {
            serviceProblems[service.id] = error.localizedDescription
            return nil
        }
    }

    // MARK: - Removal

    /// Asks HCG Server to remove this installation (`/unregister`, signed with the installation
    /// key), then forgets the pairing and the key on this device.
    public func unregister() async {
        guard let client else {
            notice = "This device is not paired with a server."
            return
        }
        isBusy = true
        defer { isBusy = false }
        deactivate()
        do {
            try await client.unregister()
            let server = pairing?.serverName ?? "the server"
            forgetLocally(silently: true)
            notice = "This device was removed from \(server). Its key was deleted; pairing again creates a new one."
        } catch let error as DeviceLinkError {
            notice = "The server did not confirm the removal: \(error.description) You can still forget the pairing on this device."
            resetToResting()
            startSyncIfNeeded()
        } catch {
            notice = "The server did not confirm the removal: \(error.localizedDescription)"
        }
    }

    /// Forgets the pairing and the installation key on this device only. The server keeps
    /// listing this installation until its owner revokes it.
    public func forgetLocally() {
        forgetLocally(silently: false)
    }

    private func forgetLocally(silently: Bool) {
        deactivate()
        try? environment.pairingFile.save(nil)
        setEndNote(nil)
        InstallationIdentity.reset(store: environment.secrets)
        pairing = nil
        client = nil
        clearServerData()
        lastSync = nil
        machine = LinkConnectionMachine()
        loadIdentity()
        resetToResting()
        if !silently {
            notice = "The pairing was forgotten on this device and a new key will be used next time. Ask the server's owner to revoke the old entry."
        }
    }
}
