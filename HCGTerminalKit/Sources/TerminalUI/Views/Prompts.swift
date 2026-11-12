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
/// Shown instead of switching when a mode cannot run. The current mode and sessions are kept.
struct ModeUnavailableSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let explanation: ModeUnavailableExplanation

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(CapabilityReport.unleashedUnavailableMessage)
                    Text("You are still in \(model.preferredMode.displayName). Your open sessions are unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if explanation.distribution == .standard {
                    Section("Why") {
                        Text(UnleashedNotIncludedCapabilityProvider.reason)
                        Text("The Unleashed backend ships only in the separate HCG Terminal Unleashed build (bundle ID ending in .unleashed). See Diagnostics → Build for what is installed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("What is missing") {
                        ForEach(explanation.report.blockers.filter { $0.kind != .remoteSSH && $0.kind != .buildOrchestration }) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(result.kind.title).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    AvailabilityPill(availability: result.availability)
                                }
                                Text(result.availability.reason).font(.footnote)
                                if let remedy = result.availability.remedy {
                                    Text(remedy).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    NavigationLink("All checks and results") {
                        List { CapabilityReportView(report: explanation.report) }
                            .navigationTitle("\(explanation.mode.displayName) checks")
                    }
                }
            }
            .navigationTitle("\(explanation.mode.displayName) is not available")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Keep \(model.preferredMode.displayName)") { dismiss() }
                }
            }
        }
    }
}
#endif
