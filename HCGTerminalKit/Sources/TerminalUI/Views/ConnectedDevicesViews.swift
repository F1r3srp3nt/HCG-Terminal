#if canImport(UIKit) && canImport(SwiftUI)
import AuthenticationServices
import DeviceLinkIntegration
import HCGDeviceLink
import SwiftUI
import TerminalCore
import UIKit

/// Connected Devices (HCG Device Link): this installation, HCG Connect sign-in, pairing with an
/// HCG Server, paired devices and the reports they share.
///
/// Everything received from the server or another device is shown as plain text
/// (`Text(verbatim:)`): no Markdown, no links, nothing copied into a command line, nothing run.
/// Local features never depend on this screen or on the server being reachable.
struct ConnectedDevicesView: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        if let link = model.deviceLink {
            ConnectedDevicesScreen(link: link)
        } else {
            HCGEmptyState(
                "Connected Devices Unavailable", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("This build has no Keychain identity or pinned network transport, so HCG Device Link is not offered. Local features are unaffected.")
            )
            .background { HCGBackdrop() }
            .navigationTitle("Connected Devices")
        }
    }
}

struct ConnectedDevicesScreen: View {
    let link: DeviceLinkController
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var invitationCode = ""
    @State private var confirmRemove = false
    @State private var confirmForget = false
    @State private var confirmSignOut = false
    @State private var viewing: LinkMessageHeader?

    var body: some View {
        List {
            Group {
                accountSection
                thisDeviceSection
                connectionSection
                if showsPairSection { pairSection }
                if link.state.isLinked {
                    devicesSection
                    inboxSection
                    approvalsSection
                }
                if link.pairing != nil { removalSection }
            }
            .hcgRows()
        }
        .navigationTitle("Connected Devices")
        .hcgScreenBackground()
        // Syncs only while this screen is visible and the app is in the foreground.
        .task { await link.activate() }
        .onDisappear { link.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await link.activate() }
            } else {
                link.deactivate()
            }
        }
        .refreshable { await link.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if link.isBusy {
                    ProgressView()
                } else if link.isSyncing {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(HCGPalette.muted)
                        .accessibilityLabel("Syncing while this screen is open")
                }
            }
        }
        .sheet(item: $viewing) { header in
            NavigationStack { SharedReportView(link: link, header: header) }
                .environment(model)
                .environment(\.hcgAppearance, model.appearance)
        }
        .confirmationDialog("Remove this device from the server?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from Server", role: .destructive) { Task { await link.unregister() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("HCG Server stops accepting this device at once and deletes reports queued for it. This device's key is then deleted; pairing again needs a new invitation.")
        }
        .confirmationDialog("Forget the pairing on this device only?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) { link.forgetLocally() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is sent. The server keeps listing this device until its owner revokes it. Use this when the server is gone.")
        }
        .confirmationDialog("Sign out of HCG Connect?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await link.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Syncing stops. The pairing is kept; sign in with the same account to continue.")
        }
    }

    private var showsPairSection: Bool {
        switch link.state {
        case .notPaired, .signedOut, .removed: link.environment.connect.configuration != nil
        default: false
        }
    }

    // MARK: HCG Connect

    private var accountSection: some View {
        Section {
            switch link.environment.connect {
            case .notConfigured(let reason):
                Label {
                    Text(verbatim: reason).foregroundStyle(HCGPalette.textSecondary)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(HCGPalette.muted)
                }
            case .ready:
                if let account = link.account {
                    LabeledContent("Signed in as", value: account.email ?? "HCG account")
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } else {
                    Text("Sign in with your HCG account. HCG Server checks with HCG that you may use connected devices on every request.")
                        .font(.footnote)
                        .foregroundStyle(HCGPalette.textSecondary)
                    Button { Task { await signIn() } } label: {
                        Label("Sign In with HCG Connect", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.hcgProminent)
                    .disabled(link.isBusy || !link.hasLoaded)
                }
            }
        } header: { Text("HCG Connect account") }
    }

    private func signIn() async {
        do {
            let attempt = try link.beginSignIn()
            guard let scheme = URL(string: attempt.redirectUri)?.scheme else {
                link.notice = "The HCG Connect redirect address has no URL scheme."
                return
            }
            let callback = try await webAuthenticationSession.authenticate(using: attempt.url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            await link.completeSignIn(attempt, callback: callback)
        } catch let error as HCGConnectError {
            link.notice = error.description
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            link.notice = HCGConnectError.cancelled.description
        } catch {
            link.notice = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: This device

    private var thisDeviceSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "iphone").foregroundStyle(HCGPalette.accentPrimary).frame(width: 24).accessibilityHidden(true)
                Text(verbatim: link.environment.describeDevice().name).font(.headline).foregroundStyle(HCGPalette.textPrimary)
                Spacer(minLength: 8)
                DeviceRoleBadge(role: .local)
            }
            LabeledContent("App", value: "HCG Terminal \(link.environment.variant.displayName) \(link.environment.appVersion)")
            if let identity = link.identity {
                LabeledContent("Installation", value: identity.shortInstallationId)
                FingerprintRow(title: "Key fingerprint", fingerprint: identity.fingerprint)
                LabeledContent("Key", value: identity.keyKindLabel)
            } else if let problem = link.identityProblem {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            } else {
                Text("The installation key is created when this screen first opens.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Advertised capabilities").font(.subheadline.weight(.semibold))
                LinkCapabilityChips(capabilities: link.advertisedCapabilities)
            }
        } header: { Text("This device") } footer: {
            Text("Capabilities come only from this app's own checks on this device and your Capabilities & Access switches. They are information for other devices: the server cannot change them, and nothing it sends unlocks anything here.")
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: link.state.title).font(.headline).foregroundStyle(HCGPalette.textPrimary)
                    Text(verbatim: link.state.detail).font(.footnote).foregroundStyle(HCGPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if case .pairing(let progress) = link.state {
                Text("Compare these with the request shown in HCG Server before it is approved.")
                    .font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                FingerprintRow(title: "Server key (\(progress.serverName))", fingerprint: progress.serverFingerprint)
                FingerprintRow(title: "This device's key", fingerprint: progress.deviceFingerprint)
            }
            if let pairing = link.pairing {
                LabeledContent("Server", value: pairing.serverName)
                LabeledContent("Address", value: pairing.serverAddress)
            }
            if let last = link.lastSync {
                LabeledContent("Last sync", value: LinkFormatting.relative(last))
            }
            if let notice = link.notice {
                Text(verbatim: notice).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
        } header: { Text("Connection") }
    }

    private var statusSymbol: String {
        switch link.state {
        case .connected: "checkmark.circle"
        case .offline: "wifi.exclamationmark"
        case .pairing: "hourglass"
        case .removed, .signInEnded: "xmark.octagon"
        case .notConfigured: "slash.circle"
        case .signedOut, .notPaired: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch link.state {
        case .connected: HCGPalette.ok
        case .offline, .pairing: HCGPalette.warn
        case .removed, .signInEnded: HCGPalette.loss
        case .notConfigured, .signedOut, .notPaired: HCGPalette.muted
        }
    }

    // MARK: Pairing

    private var pairSection: some View {
        Section {
            TextField("hcg1-…", text: $invitationCode, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...4)
                .accessibilityLabel("Invitation code")
            if !invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch link.previewInvitation(invitationCode) {
                case .success(let invitation):
                    LabeledContent("Server", value: invitation.hostName)
                    LabeledContent("Address", value: invitation.hostAddress)
                    FingerprintRow(title: "Server key", fingerprint: invitation.fingerprint)
                    if let identity = link.identity {
                        FingerprintRow(title: "This device's key", fingerprint: identity.fingerprint)
                    }
                    Button {
                        Task {
                            await link.pair(code: invitationCode)
                            if case .pairing = link.state { invitationCode = "" }
                        }
                    } label: {
                        Label("Send Pairing Request", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.hcgProminent)
                    .disabled(!link.canPair || link.isBusy)
                    if !link.signedIn {
                        Text("Sign in with HCG Connect first.").font(.footnote).foregroundStyle(HCGPalette.warn)
                    }
                case .failure(let problem):
                    Text(verbatim: problem.description).font(.footnote).foregroundStyle(HCGPalette.warn)
                }
            }
        } header: { Text("Pair with HCG Server") } footer: {
            Text("Create an invitation in HCG Server on your Mac and paste its code here. The connection is pinned to the server key in the code. The server's owner approves this device after comparing its key fingerprint.")
        }
    }

    // MARK: Paired devices

    private var devicesSection: some View {
        Section {
            if let devices = link.devices {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").foregroundStyle(HCGPalette.silver).frame(width: 24).accessibilityHidden(true)
                    Text(verbatim: devices.host.name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    DeviceRoleBadge(role: .server)
                }
                .accessibilityElement(children: .combine)
            }
            if link.remoteDevices.isEmpty {
                Text(link.devices == nil ? "Not loaded yet." : "No other device is paired with this server yet.")
                    .font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
            ForEach(link.remoteDevices) { device in
                RemoteDeviceRow(device: device)
            }
            if let problem = link.sectionProblems[.devices] {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            }
        } header: { Text("Paired devices") } footer: {
            Text("Presence is computed by HCG Server from when it last heard from each device. Capabilities are what each device says about itself.")
        }
    }

    // MARK: Shared reports

    private var inboxSection: some View {
        Section {
            if link.inbox.isEmpty {
                Text("No shared reports.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
            ForEach(link.inbox) { message in
                Button { viewing = message } label: { InboxRow(message: message) }
                    .buttonStyle(.plain)
            }
            if let problem = link.sectionProblems[.inbox] {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            }
        } header: { Text("Shared reports") } footer: {
            Text("A shared report is data. It is shown as plain text; nothing in it is ever run, opened as a link or passed to a command.")
        }
    }

    // MARK: Approvals

    private var approvalsSection: some View {
        Section {
            if let approvals = link.approvals {
                Text(verbatim: approvals.note).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                if approvals.approvals.isEmpty {
                    Text("No pending approvals.").font(.footnote)
                }
                ForEach(Array(approvals.approvals.enumerated()), id: \.offset) { _, approval in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: approval.action.type).font(.subheadline.weight(.semibold))
                        Text(verbatim: "From \(approval.origin.name) · \(approval.approval.state)").font(.caption).foregroundStyle(HCGPalette.textSecondary)
                    }
                }
            } else if link.sectionProblems[.approvals] == nil {
                Text("Not loaded yet.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
            }
            if let problem = link.sectionProblems[.approvals] {
                Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
            }
            Label("Action execution is disabled. Nothing another device sends can run on this device.", systemImage: "hand.raised")
                .font(.footnote)
                .foregroundStyle(HCGPalette.textSecondary)
        } header: { Text("Pending approvals") }
    }

    // MARK: Removal

    private var removalSection: some View {
        Section {
            if link.pairing?.status != .removed {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Remove This Device from the Server", systemImage: "minus.circle")
                }
                .disabled(link.isBusy)
            }
            Button(role: .destructive) { confirmForget = true } label: {
                Label("Forget Pairing on This Device Only", systemImage: "trash")
            }
            .disabled(link.isBusy)
        } footer: {
            Text("Removal cannot be undone; pairing again needs a new invitation.")
        }
    }
}

// MARK: - Shared report viewer

/// A report from another device, rendered from `ReportTextRenderer.sections` as plain text only.
struct SharedReportView: View {
    let link: DeviceLinkController
    let header: LinkMessageHeader
    @Environment(\.dismiss) private var dismiss
    @State private var opened: OpenedLinkReport?
    @State private var problem: String?

    var body: some View {
        List {
            Group {
                Section {
                    Label {
                        Text(verbatim: "Report from \(header.from.name) (remote) — data only, never executed")
                            .font(.headline)
                            .foregroundStyle(HCGPalette.textPrimary)
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(HCGPalette.warn)
                    }
                    Text(verbatim: "\(LinkAppNames.display(header.from.app)) · received \(LinkFormatting.relative(header.queuedAt))")
                        .font(.caption)
                        .foregroundStyle(HCGPalette.textSecondary)
                }
                if let opened {
                    ForEach(Array(opened.sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(.callout)
                                    .foregroundStyle(HCGPalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } header: {
                            Text(verbatim: section.title).textCase(nil)
                        }
                    }
                } else if let problem {
                    Text(verbatim: problem).font(.footnote).foregroundStyle(HCGPalette.warn)
                } else {
                    ProgressView()
                }
            }
            .hcgRows()
        }
        .navigationTitle("Shared Report")
        .navigationBarTitleDisplayMode(.inline)
        .hcgScreenBackground()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task {
            do {
                opened = try await link.openReport(header)
                await link.markOpened(header.messageId)
            } catch let error as DeviceLinkError {
                problem = error.description
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Components

enum DeviceRole {
    case local, remote, server

    var label: String {
        switch self {
        case .local: "LOCAL"
        case .remote: "REMOTE"
        case .server: "SERVER"
        }
    }

    var symbol: String {
        switch self {
        case .local: "iphone"
        case .remote: "antenna.radiowaves.left.and.right"
        case .server: "desktopcomputer"
        }
    }

    var color: Color {
        switch self {
        case .local: HCGPalette.accentPrimary
        case .remote: HCGPalette.accentSecondary
        case .server: HCGPalette.silver
        }
    }
}

/// LOCAL / REMOTE / SERVER pill, in the style of `TargetBadge`.
struct DeviceRoleBadge: View {
    let role: DeviceRole

    var body: some View {
        Label(role.label, systemImage: role.symbol)
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(role.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(role.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(role.color.opacity(0.35), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(role.label.capitalized)
    }
}

/// A key fingerprint in groups of four, monospaced, for comparing by eye.
struct FingerprintRow: View {
    let title: String
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            Text(verbatim: LinkCrypto.displayFingerprint(fingerprint))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(HCGPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Capability chips: icon and text for each state (color is never the only signal).
struct LinkCapabilityChips: View {
    let capabilities: [LinkCapability]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 150), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(capabilities, id: \.id) { capability in
                LinkCapabilityChip(capability: capability)
            }
        }
    }
}

struct LinkCapabilityChip: View {
    let capability: LinkCapability

    var body: some View {
        Label {
            Text(verbatim: "\(LinkCapabilityNames.title(capability.id)) · \(LinkCapabilityNames.state(capability.state))")
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(LinkCapabilityNames.title(capability.id)): \(LinkCapabilityNames.state(capability.state))\(capability.reason.map { ", \($0)" } ?? "")"))
    }

    private var symbol: String {
        switch capability.state {
        case .verified: "checkmark.seal"
        case .available: "checkmark.circle"
        case .unavailable: "minus.circle"
        case .disabled: "pause.circle"
        }
    }

    private var color: Color {
        switch capability.state {
        case .verified: HCGPalette.ok
        case .available: HCGPalette.cyan
        case .unavailable, .disabled: HCGPalette.muted
        }
    }
}

/// One paired device (always another installation, marked REMOTE).
struct RemoteDeviceRow: View {
    let device: LinkInstallation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").foregroundStyle(HCGPalette.accentSecondary).frame(width: 24).accessibilityHidden(true)
                Text(verbatim: device.name).font(.subheadline.weight(.semibold)).foregroundStyle(HCGPalette.textPrimary).lineLimit(2)
                Spacer(minLength: 8)
                DeviceRoleBadge(role: .remote)
            }
            Text(verbatim: appLine).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            HStack(spacing: 6) {
                Image(systemName: device.state == .online ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(device.state == .online ? HCGPalette.ok : HCGPalette.muted)
                    .accessibilityHidden(true)
                Text(verbatim: presenceLine).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
            if !device.capabilities.isEmpty {
                LinkCapabilityChips(capabilities: device.capabilities)
            }
        }
        .padding(.vertical, 4)
    }

    private var appLine: String {
        var parts = [LinkAppNames.display(device.app) + " " + device.appVersion]
        if let variant = LinkAppNames.variant(device.variant) { parts.append(variant) }
        parts.append(device.platform)
        return parts.joined(separator: " · ")
    }

    private var presenceLine: String {
        let state = LinkPresenceText.label(device.state)
        guard let seen = device.lastSeenAt, device.state != .neverSeen else { return state }
        return "\(state) · last seen \(LinkFormatting.relative(seen))"
    }
}

struct InboxRow: View {
    let message: LinkMessageHeader

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.status == "opened" ? "doc.text" : "doc.badge.clock")
                .foregroundStyle(message.status == "opened" ? HCGPalette.muted : HCGPalette.accentPrimary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: message.title).font(.subheadline.weight(.semibold)).foregroundStyle(HCGPalette.textPrimary).lineLimit(2)
                Text(verbatim: "From \(message.from.name) · \(LinkAppNames.display(message.from.app))")
                    .font(.caption).foregroundStyle(HCGPalette.textSecondary).lineLimit(1)
                Text(verbatim: "\(LinkFormatting.relative(message.queuedAt)) · \(message.status.capitalized)")
                    .font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(HCGPalette.muted).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the report as plain text")
    }
}

enum LinkFormatting {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
#endif
