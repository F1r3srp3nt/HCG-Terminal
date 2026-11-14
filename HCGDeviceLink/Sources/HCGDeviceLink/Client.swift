import Foundation

/// Supplies the signed-in person's HCG Connect access token.
public protocol AccessTokenProvider: Sendable {
    /// A current access token. `forceRefresh` after the server answered `token_expired`.
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// Why a Device Link operation failed, in terms the app can act on.
public enum DeviceLinkError: Error, Equatable, CustomStringConvertible {
    case server(status: Int, body: LinkErrorBody)
    case transport(TransportFailure)
    case notSignedIn(String)
    case invalidResponse(String)
    case invalidRequest(String)

    public var code: String {
        switch self {
        case .server(_, let b): return b.code
        case .transport(.pinMismatch): return "pin_mismatch"
        case .transport: return "unreachable"
        case .notSignedIn: return "not_signed_in"
        case .invalidResponse: return "invalid_response"
        case .invalidRequest: return "invalid_request"
        }
    }

    /// Worth retrying automatically with back-off.
    public var isRetryable: Bool {
        switch self {
        case .server(let status, let b): return b.retryable ?? (status >= 500 && status != 501)
        case .transport(.unreachable): return true
        default: return false
        }
    }

    public var retryAfter: TimeInterval? {
        if case .server(_, let b) = self, let s = b.retryAfterSeconds { return TimeInterval(s) }
        return nil
    }

    /// The installation must stop syncing and show this state (never retried automatically).
    public var endsLink: Bool {
        ["device_revoked", "unknown_installation", "wrong_account", "app_mismatch", "untrusted_client", "pin_mismatch",
         "access_revoked", "hcg_session_ended"].contains(code)
    }

    public var description: String {
        switch self {
        case .server(_, let b): return b.error
        case .transport(let t): return t.description
        case .notSignedIn(let why): return why
        case .invalidResponse(let why): return "HCG Server sent an unexpected answer (\(why))."
        case .invalidRequest(let why): return why
        }
    }
}

/// Where and as whom this installation talks.
public struct DeviceLinkConfiguration: Sendable {
    public var baseURL: URL
    public var serverFingerprint: String
    public var installationId: String
    public var organisation: String?

    public init(baseURL: URL, serverFingerprint: String, installationId: String, organisation: String? = nil) {
        self.baseURL = baseURL
        self.serverFingerprint = serverFingerprint.lowercased()
        self.installationId = installationId.lowercased()
        self.organisation = organisation
    }
}

/// One installation's Device Link client. Every request is signed with the
/// installation key and carries the person's HCG Connect token; HCG Server
/// authorizes it with ERP App Access. Nothing here enables local privileges.
public actor DeviceLinkClient {
    public let configuration: DeviceLinkConfiguration
    private let signer: LinkSigner
    private let transport: LinkTransport
    private let tokens: AccessTokenProvider
    private let now: @Sendable () -> Date
    private var clockOffset: TimeInterval = 0
    /// Sends not yet confirmed by the server, kept byte-identical so a resend
    /// is de-duplicated by message ID.
    private var pendingSends: [String: Data] = [:]

    public init(configuration: DeviceLinkConfiguration, signer: LinkSigner, transport: LinkTransport, tokens: AccessTokenProvider,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.signer = signer
        self.transport = transport
        self.tokens = tokens
        self.now = now
    }

    // MARK: request core

    private func signedRequest(method: String, path: String, body: Data, token: String) throws -> LinkHTTPRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw DeviceLinkError.invalidRequest("bad path \(path)")
        }
        let ts = String(Int64((now().timeIntervalSince1970 + clockOffset).rounded(.down)))
        let nonce = LinkCrypto.nonce()
        let canonical = CanonicalRequest(method: method, escapedPath: url.path, rawQuery: url.query ?? "",
                                         installationId: configuration.installationId, timestamp: ts, nonce: nonce,
                                         organisation: configuration.organisation ?? "", accessToken: token, body: body)
        let sig = try signer.sign(Data(canonical.string.utf8))
        var headers: [String: String] = [
            DeviceLinkProtocol.Header.protocolVersion: String(DeviceLinkProtocol.version),
            DeviceLinkProtocol.Header.installation: configuration.installationId,
            DeviceLinkProtocol.Header.timestamp: ts,
            DeviceLinkProtocol.Header.nonce: nonce,
            DeviceLinkProtocol.Header.signature: LinkCrypto.base64URL(sig),
            "Accept": "application/json",
        ]
        if let org = configuration.organisation, !org.isEmpty { headers[DeviceLinkProtocol.Header.organisation] = org }
        if !token.isEmpty { headers["Authorization"] = "Bearer " + token }
        if !body.isEmpty { headers["Content-Type"] = "application/json" }
        return LinkHTTPRequest(url: url, method: method, headers: headers, body: body)
    }

    private static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    /// Sends one signed request. Refreshes the token once on `token_expired`
    /// and corrects the clock once on `stale_request`.
    public func raw(_ method: String, _ path: String, body: Data = Data(), signedIn: Bool = true) async throws -> Data {
        var refreshed = false
        var skewFixed = false
        while true {
            var token = ""
            if signedIn {
                do { token = try await tokens.accessToken(forceRefresh: refreshed) } catch {
                    throw DeviceLinkError.notSignedIn("Sign in to HCG Connect to use connected devices.")
                }
            }
            let req = try signedRequest(method: method, path: path, body: body, token: token)
            let resp: LinkHTTPResponse
            do { resp = try await transport.send(req) } catch let t as TransportFailure {
                throw DeviceLinkError.transport(t)
            } catch {
                throw DeviceLinkError.transport(.unreachable(error.localizedDescription))
            }
            if (200..<300).contains(resp.status) { return resp.body }
            guard let body = try? LinkJSON.decoder().decode(LinkErrorBody.self, from: resp.body) else {
                throw DeviceLinkError.server(status: resp.status, body: LinkErrorBody(error: "HTTP \(resp.status)", code: "http_\(resp.status)",
                                                                                    retryable: resp.status >= 500))
            }
            if body.code == "token_expired", signedIn, !refreshed {
                refreshed = true
                continue
            }
            if body.code == "stale_request", !skewFixed, let d = resp.header("Date").flatMap(Self.httpDate) {
                skewFixed = true
                clockOffset = d.timeIntervalSince(now())
                continue
            }
            throw DeviceLinkError.server(status: resp.status, body: body)
        }
    }

    private func call<T: Decodable>(_ method: String, _ path: String, _ body: Encodable? = nil, as: T.Type = T.self, signedIn: Bool = true) async throws -> T {
        let data = try body.map { try LinkJSON.encoder().encode(AnyEncodable($0)) } ?? Data()
        let out = try await raw(method, path, body: data, signedIn: signedIn)
        do { return try LinkJSON.decoder().decode(T.self, from: out) } catch {
            throw DeviceLinkError.invalidResponse(String(describing: error))
        }
    }

    // MARK: operations

    private var p: String { DeviceLinkProtocol.prefix }

    public func pair(invitation: Invitation, info: LinkInstallationInfo) async throws -> LinkPairStatus {
        guard invitation.fingerprint == configuration.serverFingerprint else {
            throw DeviceLinkError.invalidRequest("The invitation is for another server.")
        }
        return try await call("POST", p + "/pair", LinkPairRequest(invitationId: invitation.invitationId, secret: invitation.secret, installation: info))
    }

    public func pairingStatus(requestId: String) async throws -> LinkPairStatus {
        try await call("GET", p + "/pair/" + requestId)
    }

    public func devices() async throws -> LinkDevices { try await call("GET", p + "/devices") }

    public func heartbeat(capabilities: [LinkCapability]?) async throws -> LinkHeartbeatResult {
        try await call("POST", p + "/heartbeat", LinkHeartbeat(capabilities: capabilities))
    }

    public func inbox() async throws -> [LinkMessageHeader] { try await call("GET", p + "/inbox", as: LinkMessageList.self).messages }

    public func outbox() async throws -> [LinkMessageHeader] { try await call("GET", p + "/outbox", as: LinkMessageList.self).messages }

    /// Fetches a shared report. The report is returned as data; callers render it as plain text only.
    public func open(messageId: String) async throws -> (header: LinkMessageHeader, report: DiagnosticReport) {
        let data = try await raw("GET", p + "/messages/" + messageId)
        struct Envelope: Decodable {
            let messageId, type, title, status: String
            let from, to: LinkParty
            let createdAt, queuedAt, expiresAt: Date
            let size: Int
            let deliveredAt, openedAt: Date?
            let report: DiagnosticReport
        }
        do {
            let e = try LinkJSON.decoder().decode(Envelope.self, from: data)
            let h = LinkMessageHeader(messageId: e.messageId, type: e.type, from: e.from, to: e.to, title: e.title, createdAt: e.createdAt,
                                      queuedAt: e.queuedAt, expiresAt: e.expiresAt, status: e.status, size: e.size,
                                      deliveredAt: e.deliveredAt, openedAt: e.openedAt)
            return (h, e.report)
        } catch {
            throw DeviceLinkError.invalidResponse("the shared report is not a valid \(DeviceLinkProtocol.reportSchema) document")
        }
    }

    @discardableResult
    public func acknowledge(messageId: String, opened: Bool) async throws -> LinkMessageHeader {
        try await call("POST", p + "/messages/" + messageId + "/ack", LinkAck(state: opened ? "opened" : "received"))
    }

    public func approvals() async throws -> LinkApprovals { try await call("GET", p + "/approvals") }

    /// Removes this installation from the server. Needs only the installation key.
    public func unregister() async throws {
        _ = try await raw("POST", p + "/unregister", signedIn: false)
    }

    /// Shares a redacted report with one paired installation. The message ID is
    /// kept until the server confirms, so `resendPending()` after a reconnect
    /// cannot create a duplicate.
    public func share(_ report: DiagnosticReport, to recipient: String, lifetime: TimeInterval = 7 * 24 * 3600,
                      messageId: String = LinkCrypto.uuid()) async throws -> LinkSendReceipt {
        let reportData = try report.encoded()
        let problems = ReportValidator.problems(report, encoded: reportData)
        guard problems.isEmpty else { throw DeviceLinkError.invalidRequest("This report was not shared: " + problems.joined(separator: "; ") + ".") }
        let created = Date(timeIntervalSince1970: (now().timeIntervalSince1970 + clockOffset).rounded(.down))
        struct Send: Encodable {
            let messageId, type, to: String
            let createdAt, expiresAt: Date
            let report: DiagnosticReport
        }
        let body = try LinkJSON.encoder().encode(Send(messageId: messageId, type: "report.share", to: recipient.lowercased(), createdAt: created,
                                                       expiresAt: created.addingTimeInterval(min(lifetime, DeviceLinkProtocol.maxMessageLifetime)),
                                                       report: report))
        pendingSends[messageId] = body
        return try await deliver(messageId: messageId, body: body)
    }

    private func deliver(messageId: String, body: Data) async throws -> LinkSendReceipt {
        do {
            let data = try await raw("POST", p + "/messages", body: body)
            pendingSends[messageId] = nil
            return try LinkJSON.decoder().decode(LinkSendReceipt.self, from: data)
        } catch let e as DeviceLinkError where e.isRetryable {
            throw e // kept for resendPending()
        } catch {
            pendingSends[messageId] = nil
            throw error
        }
    }

    /// Message IDs of shares waiting for a reconnect.
    public var pendingMessageIds: [String] { Array(pendingSends.keys).sorted() }

    /// Resends unconfirmed shares with their original message IDs and bytes.
    /// Never used for action requests: those are not queued or replayed.
    public func resendPending() async -> [String: Result<LinkSendReceipt, DeviceLinkError>] {
        var out: [String: Result<LinkSendReceipt, DeviceLinkError>] = [:]
        for (id, body) in pendingSends {
            do { out[id] = .success(try await deliver(messageId: id, body: body)) } catch let e as DeviceLinkError {
                out[id] = .failure(e)
            } catch {
                out[id] = .failure(.invalidResponse(String(describing: error)))
            }
        }
        return out
    }
}

/// Exponential back-off with jitter for reconnects (1, 2, 4 … 60 s, ±20 %).
public struct ReconnectPolicy: Sendable {
    public var base: TimeInterval = 1
    public var maximum: TimeInterval = 60
    public var jitter: Double = 0.2

    public init() {}

    public func delay(afterFailures n: Int, retryAfter: TimeInterval? = nil, random: Double = Double.random(in: -1...1)) -> TimeInterval {
        let exp = min(maximum, base * pow(2, Double(max(0, n - 1))))
        let d = max(0.1, exp * (1 + jitter * random))
        return max(d, retryAfter ?? 0)
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
