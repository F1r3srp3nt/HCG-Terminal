import Foundation
import HCGDeviceLink

/// Whether the paired HCG Server answered the last sync round. Derived from real requests only:
/// before the first answer it is `unknown`, never "reachable".
public enum HostAvailability: Equatable, Sendable {
    /// Not contacted yet (or not paired).
    case unknown
    /// The last round succeeded at `at`.
    case reachable(at: Date)
    /// The request did not reach HCG Server (network, TLS or pinning); `reason` is the real error.
    case unreachable(reason: String, retryIn: TimeInterval)
    /// HCG Server answered, but with an error; `reason` is its message.
    case failing(reason: String, retryIn: TimeInterval)

    public var title: String {
        switch self {
        case .unknown: "Not contacted yet"
        case .reachable: "Reachable"
        case .unreachable: "Unreachable"
        case .failing: "Reachable, answering with an error"
        }
    }
}

/// What was opened with the last single-use service link. The link itself is not kept: it is
/// handed to the system browser once and then forgotten.
public struct OpenedServiceTicket: Equatable, Sendable {
    public var serviceId: String
    public var serviceName: String
    /// SHA-256 of the HCG Server Local CA the browser verifies the gateway with.
    public var caFingerprint: String
    public var note: String
    public var expiresAt: Date
    public var openedAt: Date
}

/// Wording and formatting for the HCG Server host, hosted services and diagnostics. Kept out of
/// the views so it is tested on every platform.
public enum HostingText {
    /// `gateway_local_only`: the gateway listens on the Mac only.
    public static let gatewayLocalOnly =
        "HCG Server's gateway is reachable from the Mac only. The owner must approve local-network exposure on the Mac (in HCG Server, or `hcg-agent hosting expose lan --i-approve-local-network-exposure`) before this device can open hosted services."

    public static let notHosting = "This HCG Server does not host services."

    public static let openFooter =
        "Open asks HCG Server for a single-use link that is valid for 60 seconds and opens it in Safari, which verifies the gateway with the HCG Server Local CA. Compare the CA SHA-256 below with the one shown on the Mac. HCG Terminal never weakens certificate checks and runs nothing on the server."

    /// The message for a failed request to `openService`, from the server's code.
    public static func openFailure(_ error: DeviceLinkError) -> String {
        switch error.code {
        case "gateway_local_only": gatewayLocalOnly
        case "hosting_unavailable": notHosting
        default: error.description
        }
    }

    /// The message for a hosting section that could not be loaded.
    public static func sectionFailure(_ error: DeviceLinkError) -> String {
        error.code == "hosting_unavailable" ? notHosting : error.description
    }

    public static func status(_ status: String) -> String {
        switch status {
        case "registered": "Registered"
        case "starting": "Starting"
        case "running": "Running"
        case "unhealthy": "Unhealthy"
        case "stopping": "Stopping"
        case "stopped": "Stopped"
        case "crashed": "Crashed"
        case "failed": "Failed"
        default: status.isEmpty ? "Unknown" : status
        }
    }

    public static func health(_ health: String) -> String {
        switch health {
        case "ok": "Healthy"
        case "failing": "Health check failing"
        default: "Health unknown"
        }
    }

    public static func exposure(_ exposure: String) -> String {
        switch exposure {
        case "loopback": "This Mac only (local network not approved)"
        case "lan": "Local network (approved by the owner)"
        case "": "Not reported"
        default: exposure
        }
    }

    /// "macOS 26.1 · arm64".
    public static func platform(_ host: LinkHostSummary) -> String {
        [[host.platform, host.osVersion].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " "), host.architecture]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// "Apple M3 Pro · 12 cores".
    public static func chip(_ host: LinkHostSummary) -> String {
        let name = host.cpuModel.flatMap { $0.isEmpty ? nil : $0 } ?? host.architecture
        return host.logicalCpus > 0 ? "\(name) · \(host.logicalCpus) cores" : name
    }

    /// "36 GB · 12.4 GB available", or nil when the server did not report memory.
    public static func memory(_ host: LinkHostSummary) -> String? {
        guard let total = host.memoryTotalBytes else { return nil }
        var text = bytes(total)
        if let available = host.memoryAvailableBytes { text += " · \(bytes(available)) available" }
        return text
    }

    /// Agent uptime as the server reported it (start time against its own sample time).
    public static func agentUptime(_ host: LinkHostSummary) -> String {
        duration(Int64(max(0, host.sampledAt.timeIntervalSince(host.agentStartedAt))))
    }

    public static func load(_ host: LinkHostSummary) -> String? {
        guard let load = host.loadAverage, !load.isEmpty else { return nil }
        return load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " · ")
    }

    public static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return gb >= 10 || gb.rounded() == gb ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb) }
        return "\(Int((Double(value) / 1_048_576).rounded())) MB"
    }

    /// "3 d 4 h", "2 h 5 min", "42 s".
    public static func duration(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(s) s"
    }

    /// One line for a service: "Running · Healthy · up 2 h 5 min · 1 restart".
    public static func serviceLine(_ service: LinkHostedService) -> String {
        var parts = [status(service.status), health(service.health)]
        if let up = service.uptimeSeconds, service.status == "running" || service.status == "unhealthy" { parts.append("up " + duration(up)) }
        if service.restarts > 0 { parts.append("\(service.restarts) restart\(service.restarts == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
