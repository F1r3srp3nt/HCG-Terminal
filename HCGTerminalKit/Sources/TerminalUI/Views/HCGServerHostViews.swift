#if canImport(UIKit) && canImport(SwiftUI)
import DeviceLinkIntegration
import HCGDeviceLink
import SwiftUI

/// The paired HCG Server as a development host (Connected Devices): host summary and
/// availability, the services it hosts, and its read-only diagnostics.
///
/// Everything shown comes from the server's last real answer (`link/services`,
/// `link/diagnostics`) and is rendered as plain text. "Open" hands a single-use link to the
/// system browser (Safari verifies the gateway's certificate); nothing is shown in a web view
/// here, nothing is run on the server, and there is no remote shell.
struct HCGServerHostSections: View {
    let link: DeviceLinkController
    @Environment(\.openURL) private var openURL

    var body: some View {
        hostSection.hcgRows()
        servicesSection.hcgRows()
        diagnosticsSection.hcgRows()
    }

    // MARK: Host

    private var hostSection: some View {
        Section {
            if link.isLocalDevelopment {
                LocalDevelopmentBadge()
            }
            availabilityRow
            if let host = link.hostSummary {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").foregroundStyle(HCGPalette.silver).frame(width: 24).accessibilityHidden(true)
                    Text(verbatim: host.name).font(.headline).foregroundStyle(HCGPalette.textPrimary)
                    Spacer(minLength: 8)
                    DeviceRoleBadge(role: .server)
                }
                .accessibilityElement(children: .combine)
                HostFactRow(title: "Platform", value: HostingText.platform(host))
                HostFactRow(title: "Chip", value: HostingText.chip(host))
                if let memory = HostingText.memory(host) { HostFactRow(title: "Memory", value: memory) }
                if let load = HostingText.load(host) { HostFactRow(title: "Load average", value: load) }
                HostFactRow(title: "HCG Server agent", value: host.agentVersion)
                HostFactRow(title: "Agent uptime", value: HostingText.agentUptime(host))
                HostFactRow(title: "Gateway exposure", value: HostingText.exposure(host.gatewayExposure))
                if let updated = link.hostingUpdatedAt {
                    HostFactRow(title: "Updated", value: LinkFormatting.relative(updated))
                }
            } else if let problem = link.sectionProblems[.services] {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            } else {
                Text("Not loaded yet. The host is shown after HCG Server answers.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
        } header: { Text("HCG Server host") } footer: {
            Text("Only facts HCG Server approves for paired devices: no user names, paths, addresses or environment.")
        }
    }

    private var availabilityRow: some View {
        let availability = link.hostAvailability
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: availabilitySymbol(availability)).foregroundStyle(availabilityColor(availability)).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: availability.title).font(.subheadline.weight(.semibold)).foregroundStyle(HCGPalette.textPrimary)
                switch availability {
                case .unknown:
                    Text("No answer from HCG Server yet.").font(.caption).foregroundStyle(HCGPalette.textSecondary)
                case .reachable(let at):
                    Text(verbatim: "Answered \(LinkFormatting.relative(at))").font(.caption).foregroundStyle(HCGPalette.textSecondary)
                case .unreachable(let reason, let retry), .failing(let reason, let retry):
                    Text(verbatim: "\(reason) Retrying in \(Int(retry.rounded(.up))) s.")
                        .font(.caption).foregroundStyle(HCGPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func availabilitySymbol(_ availability: HostAvailability) -> String {
        switch availability {
        case .unknown: "circle.dashed"
        case .reachable: "checkmark.circle"
        case .unreachable: "wifi.exclamationmark"
        case .failing: "exclamationmark.triangle"
        }
    }

    private func availabilityColor(_ availability: HostAvailability) -> Color {
        switch availability {
        case .unknown: HCGPalette.muted
        case .reachable: HCGPalette.ok
        case .unreachable: HCGPalette.loss
        case .failing: HCGPalette.warn
        }
    }

    // MARK: Hosted services

    private var servicesSection: some View {
        Section {
            if let services = link.hostedServices {
                if services.isEmpty {
                    Text("HCG Server hosts no services.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                }
                ForEach(services) { service in
                    HostedServiceRow(
                        service: service,
                        opening: link.openingService == service.id,
                        problem: link.serviceProblems[service.id],
                        exposure: link.hostSummary?.gatewayExposure,
                        open: { Task { await open(service) } }
                    )
                    .disabled(link.openingService != nil || !link.state.isLinked)
                }
            } else if let problem = link.sectionProblems[.services] {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            } else {
                Text("Not loaded yet.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
            if let ticket = link.openedTicket {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(verbatim: "Opened \(ticket.serviceName) in Safari \(LinkFormatting.relative(ticket.openedAt))")
                    } icon: {
                        Image(systemName: "safari")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HCGPalette.textPrimary)
                    FingerprintRow(title: "HCG Server Local CA (SHA-256)", fingerprint: ticket.caFingerprint)
                    if link.ticketCAMatchesDiagnostics == false {
                        Label("This CA differs from the one in the server's diagnostics. Do not trust it until you have compared it on the Mac.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(HCGPalette.loss)
                    }
                    Text(verbatim: ticket.note).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        } header: { Text("Hosted services") } footer: {
            Text(verbatim: HostingText.openFooter)
        }
    }

    private func open(_ service: LinkHostedService) async {
        guard let url = await link.openService(service) else { return }
        // The system browser verifies the gateway with the HCG Server Local CA.
        openURL(url)
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            if let diagnostics = link.diagnostics {
                ForEach(Array(diagnostics.summary.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.callout).foregroundStyle(HCGPalette.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                HostFactRow(title: "Server", value: diagnostics.server.available ? "Available" : "Not available")
                HostFactRow(title: "Agent version", value: diagnostics.server.agentVersion)
                HostFactRow(title: "Server uptime", value: HostingText.duration(diagnostics.server.uptimeSeconds))
                HostFactRow(title: "Authority", value: LinkAuthorityText.label(diagnostics.server.authority))
                HostFactRow(title: "Device API", value: diagnostics.tls.deviceApi)
                FingerprintRow(title: "Server key (SHA-256)", fingerprint: diagnostics.tls.serverKeySha256)
                HostFactRow(title: "Gateway", value: diagnostics.tls.gatewayRunning ? "Running" : "Not running")
                HostFactRow(title: "Gateway exposure", value: HostingText.exposure(diagnostics.tls.gatewayExposure))
                if !diagnostics.tls.gatewayCaSha256.isEmpty {
                    FingerprintRow(title: "Gateway CA (SHA-256)", fingerprint: diagnostics.tls.gatewayCaSha256)
                }
                if let expires = diagnostics.tls.gatewayLeafExpires {
                    HostFactRow(title: "Gateway certificate expires", value: expires.formatted(date: .abbreviated, time: .omitted))
                }
                HostFactRow(title: "Failed authentications (24 h)", value: "\(diagnostics.failedAuthentications24h)")
                if diagnostics.securityEvents.isEmpty {
                    Text("No security events.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                } else {
                    ForEach(Array(diagnostics.securityEvents.enumerated()), id: \.offset) { _, event in
                        SecurityEventRow(event: event)
                    }
                }
            } else if let problem = link.sectionProblems[.diagnostics] {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            } else {
                Text("Not loaded yet.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
        } header: { Text("Server diagnostics (read only)") } footer: {
            Text("HCG Server redacts these before sending them: no addresses, credentials or logs. Nothing here can change the server.")
        }
    }
}

/// One hosted service: status, health and, when the gateway allows it, Open.
struct HostedServiceRow: View {
    let service: LinkHostedService
    let opening: Bool
    let problem: String?
    let exposure: String?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: healthSymbol).foregroundStyle(healthColor).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: service.name).font(.subheadline.weight(.semibold)).foregroundStyle(HCGPalette.textPrimary)
                    Text(verbatim: "\(service.id) · \(service.version) · \(service.runtime)").font(.caption).foregroundStyle(HCGPalette.textSecondary)
                }
            }
            Text(verbatim: HostingText.serviceLine(service)).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            if let last = service.lastHealthAt {
                Text(verbatim: "Last health check \(LinkFormatting.relative(last))").font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
            if let detail = service.detail, !detail.isEmpty {
                Text(verbatim: detail).font(.caption).foregroundStyle(HCGPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if service.openable {
                Button(action: open) {
                    if opening {
                        ProgressView()
                    } else {
                        Label("Open in Safari", systemImage: "safari")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Asks HCG Server for a single-use link and opens it in Safari")
            } else if service.gatewayPublished, exposure != "lan" {
                Label { Text(verbatim: HostingText.gatewayLocalOnly) } icon: { Image(systemName: "lock.laptopcomputer") }
                    .font(.footnote).foregroundStyle(HCGPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else if !service.gatewayPublished {
                Text("Not published through HCG Server's gateway.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
            if let problem {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var healthSymbol: String {
        switch service.health {
        case "ok": "checkmark.circle"
        case "failing": "exclamationmark.triangle"
        default: "questionmark.circle"
        }
    }

    private var healthColor: Color {
        switch service.health {
        case "ok": HCGPalette.ok
        case "failing": HCGPalette.loss
        default: HCGPalette.muted
        }
    }
}

struct SecurityEventRow: View {
    let event: LinkDiagEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(event.severity.uppercased()) · \(LinkFormatting.relative(event.time))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(event.severity == "critical" || event.severity == "error" ? HCGPalette.loss : HCGPalette.warn)
            Text(verbatim: event.message).font(.caption).foregroundStyle(HCGPalette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A title and a value that wraps (values are server text, shown verbatim).
struct HostFactRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(verbatim: value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        } label: {
            Text(verbatim: title)
        }
    }
}

/// The label every local-development connection carries.
struct LocalDevelopmentBadge: View {
    var body: some View {
        Label {
            Text(verbatim: LinkAuthorityText.localDevelopmentLabel)
        } icon: {
            Image(systemName: "hammer.circle")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(HCGPalette.warn)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(HCGPalette.warn.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(HCGPalette.warn.opacity(0.4), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
#endif
