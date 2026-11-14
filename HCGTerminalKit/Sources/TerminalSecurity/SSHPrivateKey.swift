import Crypto
import Foundation

/// A private key HCG Terminal can sign in with: Ed25519 or ECDSA on P-256, P-384 or P-521.
/// These are the key types SwiftNIO SSH supports for client authentication; RSA is not.
///
/// Held as raw bytes so the value is `Sendable` everywhere. Stored only in the credential
/// store (Keychain on iOS), never in plain files.
public enum SSHPrivateKey: Sendable, Equatable {
    case ed25519(Data)
    case p256(Data)
    case p384(Data)
    case p521(Data)

    /// OpenSSH algorithm name, e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`.
    public var algorithm: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .p256: "ecdsa-sha2-nistp256"
        case .p384: "ecdsa-sha2-nistp384"
        case .p521: "ecdsa-sha2-nistp521"
        }
    }

    /// Short name for the interface: "Ed25519", "ECDSA P-256".
    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .p256: "ECDSA P-256"
        case .p384: "ECDSA P-384"
        case .p521: "ECDSA P-521"
        }
    }

    /// The raw private bytes, as stored.
    public var rawRepresentation: Data {
        switch self {
        case .ed25519(let raw), .p256(let raw), .p384(let raw), .p521(let raw): raw
        }
    }

    /// Rebuilds a key from what the credential store holds. `algorithm` is the record's.
    public init(algorithm: String, rawRepresentation raw: Data) throws {
        switch algorithm {
        case "ssh-ed25519": _ = try Curve25519.Signing.PrivateKey(rawRepresentation: raw); self = .ed25519(raw)
        case "ecdsa-sha2-nistp256": _ = try P256.Signing.PrivateKey(rawRepresentation: raw); self = .p256(raw)
        case "ecdsa-sha2-nistp384": _ = try P384.Signing.PrivateKey(rawRepresentation: raw); self = .p384(raw)
        case "ecdsa-sha2-nistp521": _ = try P521.Signing.PrivateKey(rawRepresentation: raw); self = .p521(raw)
        default: throw SSHKeyError.corruptPrivateKey
        }
    }

    /// The public key in SSH wire format (the blob inside an `authorized_keys` line).
    public func publicKeyBlob() throws -> [UInt8] {
        switch self {
        case .ed25519(let raw):
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return SSHWire.string("ssh-ed25519") + SSHWire.string(key.publicKey.rawRepresentation)
        case .p256(let raw):
            let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
            return SSHWire.string(algorithm) + SSHWire.string("nistp256") + SSHWire.string(key.publicKey.x963Representation)
        case .p384(let raw):
            let key = try P384.Signing.PrivateKey(rawRepresentation: raw)
            return SSHWire.string(algorithm) + SSHWire.string("nistp384") + SSHWire.string(key.publicKey.x963Representation)
        case .p521(let raw):
            let key = try P521.Signing.PrivateKey(rawRepresentation: raw)
            return SSHWire.string(algorithm) + SSHWire.string("nistp521") + SSHWire.string(key.publicKey.x963Representation)
        }
    }

    /// `authorized_keys` line, e.g. `ssh-ed25519 AAAA… comment`.
    public func publicKeyLine(comment: String) throws -> String {
        let line = "\(algorithm) \(Data(try publicKeyBlob()).base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// OpenSSH `SHA256:` fingerprint of the public key.
    public func fingerprint() throws -> String {
        SSHWire.fingerprint(ofKeyBlob: try publicKeyBlob())
    }
}
