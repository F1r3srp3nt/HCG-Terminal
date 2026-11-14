import Crypto
import Foundation

/// Why a private key could not be imported. Every message says what to do next.
public enum SSHKeyImportError: Error, LocalizedError, Equatable {
    case notAPrivateKey
    case publicKeyGiven
    case unsupportedKeyType(String)
    case passphraseRequired
    case wrongPassphrase
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case encryptedPEM
    case malformed(String)
    case alreadyImported(fingerprint: String)

    public var errorDescription: String? {
        switch self {
        case .notAPrivateKey:
            "This is not a private key. Choose the private key file (for example ~/.ssh/id_ed25519, without .pub)."
        case .publicKeyGiven:
            "This is a public key. Import the matching private key file instead (the same name without .pub)."
        case .unsupportedKeyType(let type):
            "\(type) keys are not supported for sign-in by HCG Terminal's SSH library. Use an Ed25519 or ECDSA key: create one in HCG Terminal, or run ssh-keygen -t ed25519 on your computer, and add its public key to the host."
        case .passphraseRequired:
            "This key is protected by a passphrase. Enter it to import the key."
        case .wrongPassphrase:
            "The passphrase is not correct for this key."
        case .unsupportedCipher(let cipher):
            "This key is encrypted with \(cipher), which HCG Terminal cannot read. Re-encrypt it with the current OpenSSH default: ssh-keygen -p -f <key>."
        case .unsupportedKDF(let kdf):
            "This key uses the key-derivation method \(kdf), which HCG Terminal cannot read. Re-encrypt it with: ssh-keygen -p -f <key>."
        case .encryptedPEM:
            "This key uses the older encrypted PEM format. Convert it to the OpenSSH format with: ssh-keygen -p -f <key> (keeps your passphrase), then import it again."
        case .malformed(let detail):
            "The key file is damaged or incomplete (\(detail))."
        case .alreadyImported(let fingerprint):
            "This key is already in HCG Terminal (\(fingerprint))."
        }
    }
}

/// A key read from a private key file.
public struct ImportedSSHKey: Sendable, Equatable {
    public var key: SSHPrivateKey
    /// The comment stored in the file (OpenSSH format only), often `user@host`.
    public var comment: String
    /// Whether the file was protected by a passphrase. The passphrase itself is never stored:
    /// the decrypted key goes to secure storage like a key made on the device.
    public var wasEncrypted: Bool
}

/// Reads private key files: OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`, unencrypted or
/// protected by a passphrase with bcrypt and AES-CTR/GCM) and PEM (SEC1 `EC PRIVATE KEY`, PKCS#8
/// `PRIVATE KEY`) for Ed25519 and ECDSA P-256/P-384/P-521. RSA and DSA keys are recognised and
/// refused with an explanation.
public enum OpenSSHKeyImport {
    /// Whether the file needs a passphrase (OpenSSH format with a cipher other than `none`).
    public static func needsPassphrase(_ text: String) -> Bool {
        guard let pem = PEMBlock(text), pem.label == "OPENSSH PRIVATE KEY", let bytes = pem.der else { return false }
        var reader = SSHReader(bytes)
        guard (try? reader.readMagic()) != nil, let cipher = try? reader.readStringUTF8() else { return false }
        return cipher != "none"
    }

    public static func parse(_ text: String, passphrase: String?) throws -> ImportedSSHKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["ssh-ed25519 ", "ssh-rsa ", "ssh-dss ", "ecdsa-sha2-", "sk-"].contains(where: { trimmed.hasPrefix($0) }) {
            throw SSHKeyImportError.publicKeyGiven
        }
        guard let pem = PEMBlock(trimmed) else { throw SSHKeyImportError.notAPrivateKey }
        switch pem.label {
        case "OPENSSH PRIVATE KEY":
            guard let der = pem.der else { throw SSHKeyImportError.malformed("not valid base64") }
            return try parseOpenSSH(der, passphrase: passphrase)
        case "EC PRIVATE KEY":
            if pem.encryptedHeader { throw SSHKeyImportError.encryptedPEM }
            guard let der = pem.der else { throw SSHKeyImportError.malformed("not valid base64") }
            return ImportedSSHKey(key: try ecdsaFromDER(der), comment: "", wasEncrypted: false)
        case "PRIVATE KEY":
            guard let der = pem.der else { throw SSHKeyImportError.malformed("not valid base64") }
            if let seed = ed25519SeedFromPKCS8(der) {
                _ = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                return ImportedSSHKey(key: .ed25519(Data(seed)), comment: "", wasEncrypted: false)
            }
            if der.containsSubsequence(rsaOID) { throw SSHKeyImportError.unsupportedKeyType("RSA") }
            return ImportedSSHKey(key: try ecdsaFromDER(der), comment: "", wasEncrypted: false)
        case "ENCRYPTED PRIVATE KEY":
            throw SSHKeyImportError.encryptedPEM
        case "RSA PRIVATE KEY":
            throw SSHKeyImportError.unsupportedKeyType("RSA")
        case "DSA PRIVATE KEY":
            throw SSHKeyImportError.unsupportedKeyType("DSA")
        default:
            throw SSHKeyImportError.notAPrivateKey
        }
    }

    // MARK: OpenSSH format

    private struct CipherSpec { let keyLength: Int; let ivLength: Int; let gcm: Bool }

    private static let ciphers: [String: CipherSpec] = [
        "aes128-ctr": CipherSpec(keyLength: 16, ivLength: 16, gcm: false),
        "aes192-ctr": CipherSpec(keyLength: 24, ivLength: 16, gcm: false),
        "aes256-ctr": CipherSpec(keyLength: 32, ivLength: 16, gcm: false),
        "aes128-gcm@openssh.com": CipherSpec(keyLength: 16, ivLength: 12, gcm: true),
        "aes256-gcm@openssh.com": CipherSpec(keyLength: 32, ivLength: 12, gcm: true),
    ]

    static func parseOpenSSH(_ bytes: [UInt8], passphrase: String?) throws -> ImportedSSHKey {
        var reader = SSHReader(bytes)
        try reader.readMagic()
        let cipherName = try reader.readStringUTF8()
        let kdfName = try reader.readStringUTF8()
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else { throw SSHKeyImportError.malformed("\(keyCount) keys in one file") }
        _ = try reader.readString() // public key (re-derived and checked below)
        var privateSection = try reader.readString()

        let encrypted = cipherName != "none"
        if encrypted {
            guard let spec = ciphers[cipherName] else { throw SSHKeyImportError.unsupportedCipher(cipherName) }
            guard kdfName == "bcrypt" else { throw SSHKeyImportError.unsupportedKDF(kdfName) }
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyImportError.passphraseRequired }
            var options = SSHReader(kdfOptions)
            let salt = try options.readString()
            let rounds = Int(try options.readUInt32())
            guard rounds >= 1, rounds <= 1 << 16 else { throw SSHKeyImportError.malformed("bcrypt rounds \(rounds)") }
            let material = BcryptPBKDF.derive(passphrase: Array(passphrase.utf8), salt: salt, rounds: rounds, length: spec.keyLength + spec.ivLength)
            let key = Array(material[0..<spec.keyLength])
            let iv = Array(material[spec.keyLength...])
            if spec.gcm {
                let tag = try reader.readBytes(16)
                do {
                    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: privateSection, tag: tag)
                    privateSection = Array(try AES.GCM.open(box, using: SymmetricKey(data: key)))
                } catch {
                    throw SSHKeyImportError.wrongPassphrase
                }
            } else {
                privateSection = try AESCTR.crypt(privateSection, key: key, iv: iv)
            }
        } else if kdfName != "none" {
            throw SSHKeyImportError.malformed("unencrypted key with kdf \(kdfName)")
        }

        var body = SSHReader(privateSection)
        let check1 = try body.readUInt32()
        let check2 = try body.readUInt32()
        guard check1 == check2 else {
            throw encrypted ? SSHKeyImportError.wrongPassphrase : SSHKeyImportError.malformed("check bytes differ")
        }
        let keyType = try body.readStringUTF8()
        let key: SSHPrivateKey
        switch keyType {
        case "ssh-ed25519":
            let publicKey = try body.readString()
            let secret = try body.readString()
            guard secret.count == 64, publicKey.count == 32 else { throw SSHKeyImportError.malformed("Ed25519 key length") }
            let seed = Array(secret[0..<32])
            let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard Array(derived.publicKey.rawRepresentation) == publicKey else { throw SSHKeyImportError.malformed("Ed25519 public key mismatch") }
            key = .ed25519(Data(seed))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try body.readStringUTF8() // curve name
            let q = try body.readString()
            let d = try body.readMPInt()
            key = try ecdsaKey(type: keyType, scalar: d, publicPoint: q)
        case "ssh-rsa":
            throw SSHKeyImportError.unsupportedKeyType("RSA")
        case "ssh-dss":
            throw SSHKeyImportError.unsupportedKeyType("DSA")
        default:
            if keyType.hasPrefix("sk-") { throw SSHKeyImportError.unsupportedKeyType("Security-key (FIDO)") }
            throw SSHKeyImportError.unsupportedKeyType(keyType)
        }
        let comment = (try? body.readStringUTF8()) ?? ""
        return ImportedSSHKey(key: key, comment: comment, wasEncrypted: encrypted)
    }

    private static func ecdsaKey(type: String, scalar: [UInt8], publicPoint: [UInt8]?) throws -> SSHPrivateKey {
        func padded(_ length: Int) throws -> Data {
            var bytes = Array(scalar.drop(while: { $0 == 0 }))
            guard bytes.count <= length else { throw SSHKeyImportError.malformed("ECDSA scalar length") }
            bytes = [UInt8](repeating: 0, count: length - bytes.count) + bytes
            return Data(bytes)
        }
        switch type {
        case "ecdsa-sha2-nistp256":
            let raw = try padded(32)
            let derived = Array(try P256.Signing.PrivateKey(rawRepresentation: raw).publicKey.x963Representation)
            if let publicPoint, derived != publicPoint { throw SSHKeyImportError.malformed("ECDSA public key mismatch") }
            return .p256(raw)
        case "ecdsa-sha2-nistp384":
            let raw = try padded(48)
            let derived = Array(try P384.Signing.PrivateKey(rawRepresentation: raw).publicKey.x963Representation)
            if let publicPoint, derived != publicPoint { throw SSHKeyImportError.malformed("ECDSA public key mismatch") }
            return .p384(raw)
        default:
            let raw = try padded(66)
            let derived = Array(try P521.Signing.PrivateKey(rawRepresentation: raw).publicKey.x963Representation)
            if let publicPoint, derived != publicPoint { throw SSHKeyImportError.malformed("ECDSA public key mismatch") }
            return .p521(raw)
        }
    }

    // MARK: PEM

    /// SEC1 (`EC PRIVATE KEY`) or PKCS#8 (`PRIVATE KEY`) EC key, parsed from DER here rather
    /// than by the platform, so Apple's CryptoKit and swift-crypto on Linux accept exactly the same
    /// files. The curve comes from its OID (or, without one, from the key length), and an
    /// embedded public key must match the private one.
    static func ecdsaFromDER(_ der: [UInt8]) throws -> SSHPrivateKey {
        var outer = DERReader(der)
        var sequence = try outer.read(tag: 0x30)
        let version = try sequence.read(tag: 0x02).allBytes
        if version == [0x00] {
            // PKCS#8: AlgorithmIdentifier { id-ecPublicKey, curve }, then the SEC1 key.
            var algorithm = try sequence.read(tag: 0x30)
            let algorithmOID = try algorithm.read(tag: 0x06).allBytes
            guard algorithmOID == Self.ecPublicKeyOID else {
                if algorithmOID == Self.rsaOID { throw SSHKeyImportError.unsupportedKeyType("RSA") }
                throw SSHKeyImportError.malformed("not an EC key")
            }
            // Named curve (OID), or explicit parameters (a SEQUENCE), which some OpenSSL/LibreSSL
            // builds write; then the curve is recognised from the key sizes below.
            let parameters = algorithm.isAtEnd ? nil : try algorithm.readAny()
            let curveOID = parameters?.tag == 0x06 ? parameters?.bytes : nil
            let inner = try sequence.read(tag: 0x04).allBytes
            return try ecdsaFromSEC1(inner, curveOID: curveOID)
        }
        return try ecdsaFromSEC1(der, curveOID: nil)
    }

    private static func ecdsaFromSEC1(_ der: [UInt8], curveOID outerCurve: [UInt8]?) throws -> SSHPrivateKey {
        var outer = DERReader(der)
        var sequence = try outer.read(tag: 0x30)
        guard try sequence.read(tag: 0x02).allBytes == [0x01] else { throw SSHKeyImportError.malformed("SEC1 version") }
        let scalar = try sequence.read(tag: 0x04).allBytes
        var curveOID = outerCurve
        var publicPoint: [UInt8]?
        while !sequence.isAtEnd {
            let element = try sequence.readAny()
            if element.tag == 0xA0 {
                var parameters = DERReader(element.bytes)
                let named = try parameters.readAny()
                if named.tag == 0x06 { curveOID = named.bytes }
            } else if element.tag == 0xA1 {
                var wrapper = DERReader(element.bytes)
                let bits = try wrapper.read(tag: 0x03).allBytes
                publicPoint = Array(bits.dropFirst()) // leading "unused bits" byte
            }
        }
        let type: String
        switch curveOID {
        case Self.p256OID?: type = "ecdsa-sha2-nistp256"
        case Self.p384OID?: type = "ecdsa-sha2-nistp384"
        case Self.p521OID?: type = "ecdsa-sha2-nistp521"
        case nil:
            // No named curve: the uncompressed public point (65/97/133 bytes) or the private
            // value's encoded length (32/48/66 bytes) identifies it.
            switch publicPoint?.count ?? 0 {
            case 65: type = "ecdsa-sha2-nistp256"
            case 97: type = "ecdsa-sha2-nistp384"
            case 133: type = "ecdsa-sha2-nistp521"
            default:
                switch scalar.count {
                case ...32: type = "ecdsa-sha2-nistp256"
                case ...48: type = "ecdsa-sha2-nistp384"
                default: type = "ecdsa-sha2-nistp521"
                }
            }
        default:
            throw SSHKeyImportError.malformed("unsupported EC curve")
        }
        let key = try ecdsaKey(type: type, scalar: scalar, publicPoint: nil)
        if let publicPoint {
            let derived = try key.publicKeyBlob()
            guard derived.containsSubsequence(publicPoint) else { throw SSHKeyImportError.malformed("ECDSA public key mismatch") }
        }
        return key
    }

    private static let ecPublicKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let p256OID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let p384OID: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]
    private static let p521OID: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]

    /// PKCS#8 Ed25519: a fixed 16-byte prefix followed by the 32-byte seed (RFC 8410).
    private static let ed25519PKCS8Prefix: [UInt8] = [0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
    private static let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    private static func ed25519SeedFromPKCS8(_ der: [UInt8]) -> [UInt8]? {
        guard der.count == ed25519PKCS8Prefix.count + 32, Array(der.prefix(ed25519PKCS8Prefix.count)) == ed25519PKCS8Prefix else { return nil }
        return Array(der.suffix(32))
    }
}

/// Minimal DER reader (definite lengths only), enough for EC private keys.
struct DERReader {
    struct Element { let tag: UInt8; let bytes: [UInt8] }
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readAny() throws -> Element {
        guard offset + 2 <= bytes.count else { throw SSHKeyImportError.malformed("truncated DER") }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 3, offset + count <= bytes.count else { throw SSHKeyImportError.malformed("DER length") }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[offset]); offset += 1 }
        }
        guard offset + length <= bytes.count else { throw SSHKeyImportError.malformed("truncated DER") }
        defer { offset += length }
        return Element(tag: tag, bytes: Array(bytes[offset..<(offset + length)]))
    }

    /// Reads one element with `tag`; for a SEQUENCE the result reads its contents.
    mutating func read(tag: UInt8) throws -> DERReader {
        let element = try readAny()
        guard element.tag == tag else { throw SSHKeyImportError.malformed("unexpected DER element") }
        return DERReader(element.bytes)
    }

    var allBytes: [UInt8] { bytes }

    /// The element tree as tags and lengths only (no contents), for diagnosing unusual files.
    static func outline(_ der: [UInt8], depth: Int = 0) -> String {
        var reader = DERReader(der)
        var lines: [String] = []
        while !reader.isAtEnd, let element = try? reader.readAny() {
            lines.append(String(repeating: "  ", count: depth) + String(format: "tag 0x%02X, %d bytes", element.tag, element.bytes.count))
            if [0x30, 0xA0, 0xA1].contains(element.tag), depth < 4 {
                lines.append(outline(element.bytes, depth: depth + 1))
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// One `-----BEGIN …-----` block.
struct PEMBlock {
    let label: String
    let body: String
    let encryptedHeader: Bool

    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else { return nil }
        let label = String(lines[start].dropFirst("-----BEGIN ".count).dropLast(5))
        guard let end = lines[(start + 1)...].firstIndex(of: "-----END \(label)-----") else { return nil }
        let inner = lines[(start + 1)..<end]
        self.label = label
        self.encryptedHeader = inner.contains { $0.hasPrefix("Proc-Type:") && $0.contains("ENCRYPTED") }
        self.body = inner.filter { !$0.contains(":") }.joined()
    }

    var der: [UInt8]? { Data(base64Encoded: body).map(Array.init) }
}

/// Reads SSH wire-format values (RFC 4251).
struct SSHReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readMagic() throws {
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard bytes.count >= magic.count, Array(bytes[0..<magic.count]) == magic else { throw SSHKeyImportError.malformed("not an openssh-key-v1 file") }
        offset = magic.count
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw SSHKeyImportError.malformed("truncated") }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func readString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        return try readBytes(length)
    }

    mutating func readStringUTF8() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    /// An mpint: big-endian, possibly with a leading zero byte.
    mutating func readMPInt() throws -> [UInt8] { try readString() }
}

extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) where self[start] == needle[0] {
            if Array(self[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
