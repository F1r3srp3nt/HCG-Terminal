import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct LinkHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data
}

public struct LinkHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Carries signed requests to HCG Server.
public protocol LinkTransport: Sendable {
    func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse
}

public enum TransportFailure: Error, Equatable, CustomStringConvertible {
    /// The server presented a different key than the one pinned at pairing.
    case pinMismatch
    case unreachable(String)

    public var description: String {
        switch self {
        case .pinMismatch:
            return "The server presented a different key than the one recorded when you paired. Nothing was sent. If HCG Server was reinstalled, pair again with a new invitation."
        case .unreachable(let why):
            return "HCG Server could not be reached (\(why))."
        }
    }
}

/// Extracts the DER SubjectPublicKeyInfo from a DER X.509 certificate.
public enum CertificateSPKI {
    private struct TLV {
        let tag: UInt8
        let start: Int // index of the tag byte
        let contentStart: Int
        let end: Int // one past the last content byte
    }

    private static func read(_ b: [UInt8], at i: Int) -> TLV? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var len = Int(b[i + 1])
        var p = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n >= 1, n <= 4, p + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = (len << 8) | Int(b[p + k]) }
            p += n
        }
        guard p + len <= b.count else { return nil }
        return TLV(tag: tag, start: i, contentStart: p, end: p + len)
    }

    /// Returns nil when the data is not a certificate this parser understands.
    public static func extract(fromCertificateDER der: Data) -> Data? {
        let b = [UInt8](der)
        guard let cert = read(b, at: 0), cert.tag == 0x30,
              let tbs = read(b, at: cert.contentStart), tbs.tag == 0x30 else { return nil }
        var i = tbs.contentStart
        var fields: [TLV] = []
        while i < tbs.end, let f = read(b, at: i) {
            fields.append(f)
            i = f.end
        }
        // [0] version is optional; then serial, signature, issuer, validity, subject, SPKI.
        let offset = (fields.first?.tag == 0xA0) ? 1 : 0
        let idx = offset + 5
        guard fields.count > idx, fields[idx].tag == 0x30 else { return nil }
        return Data(b[fields[idx].start..<fields[idx].end])
    }
}

#if canImport(Security) && canImport(Darwin)
/// URLSession transport that trusts exactly one server key: the SHA-256 of
/// the leaf certificate's SPKI must equal the fingerprint from the invitation.
/// No certificate authority or host name is consulted.
public final class PinnedSessionTransport: NSObject, LinkTransport, URLSessionDelegate, @unchecked Sendable {
    public let fingerprint: String
    private var session: URLSession!
    private let lock = NSLock()
    private var lastPinFailure = false

    public init(fingerprint: String, timeout: TimeInterval = 15) {
        self.fingerprint = fingerprint.lowercased()
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Device Link never presents a client certificate.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var leaf: SecCertificate?
        if #available(iOS 15.0, macOS 12.0, *) {
            leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            leaf = SecTrustGetCertificateAtIndex(trust, 0)
        }
        guard let cert = leaf,
              let spki = CertificateSPKI.extract(fromCertificateDER: SecCertificateCopyData(cert) as Data),
              LinkCrypto.fingerprint(spki: spki) == fingerprint else {
            lock.lock(); lastPinFailure = true; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    public func send(_ request: LinkHTTPRequest) async throws -> LinkHTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        if !request.body.isEmpty { r.httpBody = request.body }
        lock.lock(); lastPinFailure = false; lock.unlock()
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: r) { [weak self] data, response, error in
                if let error = error {
                    let pin: Bool = self.map { (s: PinnedSessionTransport) -> Bool in s.lock.lock(); defer { s.lock.unlock() }; return s.lastPinFailure } ?? false
                    cont.resume(throwing: pin ? TransportFailure.pinMismatch : TransportFailure.unreachable(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: TransportFailure.unreachable("no HTTP response"))
                    return
                }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
                cont.resume(returning: LinkHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }.resume()
        }
    }
}
#endif
