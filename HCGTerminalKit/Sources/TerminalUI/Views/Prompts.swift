#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity

/// Explicit approval for one privileged action. "Don't Run" is the default.
struct AuthorizationSheet: View {
    @Environment(TerminalAppModel.self) private var model
    let request: AuthorizationRequest

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.commandLine)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } header: { Text("Command") }
                Section("Runs on") {
                    TargetBadge(target: request.target)
                    Text("With the permissions this device actually grants. HCG Terminal does not add sudo, does not supply passwords and does not change security settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !request.reasons.isEmpty {
                    Section("Why approval is needed") {
                        ForEach(request.reasons, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't Run") { model.answerAuthorization(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run Once", role: .destructive) { model.answerAuthorization(true) }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// First connection to a host: the user compares the fingerprint before trusting it.
struct HostKeySheet: View {
    @Environment(TerminalAppModel.self) private var model
    let prompt: HostKeyPrompt

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Host", value: prompt.port == 22 ? prompt.host : "\(prompt.host):\(prompt.port)")
                    LabeledContent("Key type", value: prompt.key.algorithm)
                    Text(prompt.key.fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } footer: {
                    Text("Compare with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the host (on a Mac: same path). Trust it only if they match. If this key changes later, HCG Terminal refuses to connect.")
                }
            }
            .navigationTitle("Unknown Host Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.answerHostKey(false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Trust and Connect") { model.answerHostKey(true) } }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// Offer shown after changing mode while local sessions are open. Keeping them is the default.
struct ModeSwitchConfirmationSheet: View {
    @Environment(TerminalAppModel.self) private var model
    let confirmation: ModeSwitchConfirmation
    @State private var selected: Set<SessionID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("New local sessions now open in \(confirmation.plan.to.displayName). Your open local sessions keep running in \(confirmation.plan.from.displayName) unless you choose to restart them.")
                }
                Section {
                    ForEach(confirmation.plan.localSessions, id: \.session.id) { entry in
                        row(entry)
                    }
                } header: { Text("Local sessions") } footer: {
                    Text("Restarting closes the session and opens a fresh one in \(confirmation.plan.to.displayName). No command, input or process is transferred.")
                }
                if !confirmation.plan.preservedRemoteSessions.isEmpty {
                    Section("Remote sessions") {
                        ForEach(confirmation.plan.preservedRemoteSessions, id: \.id) { session in
                            Label("\(session.title) — not affected", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Switched to \(confirmation.plan.to.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Sessions") { Task { await model.resolveModeSwitch(.keepCurrentEnvironment) } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restart \(selected.count)") { Task { await model.resolveModeSwitch(.moveConfirmed(selected)) } }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func row(_ entry: ModeSwitchPlan.LocalEntry) -> some View {
        switch entry.disposition {
        case .movableWithConfirmation:
            Toggle(isOn: Binding(
                get: { selected.contains(entry.session.id) },
                set: { on in if on { selected.insert(entry.session.id) } else { selected.remove(entry.session.id) } }
            )) {
                VStack(alignment: .leading) {
                    Text(entry.session.title)
                    Text("Restart in \(confirmation.plan.to.displayName)").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .alreadyInTargetMode:
            Label("\(entry.session.title) — already \(confirmation.plan.to.displayName)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .mustStay(let reason):
            VStack(alignment: .leading) {
                Text(entry.session.title)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
/// Shown instead of switching when a mode cannot open a local session. The current mode and
/// sessions are kept. Says what works, what blocks the rest, and offers the relevant actions.
struct ModeUnavailableSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let explanation: ModeUnavailableExplanation
    @State private var showConnection = false

    /// The live report (it changes after Recheck or a test), falling back to the snapshot.
    private var report: CapabilityReport { model.report(for: explanation.mode) ?? explanation.report }
    private var local: [CapabilityResult] { report.results.filter(\.kind.isLocal) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(report.bannerText, systemImage: report.level == .available ? "checkmark.circle" : report.level == .partial ? "circle.lefthalf.filled" : "exclamationmark.triangle")
                        .foregroundStyle(report.level == .unavailable ? HCGPalette.warn : HCGPalette.cyan)
                    Text("You are still in \(model.preferredMode.displayName). Your open sessions are unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.isAvailable(explanation.mode), model.preferredMode != explanation.mode {
                        Button("Switch to \(explanation.mode.displayName)") { dismiss(); model.selectMode(explanation.mode) }
                    }
                }
                if explanation.distribution == .standard {
                    Section("Why") {
                        Text(UnleashedNotIncludedCapabilityProvider.reason)
                        Text("The Unleashed backend ships only in the separate HCG Terminal Unleashed build (bundle ID ending in .unleashed). See Diagnostics → Build for what is installed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    actions
                    let working = local.filter(\.availability.isUsable)
                    if !working.isEmpty {
                        Section("Working") {
                            ForEach(working) { result in resultRow(result) }
                        }
                    }
                    Section("Not working") {
                        ForEach(local.filter { !$0.availability.isUsable }) { result in resultRow(result) }
                    }
                }
                Section {
                    NavigationLink("All checks and results") {
                        List { CapabilityReportView(report: report) }
                            .hcgScreenBackground()
                            .navigationTitle("\(explanation.mode.displayName) checks")
                    }
                }
            }
            .hcgScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Keep \(model.preferredMode.displayName)") { dismiss() }
                }
            }
            .sheet(isPresented: $showConnection) {
                NavigationStack { LoopbackServiceSheet() }.environment(model)
            }
        }
    }

    /// Follows the live report: after Recheck or a successful test it may no longer be "not available".
    private var title: String {
        switch report.level {
        case .available: "\(explanation.mode.displayName) checks"
        case .partial: "\(explanation.mode.displayName) partially available"
        case .unavailable: "\(explanation.mode.displayName) is not available"
        }
    }

    private var actions: some View {
        Section {
            Button {
                Task { await model.recheckUnleashed() }
            } label: { Label("Recheck", systemImage: "arrow.clockwise") }
            .disabled(model.isDetecting)

            Button {
                Task { await model.testLocalShell() }
            } label: {
                HStack {
                    Label("Test local shell", systemImage: "terminal")
                    if model.isTestingShell { Spacer(); ProgressView() }
                }
            }
            .disabled(model.isTestingShell || !model.dependencies.access.isEnabled(.localShell))
            if let test = model.lastShellTest {
                Label(test.outcome, systemImage: test.succeeded ? "checkmark.seal" : "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(test.succeeded ? HCGPalette.ok : HCGPalette.warn)
            }

            Button { showConnection = true } label: {
                Label("Configure connection (localhost SSH)", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(!model.dependencies.access.isEnabled(.localhostSSH))

            NavigationLink { SetupRequirementsView() } label: {
                Label("View setup requirements", systemImage: "list.bullet.clipboard")
            }
            if report.level == .partial {
                NavigationLink { UnleashedToolsView() } label: {
                    Label("Use what works (files, packages)", systemImage: "folder")
                }
            }
        } header: { Text("Actions") } footer: {
            Text("Recheck runs the read-only checks again. Test local shell runs `printf HCG_SHELL_OK; id -u` once, limited to 5 seconds. Nothing else is executed, installed or changed.")
        }
    }

    private func resultRow(_ result: CapabilityResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(result.kind.title, systemImage: result.kind.symbolName).font(.subheadline.weight(.semibold))
                Spacer()
                StatusChip(availability: result.availability)
            }
            if result.partial { Text("Partial: \(result.scope.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            Text(result.availability.reason).font(.footnote).fixedSize(horizontal: false, vertical: true)
            if let remedy = result.availability.remedy, !result.availability.isUsable {
                Text(remedy).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The host presented a different key than before. Nothing was connected. Removing the old
/// key is a separate, explicit step; the next connection then shows the new fingerprint for
/// verification like a first connection.
struct HostKeyChangedSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let notice: HostKeyChangeNotice
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("HCG Terminal refused to connect to \(notice.host.endpoint.address).", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(HCGPalette.loss)
                    Text("Its host key is different from the one you trusted before. This happens after the host's system was reinstalled or its SSH keys were regenerated — or if someone is intercepting the connection.")
                        .font(.footnote)
                }
                Section("Trusted before") {
                    Text(notice.expectedFingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                Section("Presented now") {
                    Text(notice.presentedFingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                Section {
                    Button("Remove Old Key…", role: .destructive) { confirmRemoval = true }
                } footer: {
                    Text("Only if you know why the key changed. On the host, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` shows the current fingerprint. After removal, the next connection asks you to verify it.")
                }
            }
            .navigationTitle("Host Key Changed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Don't Connect") { model.hostKeyChange = nil } }
            }
            .confirmationDialog("Remove the old key for \(notice.host.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove Old Key", role: .destructive) { Task { await model.forgetHostKey(notice) } }
            } message: {
                Text("Nothing connects now. The next connection shows the new fingerprint for you to verify.")
            }
        }
        .interactiveDismissDisabled()
    }
}
#endif
