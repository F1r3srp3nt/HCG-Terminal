import Crypto
import Foundation

/// SSH wire-format helpers (RFC 4251 strings).
public enum SSHWire {
    public static func string(_ bytes: some Collection<UInt8>) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + Array(bytes)
    }

    public static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    /// OpenSSH-style fingerprint: `SHA256:` + unpadded base64 of SHA-256 over the key blob.
    public static func fingerprint(ofKeyBlob blob: some DataProtocol) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    /// Parses an OpenSSH public key line (`type base64 [comment]`) into type and blob.
    public static func parsePublicKeyLine(_ line: String) -> (type: String, blob: Data)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return (String(parts[0]), blob)
    }
}

/// Metadata for a key made on the device or imported. The private key itself lives only in
/// the credential store (Keychain on iOS).
public struct SSHKeyRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var comment: String
    /// OpenSSH algorithm name (`ssh-ed25519`, `ecdsa-sha2-nistp256`, …).
    public var algorithm: String
    /// OpenSSH `authorized_keys` line.
    public var publicKeyLine: String
    public var fingerprint: String
    public var createdAt: Date
    /// True for keys imported from a file; `nil`/false for keys made on this device.
    public var imported: Bool? = nil

    public var isImported: Bool { imported == true }

    /// "Ed25519", "ECDSA P-256", …
    public var algorithmDisplayName: String {
        switch algorithm {
        case "ssh-ed25519": "Ed25519"
        case "ecdsa-sha2-nistp256": "ECDSA P-256"
        case "ecdsa-sha2-nistp384": "ECDSA P-384"
        case "ecdsa-sha2-nistp521": "ECDSA P-521"
        default: algorithm
        }
    }
}

public enum SSHKeyError: Error, LocalizedError {
    case missingPrivateKey(UUID)
    case corruptPrivateKey

    public var errorDescription: String? {
        switch self {
        case .missingPrivateKey: "The private key is missing from secure storage."
        case .corruptPrivateKey: "The stored private key could not be read."
        }
    }
}

/// Generates, imports and stores SSH keys.
public struct SSHKeyManager: Sendable {
    private let credentials: any CredentialStore
    private let metadataURL: URL

    public init(credentials: any CredentialStore, metadataURL: URL) {
        self.credentials = credentials
        self.metadataURL = metadataURL
    }

    public func generateEd25519(comment: String) throws -> SSHKeyRecord {
        let key = Curve25519.Signing.PrivateKey()
        let record = Self.record(for: key.publicKey, id: UUID(), comment: comment)
        try credentials.save(key.rawRepresentation, for: .privateKey(record.id))
        var all = list()
        all.append(record)
        try persist(all)
        return record
    }

    public func list() -> [SSHKeyRecord] {
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        return (try? JSONDecoder().decode([SSHKeyRecord].self, from: data)) ?? []
    }

    /// The private key for a stored record (any supported algorithm).
    public func privateKey(for id: UUID) throws -> SSHPrivateKey {
        guard let raw = try credentials.load(.privateKey(id)) else { throw SSHKeyError.missingPrivateKey(id) }
        // Records written before imports existed are Ed25519.
        let algorithm = list().first { $0.id == id }?.algorithm ?? "ssh-ed25519"
        do { return try SSHPrivateKey(algorithm: algorithm, rawRepresentation: raw) } catch { throw SSHKeyError.corruptPrivateKey }
    }

    /// Stores an imported key under `comment` (the file's comment, or one the user chose).
    /// Refuses a key that is already stored (same fingerprint). The passphrase that protected the
    /// file is not kept: the decrypted key is held in secure storage like a generated key.
    @discardableResult
    public func importKey(_ imported: ImportedSSHKey, comment: String) throws -> SSHKeyRecord {
        let fingerprint = try imported.key.fingerprint()
        if list().contains(where: { $0.fingerprint == fingerprint }) {
            throw SSHKeyImportError.alreadyImported(fingerprint: fingerprint)
        }
        let record = SSHKeyRecord(
            id: UUID(), comment: comment, algorithm: imported.key.algorithm,
            publicKeyLine: try imported.key.publicKeyLine(comment: comment), fingerprint: fingerprint,
            createdAt: Date(), imported: true
        )
        try credentials.save(imported.key.rawRepresentation, for: .privateKey(record.id))
        var all = list()
        all.append(record)
        try persist(all)
        return record
    }

    public func delete(_ id: UUID) throws {
        try credentials.delete(.privateKey(id))
        try persist(list().filter { $0.id != id })
    }

    public static func record(for publicKey: Curve25519.Signing.PublicKey, id: UUID, comment: String) -> SSHKeyRecord {
        let blob = SSHWire.string("ssh-ed25519") + SSHWire.string(publicKey.rawRepresentation)
        let line = "ssh-ed25519 \(Data(blob).base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)")
        return SSHKeyRecord(
            id: id, comment: comment, algorithm: "ssh-ed25519", publicKeyLine: line,
            fingerprint: SSHWire.fingerprint(ofKeyBlob: blob), createdAt: Date()
        )
    }

    private func persist(_ records: [SSHKeyRecord]) throws {
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: metadataURL, options: [.atomic])
    }
}
