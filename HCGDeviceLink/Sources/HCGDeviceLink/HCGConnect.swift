import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// HCG Connect sign-in for an HCG app: OAuth 2.1 authorization code with
/// PKCE (S256), public client, no secret. Endpoints default to the values HCG
/// Executable Maker verified against HCG's live identity server. The client ID
/// and redirect URI must be issued by HCG for each app; until they are, the
/// configuration is "not configured" and nothing is contacted.
public struct HCGConnectConfiguration: Codable, Sendable, Equatable {
    public static let defaultIssuer = "https://qggdyzoydveafkmjgkpq.supabase.co/auth/v1"

    public var contractVersion: String
    public var clientId: String?
    public var redirectUri: String?
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var scopes: [String]

    public init(contractVersion: String, clientId: String?, redirectUri: String?, issuer: String = defaultIssuer,
                authorizationEndpoint: String? = nil, tokenEndpoint: String? = nil, scopes: [String] = ["openid", "email", "profile"]) {
        self.contractVersion = contractVersion
        self.clientId = clientId
        self.redirectUri = redirectUri
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint ?? issuer + "/oauth/authorize"
        self.tokenEndpoint = tokenEndpoint ?? issuer + "/oauth/token"
        self.scopes = scopes
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion, clientId, redirectUri, issuer, authorizationEndpoint, tokenEndpoint, scopes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? Self.defaultIssuer
        self.init(contractVersion: try c.decode(String.self, forKey: .contractVersion),
                  clientId: try c.decodeIfPresent(String.self, forKey: .clientId),
                  redirectUri: try c.decodeIfPresent(String.self, forKey: .redirectUri), issuer: issuer,
                  authorizationEndpoint: try c.decodeIfPresent(String.self, forKey: .authorizationEndpoint),
                  tokenEndpoint: try c.decodeIfPresent(String.self, forKey: .tokenEndpoint),
                  scopes: try c.decodeIfPresent([String].self, forKey: .scopes) ?? ["openid", "email", "profile"])
    }

    /// Why sign-in is unavailable (nil = ready).
    public func problem(expectedContract: String) -> String? {
        guard contractVersion == expectedContract else { return "The HCG Connect configuration is for \(contractVersion), not \(expectedContract)." }
        guard let id = clientId, UUID(uuidString: id) != nil, id != "00000000-0000-0000-0000-000000000000" else {
            return "HCG has not issued an HCG Connect client for this app yet, so sign-in is not configured. Nothing is contacted."
        }
        guard let r = redirectUri, let u = URL(string: r), u.scheme != nil else {
            return "No HCG Connect redirect URI has been issued for this app yet."
        }
        for e in [issuer, authorizationEndpoint, tokenEndpoint] {
            guard let u = URL(string: e), u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost"].contains(u.host ?? "")) else {
                return "HCG Connect endpoints must use https."
            }
        }
        guard scopes.contains("openid") else { return "The openid scope is required." }
        return nil
    }

    /// Reads a configuration file; refuses files that contain anything secret-looking.
    public static func load(_ data: Data) throws -> HCGConnectConfiguration {
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let allowed = Set(Self.keyNames + ["$schema"])
            for k in obj.keys {
                let l = k.lowercased()
                if ["secret", "password", "private", "service_role", "apikey", "api_key"].contains(where: l.contains) {
                    throw HCGConnectError.configuration("The HCG Connect file must not contain secrets (\(k)); public clients have none.")
                }
                if !allowed.contains(k) { throw HCGConnectError.configuration("Unknown key \(k) in the HCG Connect file.") }
            }
        }
        return try JSONDecoder().decode(HCGConnectConfiguration.self, from: data)
    }
}

extension HCGConnectConfiguration {
    static let keyNames = ["contractVersion", "clientId", "redirectUri", "issuer", "authorizationEndpoint", "tokenEndpoint", "scopes"]
}

public enum HCGConnectError: Error, Equatable, CustomStringConvertible {
    case notConfigured(String)
    case configuration(String)
    case cancelled
    case mismatch(String)
    case rejected(String)
    case sessionEnded
    case unavailable(String)

    public var description: String {
        switch self {
        case .notConfigured(let s), .configuration(let s): return s
        case .cancelled: return "Sign-in was cancelled."
        case .mismatch(let s): return "The sign-in response did not match this request (\(s)). Nothing was stored; try again."
        case .rejected(let s): return "HCG Connect refused the sign-in: \(s)"
        case .sessionEnded: return "Your HCG Connect session has ended. Sign in again."
        case .unavailable(let s): return "HCG Connect could not be reached (\(s))."
        }
    }
}

/// PKCE (RFC 7636, S256).
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init() { self.init(verifier: LinkCrypto.base64URL(LinkCrypto.randomBytes(32))) }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = LinkCrypto.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// One sign-in attempt: open `url` in the system browser
/// (ASWebAuthenticationSession), then pass the callback URL to `HCGConnectAuth.complete`.
public struct SignInAttempt: Sendable, Equatable {
    public let url: URL
    public let state: String
    public let nonce: String
    public let pkce: PKCE
    public let redirectUri: String
}

/// Tokens from HCG Connect. Store only in the Keychain.
public struct HCGConnectTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var subject: String
    public var email: String?
    public var clientId: String
}

/// Builds and finishes HCG Connect sign-ins.
public struct HCGConnectAuth: Sendable {
    public let configuration: HCGConnectConfiguration
    public let expectedContract: String
    private let send: @Sendable (URLRequest) async throws -> (Data, Int)

    public init(configuration: HCGConnectConfiguration, expectedContract: String,
                send: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil) {
        self.configuration = configuration
        self.expectedContract = expectedContract
        self.send = send ?? { req in
            try await withCheckedThrowingContinuation { cont in
                URLSession(configuration: .ephemeral).dataTask(with: req) { data, resp, err in
                    if let err = err { cont.resume(throwing: HCGConnectError.unavailable(err.localizedDescription)); return }
                    cont.resume(returning: (data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
                }.resume()
            }
        }
    }

    public func begin() throws -> SignInAttempt {
        if let p = configuration.problem(expectedContract: expectedContract) { throw HCGConnectError.notConfigured(p) }
        let pkce = PKCE()
        let state = LinkCrypto.base64URL(LinkCrypto.randomBytes(24))
        let nonce = LinkCrypto.base64URL(LinkCrypto.randomBytes(24))
        var c = URLComponents(string: configuration.authorizationEndpoint)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientId!),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectUri!),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return SignInAttempt(url: c.url!, state: state, nonce: nonce, pkce: pkce, redirectUri: configuration.redirectUri!)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Decodes JWT claims WITHOUT verifying the signature. Used only to bind a
    /// response to this attempt (nonce, audience, client); HCG Server verifies
    /// access tokens cryptographically before trusting them.
    public static func peekClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let d = LinkCrypto.base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    public func complete(_ attempt: SignInAttempt, callback: URL, now: Date = Date()) async throws -> HCGConnectTokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard Self.constantTimeEqual(q("state") ?? "", attempt.state) else { throw HCGConnectError.mismatch("state") }
        if let e = q("error") { throw HCGConnectError.rejected(q("error_description") ?? e) }
        guard let code = q("code"), !code.isEmpty else { throw HCGConnectError.mismatch("no authorization code") }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": attempt.redirectUri,
            "client_id": configuration.clientId!, "code_verifier": attempt.pkce.verifier,
        ], now: now)
        guard let idToken = tokens.idToken, let id = Self.peekClaims(idToken) else { throw HCGConnectError.mismatch("no ID token") }
        guard (id["nonce"] as? String) == attempt.nonce else { throw HCGConnectError.mismatch("nonce") }
        let aud = (id["aud"] as? String).map { [$0] } ?? (id["aud"] as? [String]) ?? []
        guard aud.contains(configuration.clientId!), (id["iss"] as? String) == configuration.issuer else { throw HCGConnectError.mismatch("ID token audience or issuer") }
        return try tokens.result(clientId: configuration.clientId!, now: now)
    }

    public func refresh(_ t: HCGConnectTokens, now: Date = Date()) async throws -> HCGConnectTokens {
        let r = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refreshToken, "client_id": t.clientId], now: now)
        return try r.result(clientId: t.clientId, now: now, fallbackRefresh: t.refreshToken)
    }

    struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
        let error: String?
        let error_description: String?
        var idToken: String? { id_token }

        func result(clientId: String, now: Date, fallbackRefresh: String? = nil) throws -> HCGConnectTokens {
            guard let at = access_token, let c = HCGConnectAuth.peekClaims(at), let sub = c["sub"] as? String else {
                throw HCGConnectError.mismatch("no access token")
            }
            guard (c["client_id"] as? String) == clientId else { throw HCGConnectError.mismatch("token issued to another client") }
            guard let rt = refresh_token ?? fallbackRefresh else { throw HCGConnectError.mismatch("no refresh token") }
            return HCGConnectTokens(accessToken: at, refreshToken: rt, expiresAt: now.addingTimeInterval(expires_in ?? 3600), subject: sub,
                                    email: c["email"] as? String, clientId: clientId)
        }
    }

    private func tokenRequest(_ form: [String: String], now: Date) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: configuration.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (data, status) = try await send(req)
        let r = (try? JSONDecoder().decode(TokenResponse.self, from: data))
        if status == 400 || status == 401, let e = r?.error {
            if ["invalid_grant", "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired"].contains(e) {
                throw HCGConnectError.sessionEnded
            }
            throw HCGConnectError.rejected(r?.error_description ?? e)
        }
        guard status == 200, let ok = r else { throw HCGConnectError.unavailable("HTTP \(status)") }
        return ok
    }
}

/// Stores tokens; the app provides a Keychain-backed implementation.
public protocol HCGConnectTokenStore: Sendable {
    func load() -> HCGConnectTokens?
    func save(_ tokens: HCGConnectTokens?) throws
}

/// A signed-in session: refreshes before expiry, single-flight, and serves
/// as the Device Link `AccessTokenProvider`. Sign-out is local (HCG Connect has
/// no revocation endpoint); HCG Server stops accepting the session once HCG
/// reports it ended.
public actor HCGConnectSession: AccessTokenProvider {
    private let auth: HCGConnectAuth
    private let store: HCGConnectTokenStore
    private let now: @Sendable () -> Date
    private var tokens: HCGConnectTokens?
    private var refreshing: Task<HCGConnectTokens, Error>?

    public init(auth: HCGConnectAuth, store: HCGConnectTokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.auth = auth
        self.store = store
        self.now = now
        self.tokens = store.load()
    }

    public var current: HCGConnectTokens? { tokens }

    public func signedIn(_ t: HCGConnectTokens) throws {
        tokens = t
        try store.save(t)
    }

    public func signOut() {
        tokens = nil
        try? store.save(nil)
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        guard let t = tokens else { throw HCGConnectError.notConfigured("Not signed in to HCG Connect.") }
        if !forceRefresh, t.expiresAt.timeIntervalSince(now()) > 60 { return t.accessToken }
        if let task = refreshing { return try await task.value.accessToken }
        let task = Task { try await auth.refresh(t, now: now()) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            try? store.save(fresh)
            return fresh.accessToken
        } catch HCGConnectError.sessionEnded {
            signOut()
            throw HCGConnectError.sessionEnded
        }
    }
}
