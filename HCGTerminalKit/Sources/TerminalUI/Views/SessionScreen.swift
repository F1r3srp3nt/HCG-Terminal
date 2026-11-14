#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// A terminal session: a compact header (name, real state, mode, actions), notices and the
/// terminal. The terminal surface is opaque and undecorated; the background and frame stay
/// outside the text area, and no ambient motion runs on this screen.
struct SessionScreen: View {
    @Environment(TerminalAppModel.self) private var model
    let session: SessionModel
    /// Back to the session list (iPhone, where the navigation bar is hidden on this screen).
    var onBack: (() -> Void)?
    @State private var showDetails = false
    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session, showDetails: $showDetails, confirmClose: $confirmClose, onBack: onBack)
                // The header always gets its full height; the terminal takes what is left.
                // Without this, large text was squeezed and wrapped lines overlapped.
                .fixedSize(horizontal: false, vertical: true)
            ForEach(session.notices, id: \.self) { notice in
                NoticeBanner(notice: notice) { session.dismissNotice(notice) }
            }
            if !session.isLive, !session.target.isLocal {
                EndedRemoteSessionBanner(session: session)
            }
            TerminalFrame(accent: ModeAccent.color(session.target)) {
                TerminalHostView(session: session, accent: ModeAccent.color(session.target), fontSize: CGFloat(model.appearance.terminalFontSize))
                    .id(session.id)
            }
        }
        .background { HCGBackdrop(terminalInUse: true) }
        .sheet(isPresented: $showDetails) {
            NavigationStack { SessionDetailsView(session: session) }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Close this session?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Session", role: .destructive) { Task { await model.closeSession(session.id) } }
        } message: {
            Text(session.target.isLocal
                ? "Anything running in this local session stops."
                : "Only this session's channel closes. The SSH connection and other sessions stay open.")
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Compact header: one row with the session name (full name for VoiceOver), its target badge
/// and the stop / information / close controls; one row with the compact mode selector and a
/// short summary of the real state that expands into the capability details.
struct SessionHeader: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: SessionModel
    @Binding var showDetails: Bool
    @Binding var confirmClose: Bool
    var onBack: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Row 1: the name gets all the room the controls leave. Two lines at accessibility
            // text sizes; VoiceOver always reads the full name.
            HStack(spacing: 2) {
                if let onBack {
                    HeaderIconButton(systemImage: "chevron.left", label: "Back to sessions", action: onBack)
                }
                Text(session.title)
                    .font(.headline)
                    .foregroundStyle(HCGPalette.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, onBack == nil ? 6 : 0)
                    .accessibilityLabel("Session: \(session.title)")
                    .accessibilityAddTraits(.isHeader)
                HeaderIconButton(systemImage: "stop.circle", label: "Interrupt (Control-C)") { session.interrupt() }
                    .disabled(!session.isLive)
                HeaderIconButton(systemImage: "info.circle", label: "Session details") { showDetails = true }
                HeaderIconButton(systemImage: "xmark", label: "Close session") { confirmClose = true }
            }
            // Row 2 (and 3): local mode selector, this session's target, and the summary.
            if sizeClass == .regular && !typeSize.isAccessibilitySize {
                HStack(spacing: 10) {
                    selector.fixedSize()
                    TargetBadge(target: session.target, compact: true).fixedSize()
                    summary
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            } else if typeSize.isAccessibilitySize {
                // Accessibility text sizes: one item per row, nothing truncated.
                VStack(alignment: .leading, spacing: 6) {
                    selector
                    TargetBadge(target: session.target, compact: true)
                    summary
                }
                .padding(.horizontal, 6)
            } else {
                HStack(spacing: 10) {
                    selector
                    TargetBadge(target: session.target, compact: true).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                summary.padding(.horizontal, 6)
            }
            if expanded { details.padding(.horizontal, 6).padding(.top, 2) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(HCGPalette.surfaceDeep.opacity(appearance.style == .eventHorizon ? 0.92 : 1))
        .overlay(alignment: .bottom) { Rectangle().fill(HCGPalette.border).frame(height: 1) }
    }

    private var selector: some View {
        ModeSelector(selection: model.preferredMode, compact: true, availability: availability) { mode in
            model.selectMode(mode)
        }
    }

    private var tone: SessionHeaderSummary.Tone { SessionHeaderSummary.tone(session.state) }

    private var toneColor: Color {
        switch tone {
        case .live: HCGPalette.ok
        case .pending: HCGPalette.accentPrimary
        case .ended: HCGPalette.warn
        }
    }

    private var note: String? {
        SessionHeaderSummary.modeNote(preferred: model.preferredMode, available: availability(model.preferredMode), target: session.target)
    }

    private var summary: some View {
        Button {
            withAnimation(reduceMotion || appearance.reducedEffects ? nil : .snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tone.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(toneColor)
                Text(SessionHeaderSummary.line(state: session.state, target: session.target))
                    .font(.caption)
                    .foregroundStyle(HCGPalette.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                    .multilineTextAlignment(.leading)
                if let note {
                    Label(note, systemImage: availability(model.preferredMode) == false ? "lock.fill" : "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(availability(model.preferredMode) == false ? HCGPalette.warn : HCGPalette.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .layoutPriority(1)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HCGPalette.textSecondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionHeaderSummary.accessibilityText(state: session.state, target: session.target, note: note))
        .accessibilityValue(expanded ? "Details shown" : "Details hidden")
        .accessibilityHint("Shows the backend and capability details")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(session.backend.label, systemImage: "cpu")
                .font(.footnote)
                .foregroundStyle(HCGPalette.textSecondary)
            ModeStatusLine(mode: model.preferredMode, available: availability(model.preferredMode))
            Button { showDetails = true } label: {
                Label("Session details", systemImage: "info.circle").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func availability(_ mode: ExecutionMode) -> Bool? {
        model.report(for: mode).map { _ in model.isAvailable(mode) }
    }
}

/// Shown when a remote session has ended. Reconnecting opens a fresh shell; a command
/// session (e.g. Claude Code) runs again only when the user taps Run Again. Builds are never
/// rerun from here.
struct EndedRemoteSessionBanner: View {
    @Environment(TerminalAppModel.self) private var model
    let session: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.state.label).font(.footnote.weight(.semibold))
                Text("Scrollback is kept. Nothing is re-run automatically.").font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
            Spacer()
            if case .sshCommand = session.backend {
                Button("Run Again") { Task { await model.runAgain(session) } }.buttonStyle(.bordered)
            }
            Button("Reconnect") { Task { await model.reconnect(session) } }.buttonStyle(.hcgProminent)
        }
        .foregroundStyle(HCGPalette.silver)
        .padding(10)
        .background(HCGPalette.surfaceElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(HCGPalette.border).frame(height: 1) }
    }
}

struct NoticeBanner: View {
    let notice: TerminalNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.kind == .error ? "exclamationmark.octagon" : notice.kind == .warning ? "exclamationmark.triangle" : "info.circle")
            Text(notice.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(notice.kind == .info ? HCGPalette.silver : HCGPalette.warn)
        .padding(10)
        .background(HCGPalette.surfaceElevated)
        .overlay(alignment: .leading) { Rectangle().fill(notice.kind == .info ? HCGPalette.accentPrimary : HCGPalette.warn).frame(width: 2) }
    }
}

/// Session details: target, backend, the session's mode and the current preferred mode.
struct SessionDetailsView: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionModel

    var body: some View {
        List {
            Group {
                Section("Execution") {
                    LabeledContent("Target", value: session.target.label)
                    LabeledContent("Where", value: session.target.detail)
                    LabeledContent("Backend", value: session.backend.label)
                    LabeledContent("Session mode", value: sessionMode)
                    LabeledContent("Active local mode", value: model.preferredMode.displayName)
                }
                Section("State") {
                    LabeledContent("Status", value: session.state.label)
                    LabeledContent("Opened", value: session.createdAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Last activity", value: session.lastActivity.formatted(date: .omitted, time: .standard))
                    if let directory = session.workingDirectory { LabeledContent("Directory", value: directory) }
                    LabeledContent("Session ID", value: session.id.description)
                }
                Section {
                    Text(explanation).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .navigationTitle("Session Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var sessionMode: String {
        switch session.target {
        case .local(let mode): mode.displayName
        case .remote: "Remote (independent of local mode)"
        }
    }

    private var explanation: String {
        switch session.target {
        case .local(let mode) where mode != model.preferredMode:
            "This session keeps running in \(mode.displayName). Changing the local mode only affects new sessions unless you confirm moving this one, which starts a fresh session; nothing running is transferred."
        case .local:
            "Commands typed here run on this device in the environment shown above. They are never sent to a remote host."
        case .remote:
            "Commands typed here run on the remote host. Switching the local mode never interrupts this session."
        }
    }
}

/// Capability status for one mode: banner plus one row per capability. Each row shows its
/// summary once, the reason for its state only when it adds something, exactly where it
/// applies, every check with its return value, errno and time, and what would change the state.
struct CapabilityReportView: View {
    let report: CapabilityReport

    var body: some View {
        Section {
            Text(report.bannerText)
                .font(.subheadline)
                .foregroundStyle(report.level == .available ? ModeAccent.color(report.mode) : report.level == .partial ? HCGPalette.cyan : HCGPalette.warn)
            ForEach(report.results) { result in
                CapabilityRow(result: result)
            }
            ForEach(report.buildNotes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
        } header: {
            Text("\(report.mode.displayName) capabilities")
        } footer: {
            Text("Checked \(report.generatedAt.formatted(date: .omitted, time: .standard)). Checks are read-only and never request privileges. “Verified working” means it was actually used successfully on this device; “partial” means only where listed.")
        }
    }
}

struct CapabilityRow: View {
    let result: CapabilityResult

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.summary).font(.footnote)
                if let detail = result.detail {
                    Text(detail).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                }
                if !result.scope.isEmpty {
                    Text("\(result.partial ? "Only in" : "Applies to"): \(result.scope.joined(separator: ", "))").font(.caption).foregroundStyle(HCGPalette.textSecondary)
                }
                if result.requiresAuthorization {
                    Label("Each use needs your explicit approval.", systemImage: "hand.raised").font(.caption).foregroundStyle(HCGPalette.warn)
                }
                if let remedy = result.availability.remedy {
                    Label(remedy, systemImage: "lightbulb").font(.caption).foregroundStyle(HCGPalette.textSecondary)
                }
                if !result.evidence.isEmpty {
                    Text("Checks").font(.caption.weight(.semibold)).padding(.top, 2)
                    ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, check in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: check.positive ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(check.positive ? HCGPalette.ok : HCGPalette.muted)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.probe).font(.caption.monospaced()).textSelection(.enabled)
                                Text(check.observation).font(.caption).foregroundStyle(HCGPalette.textSecondary)
                                if let time = check.timestamp {
                                    Text(time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } label: {
            HStack {
                Label(result.kind.title, systemImage: result.kind.symbolName)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    StatusChip(availability: result.availability)
                    if result.partial && result.availability.isUsable {
                        Text("partial").font(.caption2.weight(.semibold)).foregroundStyle(HCGPalette.warn)
                    }
                }
            }
        }
    }
}

struct AvailabilityPill: View {
    let availability: CapabilityAvailability
    var body: some View { StatusChip(availability: availability) }
}
#endif
