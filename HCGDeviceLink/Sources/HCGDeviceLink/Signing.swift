import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The exact inputs an installation signs (docs/DEVICE-LINK.md "Request signing").
public struct CanonicalRequest: Sendable, Equatable {
    public var method: String
    public var escapedPath: String
    public var rawQuery: String
    public var installationId: String
    public var timestamp: String
    public var nonce: String
    public var organisation: String
    public var accessToken: String
    public var body: Data

    public init(method: String, escapedPath: String, rawQuery: String = "", installationId: String, timestamp: String, nonce: String,
                organisation: String = "", accessToken: String, body: Data) {
        self.method = method
        self.escapedPath = escapedPath
        self.rawQuery = rawQuery
        self.installationId = installationId
        self.timestamp = timestamp
        self.nonce = nonce
        self.organisation = organisation
        self.accessToken = accessToken
        self.body = body
    }

    /// The ten-line canonical string.
    public var string: String {
        [
            DeviceLinkProtocol.name,
            method.uppercased(),
            escapedPath,
            rawQuery,
            installationId,
            timestamp,
            nonce,
            organisation,
            LinkCrypto.sha256Hex(Data(accessToken.utf8)),
            LinkCrypto.sha256Hex(body),
        ].joined(separator: "\n")
    }
}

public enum LinkCrypto {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex SHA-256 of a DER SubjectPublicKeyInfo (HCG Server's fingerprint rule).
    public static func fingerprint(spki: Data) -> String { sha256Hex(spki) }

    /// Fingerprint for people: 16 groups of 4 upper-case hex digits.
    public static func displayFingerprint(_ fp: String) -> String {
        let up = fp.uppercased()
        var groups: [String] = []
        var i = up.startIndex
        while i < up.endIndex {
            let j = up.index(i, offsetBy: 4, limitedBy: up.endIndex) ?? up.endIndex
            groups.append(String(up[i..<j]))
            i = j
        }
        return groups.joined(separator: " ")
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Random bytes from the system generator.
    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    public static func nonce() -> String { base64URL(randomBytes(18)) }

    /// A random RFC 4122 version-4 UUID, lowercase.
    public static func uuid() -> String { UUID().uuidString.lowercased() }

    /// Verifies a DER ECDSA P-256 signature (used by tests and cross-language vectors).
    public static func verify(spki: Data, signatureDER: Data, message: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: spki),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signatureDER) else { return false }
        return key.isValidSignature(sig, for: message)
    }
}

/// An installation key. Implementations: software P-256 (all platforms) and
/// Secure Enclave P-256 (Apple devices that have one).
public protocol LinkSigner: Sendable {
    /// DER SubjectPublicKeyInfo of the public key.
    var publicKeySPKI: Data { get }
    /// DER ECDSA P-256 / SHA-256 signature of message.
    func sign(_ message: Data) throws -> Data
}

public extension LinkSigner {
    var publicKeyBase64: String { publicKeySPKI.base64EncodedString() }
    var fingerprint: String { LinkCrypto.fingerprint(spki: publicKeySPKI) }
}

/// A software P-256 key. Persist `rawRepresentation` only in the Keychain.
public struct SoftwareSigner: LinkSigner, @unchecked Sendable {
    private let key: P256.Signing.PrivateKey

    public init() { key = P256.Signing.PrivateKey() }
    public init(rawRepresentation: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) }

    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKeySPKI: Data { key.publicKey.derRepresentation }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}

#if canImport(CryptoKit) && !os(macOS)
/// A Secure Enclave P-256 key: the private key never leaves the device's
/// enclave. `dataRepresentation` is an opaque, enclave-bound handle that is
/// stored in the Keychain.
@available(iOS 13.0, *)
public struct SecureEnclaveSigner: LinkSigner, @unchecked Sendable {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init() throws { key = try SecureEnclave.P256.Signing.PrivateKey() }
    public init(dataRepresentation: Data) throws { key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation) }

    public var dataRepresentation: Data { key.dataRepresentation }
    public var publicKeySPKI: Data { key.publicKey.derRepresentation }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}
#endif
