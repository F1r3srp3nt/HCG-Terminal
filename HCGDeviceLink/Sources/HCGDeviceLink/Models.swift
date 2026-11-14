import Foundation

/// HCG Device Link protocol constants (`hcg.devicelink/1`, see HCG-Server docs/DEVICE-LINK.md).
public enum DeviceLinkProtocol {
    public static let name = "hcg.devicelink/1"
    public static let version = 1
    public static let prefix = "/peer/v1/link"
    public static let reportSchema = "hcg.diagnostic-report/1"
    public static let redactionPolicy = "hcg.redaction/1"
    /// Version of this Swift client package (bump on every change; vendored copies must match).
    public static let clientVersion = "1.0.0"

    public enum Header {
        public static let protocolVersion = "HCG-Link-Protocol"
        public static let installation = "HCG-Link-Installation"
        public static let timestamp = "HCG-Link-Timestamp"
        public static let nonce = "HCG-Link-Nonce"
        public static let signature = "HCG-Link-Signature"
        public static let organisation = "HCG-Link-Organisation"
    }

    /// Foreground polling cadence.
    public static let heartbeatInterval: TimeInterval = 20
    public static let inboxInterval: TimeInterval = 10
    public static let onlineWindow: TimeInterval = 45
    public static let maxMessageLifetime: TimeInterval = 7 * 24 * 3600
}

/// Capability identifiers (information, never authorization).
public enum LinkCapabilityID {
    public static let reportSend = "report.send"
    public static let reportReceive = "report.receive"
    public static let reportView = "report.view"
    public static let terminalWorkspace = "terminal.workspace.commands"
    public static let terminalRemoteSSH = "terminal.remote.ssh"
    public static let terminalLocalShell = "terminal.local.shell"
    public static let terminalExpandedFiles = "terminal.files.expanded"
    public static let terminalPrivileged = "terminal.privileged"
}

public enum LinkCapabilityState: String, Codable, Sendable, Equatable {
    case available, verified, unavailable, disabled

    public var isUsable: Bool { self == .available || self == .verified }
}

/// An installation's own statement about one capability.
public struct LinkCapability: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var state: LinkCapabilityState
    public var reason: String?
    public var verifiedAt: Date?
    public var evidence: String?

    public init(id: String, state: LinkCapabilityState, reason: String? = nil, verifiedAt: Date? = nil, evidence: String? = nil) {
        self.id = id
        self.state = state
        self.reason = reason
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }
}

public struct LinkInstallationInfo: Codable, Sendable, Equatable {
    public var installationId: String
    public var deviceId: String?
    public var name: String
    public var platform: String
    public var app: String
    public var appVersion: String
    public var variant: String?
    public var publicKey: String
    public var protocolVersions: [Int]
    public var capabilities: [LinkCapability]

    public init(installationId: String, deviceId: String?, name: String, platform: String, app: String, appVersion: String,
                variant: String?, publicKey: String, protocolVersions: [Int] = [DeviceLinkProtocol.version], capabilities: [LinkCapability]) {
        self.installationId = installationId
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
        self.app = app
        self.appVersion = appVersion
        self.variant = variant
        self.publicKey = publicKey
        self.protocolVersions = protocolVersions
        self.capabilities = capabilities
    }
}

public struct LinkPairRequest: Codable, Sendable {
    public var invitationId: String
    public var secret: String
    public var installation: LinkInstallationInfo
}

public struct LinkHost: Codable, Sendable, Equatable {
    public var deviceId: String
    public var name: String
    public var fingerprint: String
}

public struct LinkAccount: Codable, Sendable, Equatable {
    public var subject: String
    public var email: String?
}

public struct LinkOrganisation: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
}

public struct LinkBoundary: Codable, Sendable, Equatable {
    public var kind: String
    public var organisation: LinkOrganisation?
    public var account: LinkAccount?
    public var setAt: Date
}

public struct LinkPairStatus: Codable, Sendable, Equatable {
    public var requestId: String
    public var status: String
    public var host: LinkHost
    public var keyFingerprint: String
    public var expiresAt: Date
    public var decidedAt: Date?
}

public enum LinkPresenceState: String, Codable, Sendable {
    case online
    case offline
    case neverSeen = "never-seen"
    case revoked
}

public struct LinkInstallation: Codable, Sendable, Equatable, Identifiable {
    public var installationId: String
    public var deviceId: String?
    public var name: String
    public var platform: String
    public var app: String
    public var appVersion: String
    public var variant: String?
    public var keyFingerprint: String
    public var protocolVersions: [Int]
    public var capabilities: [LinkCapability]
    public var account: LinkAccount
    public var organisation: LinkOrganisation?
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var state: LinkPresenceState
    public var revokedAt: Date?
    public var revokedBy: String?

    public var id: String { installationId }

    public func capability(_ id: String) -> LinkCapability? { capabilities.first { $0.id == id } }
    public func supports(_ id: String) -> Bool { capability(id)?.state.isUsable ?? false }
}

public struct LinkDevices: Codable, Sendable, Equatable {
    public var `protocol`: String
    public var host: LinkHost
    /// This installation's ID (JSON `self`).
    public var selfInstallationId: String
    public var boundary: LinkBoundary?
    public var installations: [LinkInstallation]
    public var onlineWindowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case `protocol`, host, selfInstallationId = "self", boundary, installations, onlineWindowSeconds
    }
}

public struct LinkHeartbeat: Codable, Sendable {
    public var capabilities: [LinkCapability]?
    public init(capabilities: [LinkCapability]?) { self.capabilities = capabilities }
}

public struct LinkHeartbeatResult: Codable, Sendable {
    public var state: LinkPresenceState
    public var lastSeenAt: Date?
    public var serverTime: Date
}

public struct LinkSendReceipt: Codable, Sendable, Equatable {
    public var messageId: String
    public var status: String
    public var duplicate: Bool
    public var recipientState: String
    public var queuedAt: Date
    public var expiresAt: Date
}

public struct LinkParty: Codable, Sendable, Equatable {
    public var installationId: String
    public var name: String
    public var app: String
}

public struct LinkMessageHeader: Codable, Sendable, Equatable, Identifiable {
    public var messageId: String
    public var type: String
    public var from: LinkParty
    public var to: LinkParty
    public var title: String
    public var createdAt: Date
    public var queuedAt: Date
    public var expiresAt: Date
    public var status: String
    public var size: Int
    public var deliveredAt: Date?
    public var openedAt: Date?

    public var id: String { messageId }
}

public struct LinkMessageList: Codable, Sendable {
    public var messages: [LinkMessageHeader]
}

public struct LinkAck: Codable, Sendable {
    public var state: String
}

public struct LinkActionRequest: Codable, Sendable, Equatable {
    public var actionId: String
    public var type: String
    public var target: String
    public var parameters: [String: String]
    public var createdAt: Date
    public var expiresAt: Date
    public var requiredPermission: String
}

public struct LinkApprovalRecord: Codable, Sendable, Equatable {
    public var state: String
    public var decidedBy: String?
    public var decidedAt: Date?
    public var decidingInstallation: String?
}

public struct LinkApproval: Codable, Sendable, Equatable {
    public var action: LinkActionRequest
    public var origin: LinkParty
    public var approval: LinkApprovalRecord
}

public struct LinkApprovals: Codable, Sendable, Equatable {
    public var approvals: [LinkApproval]
    public var executionEnabled: Bool
    public var note: String
}

/// The Device Link error body.
public struct LinkErrorBody: Codable, Sendable, Equatable {
    public var error: String
    public var code: String
    public var retryable: Bool?
    public var retryAfterSeconds: Int?
    public var `protocol`: String?
    public var supportedVersions: [Int]?
    public var blockingLayer: String?
}

// MARK: - JSON

public enum LinkJSON {
    /// Go encodes times as RFC 3339 with up to nanoseconds; accept any precision.
    public static func parseDate(_ s: String) -> Date? {
        var str = s
        if let dot = str.firstIndex(of: ".") {
            var end = str.index(after: dot)
            while end < str.endIndex, str[end].isNumber { end = str.index(after: end) }
            let frac = str[str.index(after: dot)..<end]
            let ms = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            str = String(str[..<dot]) + "." + ms + String(str[end...])
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: str)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: str)
    }

    public static func formatDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an RFC 3339 time: \(s)")
            }
            return date
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatDate(date))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
