#if canImport(UIKit) && canImport(SwiftUI)
import DeveloperWorkspace
import SwiftUI
import TerminalCore
import UIKit

// HCG Nexus handoff (docs/NEXUS-HANDOFF.md): the sheet a `connection` link opens, the
// non-blocking notice banner, and "Copy Link for HCG Nexus".

/// Shows a saved connection that HCG Nexus asked for. Nothing connects until the user taps
/// Connect; nothing runs and no session starts on its own.
struct NexusHandoffSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile

    /// The saved profile as it is now (the one the link resolved may be older).
    private var current: HostProfile { model.hosts.first { $0.id == host.id } ?? host }

    var body: some View {
        List {
            Group {
                Section {
                    LabeledContent("Name", value: current.name)
                    LabeledContent("Address", value: current.endpoint.address)
                } header: { Text("Saved connection") } footer: {
                    Text("Opened from HCG Nexus. Nothing has connected and nothing has run. Tap Connect to open a shell on \(current.name).")
                }
                Section {
                    Button { connect() } label: { Label("Connect", systemImage: "terminal") }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    /// Runs only from the user's tap on Connect.
    private func connect() {
        let host = current
        model.handoffConnection = nil
        Task { await model.openRemoteShell(host) }
    }
}

/// A dismissible notice at the top of the window. It does not block, and goes away by itself.
struct HandoffNoticeBanner: View {
    let notice: HandoffNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.kind == .warning ? "exclamationmark.triangle" : "info.circle")
            Text(notice.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(notice.kind == .info ? HCGPalette.silver : HCGPalette.warn)
        .padding(.leading, 12)
        .background(HCGPalette.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HCGPalette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Shows the model's handoff notice over the content for a few seconds.
struct HandoffNoticeOverlay: ViewModifier {
    let model: TerminalAppModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = model.handoffNotice {
                HandoffNoticeBanner(notice: notice) { model.handoffNotice = nil }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(6))
                        if model.handoffNotice?.id == notice.id { model.handoffNotice = nil }
                    }
            }
        }
    }
}

extension View {
    func handoffNoticeOverlay(_ model: TerminalAppModel) -> some View { modifier(HandoffNoticeOverlay(model: model)) }
}

/// "Copy Link for HCG Nexus": the link holds only the saved connection's ID.
@MainActor
func copyNexusLink(for host: HostProfile, model: TerminalAppModel) {
    UIPasteboard.general.string = model.nexusLink(for: host)
    model.handoffNotice = HandoffNotice("Link for HCG Nexus copied. It contains only this connection's ID.")
}
#endif
