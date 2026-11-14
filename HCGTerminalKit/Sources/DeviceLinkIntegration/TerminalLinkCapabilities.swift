import Foundation
import HCGDeviceLink
import TerminalCapabilityProvider
import TerminalCore

/// Which HCG Terminal build this is, as Device Link names it (`variant`). Decided by the app
/// target at compile time (what is linked), never by the app's name or bundle identifier.
public enum TerminalLinkVariant: String, Sendable, CaseIterable {
    case vanilla
    case unleashed

    /// The `variant` value sent to HCG Server (display only on the server).
    public var wireValue: String { rawValue }

    public var displayName: String {
        switch self {
        case .vanilla: "Vanilla"
        case .unleashed: "Unleashed"
        }
    }
}

/// The capabilities HCG Terminal advertises over Device Link.
///
/// Rules (HCG-Server docs/DEVICE-LINK.md, "Capabilities"):
/// - An advertisement is information. It can make HCG Server refuse an operation; it never
///   allows anything, here or on the server.
/// - The inputs are this app's own build variant, its own capability reports (detection plus
///   real use on this device) and the user's Capabilities & Access switches. Nothing the server
///   sends is an input: there is no parameter for it.
/// - The Unleashed capabilities are advertised as `verified` only in the Unleashed build, and only
///   when the report's result for that capability is `.verified`. App name, bundle identifier,
///   package presence or marker files alone never count.
public enum TerminalLinkCapabilities {
    /// Reasons used in advertisements (short; shown on other devices).
    public enum Reason {
        public static let vanillaBuild = "Vanilla build"
        public static let helperUnavailable = "Unleashed helper not available"
        public static let notVerified = "Not verified on this device yet"
        public static let switchedOff = "Turned off in Capabilities & Access"
    }

    /// Longest reason or evidence text sent to the server.
    static let maxTextLength = 160

    /// The advertisement for this installation.
    /// - Parameters:
    ///   - distribution: the build that is running (from what the app target linked).
    ///   - reports: this app's capability reports, by local mode.
    ///   - access: the user's Capabilities & Access switches (they only ever restrict).
    public static func advertised(
        distribution: TerminalLinkVariant,
        reports: [ExecutionMode: CapabilityReport],
        access: AccessPolicy
    ) -> [LinkCapability] {
        var out = [
            LinkCapability(id: LinkCapabilityID.reportReceive, state: .available),
            LinkCapability(id: LinkCapabilityID.reportView, state: .available),
            workspaceCommands(vanilla: reports[.vanilla], access: access),
            remoteSSH(access: access),
        ]
        // Only a report produced for Unleashed mode counts, with the switches applied again
        // (idempotent) so a switch that is off is always honoured.
        let unleashed = reports[.unleashed].flatMap { $0.mode == .unleashed ? $0.applying(access: access) : nil }
        out.append(unleashedCapability(LinkCapabilityID.terminalLocalShell, kind: .localShell, distribution: distribution, report: unleashed,
                                       evidence: "local shell launch verified on this device"))
        out.append(unleashedCapability(LinkCapabilityID.terminalExpandedFiles, kind: .fileReading, distribution: distribution, report: unleashed,
                                       evidence: "file read outside the app sandbox verified on this device"))
        out.append(unleashedCapability(LinkCapabilityID.terminalPrivileged, kind: .privilegedOperations, distribution: distribution, report: unleashed,
                                       evidence: "approved privileged operation verified on this device"))
        return out
    }

    static func workspaceCommands(vanilla: CapabilityReport?, access: AccessPolicy) -> LinkCapability {
        let id = LinkCapabilityID.terminalWorkspace
        guard access.isEnabled(.workspaceCommands) else { return LinkCapability(id: id, state: .disabled, reason: Reason.switchedOff) }
        if let result = vanilla.map({ $0[.localShell] }), !result.availability.isUsable {
            if case .disabledByUser = result.availability { return LinkCapability(id: id, state: .disabled, reason: Reason.switchedOff) }
            return LinkCapability(id: id, state: .unavailable, reason: reason(result.availability))
        }
        return LinkCapability(id: id, state: .available)
    }

    static func remoteSSH(access: AccessPolicy) -> LinkCapability {
        access.isEnabled(.remoteSSH)
            ? LinkCapability(id: LinkCapabilityID.terminalRemoteSSH, state: .available)
            : LinkCapability(id: LinkCapabilityID.terminalRemoteSSH, state: .disabled, reason: Reason.switchedOff)
    }

    static func unleashedCapability(
        _ id: String, kind: CapabilityKind, distribution: TerminalLinkVariant, report: CapabilityReport?, evidence: String
    ) -> LinkCapability {
        guard distribution == .unleashed else { return LinkCapability(id: id, state: .unavailable, reason: Reason.vanillaBuild) }
        guard let report else { return LinkCapability(id: id, state: .unavailable, reason: Reason.helperUnavailable) }
        let result = report[kind]
        switch result.availability {
        case .verified:
            let observed = result.evidence.filter(\.positive).compactMap(\.timestamp).max()
            return LinkCapability(id: id, state: .verified, verifiedAt: observed ?? report.generatedAt, evidence: evidence)
        case .disabledByUser:
            return LinkCapability(id: id, state: .disabled, reason: Reason.switchedOff)
        case .notIncluded:
            return LinkCapability(id: id, state: .unavailable, reason: Reason.helperUnavailable)
        case .availableUntested:
            return LinkCapability(id: id, state: .unavailable, reason: Reason.notVerified)
        case .environmentUnknown, .toolMissing, .permissionDenied:
            return LinkCapability(id: id, state: .unavailable, reason: reason(result.availability))
        }
    }

    /// "Permission denied: …", shortened.
    static func reason(_ availability: CapabilityAvailability) -> String {
        let detail = availability.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = detail.isEmpty ? availability.label : "\(availability.label): \(detail)"
        return text.count <= maxTextLength ? text : String(text.prefix(maxTextLength - 1)) + "…"
    }
}

/// Human names for Device Link app identifiers (display only).
public enum LinkAppNames {
    public static let terminal = "hcg.terminal"

    public static func display(_ app: String) -> String {
        switch app {
        case "hcg.sentinel": "HCG Sentinel"
        case "hcg.terminal": "HCG Terminal"
        case "hcg.nexus": "HCG Nexus"
        case "hcg.server": "HCG Server"
        default: app
        }
    }

    public static func variant(_ variant: String?) -> String? {
        switch variant {
        case "vanilla": "Vanilla"
        case "unleashed": "Unleashed"
        case .none: nil
        case .some(let other): other
        }
    }
}

/// Display names for capability identifiers and states (any app's advertisement; display only).
public enum LinkCapabilityNames {
    public static func title(_ id: String) -> String {
        switch id {
        case LinkCapabilityID.reportSend: "Send reports"
        case LinkCapabilityID.reportReceive: "Receive reports"
        case LinkCapabilityID.reportView: "View reports"
        case LinkCapabilityID.terminalWorkspace: "Workspace commands"
        case LinkCapabilityID.terminalRemoteSSH: "Remote SSH"
        case LinkCapabilityID.terminalLocalShell: "Local shell"
        case LinkCapabilityID.terminalExpandedFiles: "Expanded files"
        case LinkCapabilityID.terminalPrivileged: "Privileged operations"
        default: id
        }
    }

    public static func state(_ state: LinkCapabilityState) -> String {
        switch state {
        case .available: "Available"
        case .verified: "Verified"
        case .unavailable: "Unavailable"
        case .disabled: "Off"
        }
    }
}

/// Display text for presence (computed by the server from when it last heard from a device).
public enum LinkPresenceText {
    public static func label(_ state: LinkPresenceState) -> String {
        switch state {
        case .online: "Online"
        case .offline: "Offline"
        case .neverSeen: "Never seen"
        case .revoked: "Removed"
        }
    }
}
