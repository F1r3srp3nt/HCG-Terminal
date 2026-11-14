import Foundation
#if canImport(Security)
import Security
#endif

/// Small secret store abstraction (Keychain on Apple platforms, memory in tests).
public protocol LinkSecretStore: Sendable {
    func read(_ account: String) -> Data?
    func write(_ account: String, _ data: Data) throws
    func delete(_ account: String)
}

/// In-memory store for tests and previews. Never used for real credentials.
public final class MemorySecretStore: LinkSecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func write(_ account: String, _ data: Data) throws { lock.lock(); items[account] = data; lock.unlock() }
    public func delete(_ account: String) { lock.lock(); items[account] = nil; lock.unlock() }
}

#if canImport(Security) && canImport(Darwin)
/// Generic-password Keychain items, this device only, available after first
/// unlock (so a foreground app can sync without prompting).
public struct KeychainSecretStore: LinkSecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func write(_ account: String, _ data: Data) throws {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add.merge(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain error \(status)"])
        }
    }

    public func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}
#endif

/// Keychain-backed HCG Connect token storage.
public struct SecretTokenStore: HCGConnectTokenStore {
    public let store: LinkSecretStore
    public init(store: LinkSecretStore) { self.store = store }

    public func load() -> HCGConnectTokens? {
        store.read("hcg-connect.tokens").flatMap { try? LinkJSON.decoder().decode(HCGConnectTokens.self, from: $0) }
    }

    public func save(_ tokens: HCGConnectTokens?) throws {
        guard let t = tokens else { store.delete("hcg-connect.tokens"); return }
        try store.write("hcg-connect.tokens", try LinkJSON.encoder().encode(t))
    }
}

/// This app installation's identity: a random installation ID and a P-256
/// key (Secure Enclave when the device has one). Created on first use, kept
/// in the Keychain, never exported.
public struct InstallationIdentity: Sendable {
    public let installationId: String
    public let signer: LinkSigner
    public let keyKind: String // "secure-enclave" | "software"

    public var fingerprint: String { signer.fingerprint }

    public static func loadOrCreate(store: LinkSecretStore, preferSecureEnclave: Bool = true) throws -> InstallationIdentity {
        let idData = store.read("installation.id")
        var id = idData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if UUID(uuidString: id) == nil {
            id = LinkCrypto.uuid()
            try store.write("installation.id", Data(id.utf8))
            store.delete("installation.key.se")
            store.delete("installation.key.sw")
        }
        #if canImport(CryptoKit) && !os(macOS)
        if preferSecureEnclave, SecureEnclaveSigner.isAvailable {
            if let blob = store.read("installation.key.se"), let s = try? SecureEnclaveSigner(dataRepresentation: blob) {
                return InstallationIdentity(installationId: id, signer: s, keyKind: "secure-enclave")
            }
            if store.read("installation.key.sw") == nil, let s = try? SecureEnclaveSigner() {
                try store.write("installation.key.se", s.dataRepresentation)
                return InstallationIdentity(installationId: id, signer: s, keyKind: "secure-enclave")
            }
        }
        #endif
        if let raw = store.read("installation.key.sw"), let s = try? SoftwareSigner(rawRepresentation: raw) {
            return InstallationIdentity(installationId: id, signer: s, keyKind: "software")
        }
        let s = SoftwareSigner()
        try store.write("installation.key.sw", s.rawRepresentation)
        return InstallationIdentity(installationId: id, signer: s, keyKind: "software")
    }

    /// Forgets the identity (after removal from a server): a new ID and key next time.
    public static func reset(store: LinkSecretStore) {
        for k in ["installation.id", "installation.key.se", "installation.key.sw"] { store.delete(k) }
    }
}

/// What this installation remembers about the server it paired with (not secret).
public struct PairingRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, approved, rejected, expired, removed }

    public var serverAddress: String
    public var serverFingerprint: String
    public var serverName: String
    public var serverDeviceId: String
    public var requestId: String
    public var status: Status
    public var updatedAt: Date

    public init(invitation: Invitation, requestId: String, status: Status, at: Date = Date()) {
        serverAddress = invitation.hostAddress
        serverFingerprint = invitation.fingerprint
        serverName = invitation.hostName
        serverDeviceId = invitation.hostDeviceId
        self.requestId = requestId
        self.status = status
        updatedAt = at
    }

    public var baseURL: URL? { URL(string: "https://" + serverAddress) }
}

/// Persists the pairing record as JSON (Application Support).
public struct PairingRecordFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> PairingRecord? {
        (try? Data(contentsOf: url)).flatMap { try? LinkJSON.decoder().decode(PairingRecord.self, from: $0) }
    }

    public func save(_ r: PairingRecord?) throws {
        guard let r = r else { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try LinkJSON.encoder().encode(r).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try LinkJSON.encoder().encode(r).write(to: url, options: [.atomic])
        #endif
    }
}
