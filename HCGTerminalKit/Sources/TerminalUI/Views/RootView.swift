#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

enum SidebarItem: Hashable {
    case dashboard
    case session(SessionID)
    case access
    case files
    case hosts
    case builds
    case artifacts
    case unleashedTools
    case preferences
    case diagnostics
}

/// Root of HCG Terminal. Split view on iPad, stack on iPhone (NavigationSplitView adapts).
public struct RootView: View {
    @State private var model: TerminalAppModel
    @State private var selection: SidebarItem? = .dashboard
    @State private var showNewRemote = false
    @State private var showLoopback = false
    @State private var renamingSession: SessionModel?
    @State private var renameTitle = ""

    public init(model: TerminalAppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .environment(model)
        .environment(\.hcgAppearance, model.appearance)
        .tint(ModeAccent.color(model.preferredMode, accent: model.appearance.accent))
        .preferredColorScheme(model.appearance.theme == .dark ? .dark : nil)
        .task {
            await model.bootstrap()
            #if DEBUG
            await runSmokeScenario()
            #endif
        }
        .onChange(of: model.selectedSessionID) { _, id in
            if let id { selection = .session(id) }
        }
        .sheet(item: $model.authorizationPrompt) { prompt in
            AuthorizationSheet(request: prompt.request).environment(model)
        }
        .sheet(item: $model.hostKeyPrompt) { prompt in
            HostKeySheet(prompt: prompt.request).environment(model)
        }
        .sheet(item: $model.hostKeyChange) { notice in
            HostKeyChangedSheet(notice: notice).environment(model)
        }
        .sheet(item: $model.modeUnavailable) { explanation in
            ModeUnavailableSheet(explanation: explanation).environment(model)
        }
        .sheet(item: $model.pendingAccessChange) { request in
            AccessChangeSheet(request: request).environment(model).environment(\.hcgAppearance, model.appearance)
        }
        .sheet(item: $model.modeSwitchConfirmation) { confirmation in
            ModeSwitchConfirmationSheet(confirmation: confirmation).environment(model)
        }
        .sheet(isPresented: $showNewRemote) {
            NavigationStack { HostPickerView { host in
                showNewRemote = false
                Task { await model.openRemoteShell(host) }
            } }
            .environment(model)
        }
        .sheet(isPresented: $showLoopback) {
            NavigationStack { LoopbackServiceSheet() }.environment(model)
        }
        .alert("Rename Session", isPresented: Binding(get: { renamingSession != nil }, set: { if !$0 { renamingSession = nil } })) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                let trimmed = renameTitle.trimmingCharacters(in: .whitespaces)
                if let session = renamingSession, !trimmed.isEmpty { session.title = trimmed }
                renamingSession = nil
            }
            Button("Cancel", role: .cancel) { renamingSession = nil }
        }
        .alert("HCG Terminal", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: SidebarItem.dashboard) {
                    HStack(spacing: 10) {
                        HCGMark(size: 28)
                        Text("Dashboard")
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ModeSelector(selection: model.preferredMode, availability: availability) { model.selectMode($0) }
                    ModeStatusLine(mode: model.preferredMode, available: availability(model.preferredMode))
                }
                .listRowBackground(Color.clear)
            } header: { Eyebrow("Local mode") }

            Section {
                ForEach(model.sessions) { session in
                    NavigationLink(value: SidebarItem.session(session.id)) {
                        SessionRow(session: session)
                    }
                    .contextMenu {
                        Button { renameTitle = session.title; renamingSession = session } label: { Label("Rename…", systemImage: "pencil") }
                        Button(role: .destructive) { Task { await model.closeSession(session.id) } } label: { Label("Close", systemImage: "xmark") }
                    }
                }
                Menu {
                    Button {
                        Task { await model.openLocalSession() }
                    } label: {
                        Label("Local \(model.preferredMode.displayName) Session", systemImage: "iphone")
                    }
                    .disabled(!model.isAvailable(model.preferredMode))
                    if model.dependencies.distribution == .unleashed {
                        Button { showLoopback = true } label: {
                            Label("Connect to Local Terminal Service", systemImage: "network.badge.shield.half.filled")
                        }
                        .disabled(!model.isAvailable(.unleashed))
                    }
                    Button { showNewRemote = true } label: {
                        Label("Remote Host Session", systemImage: "desktopcomputer")
                    }
                    if model.sessions.contains(where: { !$0.isLive }) {
                        Divider()
                        Button(role: .destructive) { Task { await model.closeEndedSessions() } } label: {
                            Label("Close Ended Sessions", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Label("New Session", systemImage: "plus.circle")
                }
            } header: { Eyebrow("Sessions") }

            Section {
                NavigationLink(value: SidebarItem.files) { Label("Files", systemImage: "folder") }
            } header: { Eyebrow("Workspace") }

            Section {
                NavigationLink(value: SidebarItem.hosts) { Label("Hosts & Projects", systemImage: "server.rack") }
                NavigationLink(value: SidebarItem.builds) { Label("Builds & Tests", systemImage: "hammer") }
                NavigationLink(value: SidebarItem.artifacts) { Label("Artifacts", systemImage: "shippingbox") }
            } header: { Eyebrow("Remote development") }

            Section {
                if model.dependencies.distribution == .unleashed {
                    NavigationLink(value: SidebarItem.unleashedTools) { Label("Unleashed Tools", systemImage: "wrench.and.screwdriver") }
                }
                NavigationLink(value: SidebarItem.access) { Label("Capabilities & Access", systemImage: "switch.2") }
                NavigationLink(value: SidebarItem.diagnostics) { Label("Diagnostics", systemImage: "stethoscope") }
                NavigationLink(value: SidebarItem.preferences) { Label("Settings", systemImage: "gearshape") }
            } header: { Eyebrow("Device") }
        }
        .navigationTitle("HCG Terminal")
        .hcgScreenBackground()
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard, nil:
            NavigationStack {
                DashboardView(
                    openSession: { selection = .session($0) },
                    openItem: { selection = $0 },
                    newRemote: { showNewRemote = true }
                )
            }
        case .access: NavigationStack { CapabilitiesAccessView() }
        case .session(let id):
            if let session = model.session(id) {
                SessionScreen(session: session)
            } else {
                emptyState
            }
        case .files: NavigationStack { WorkspaceBrowserView(directory: .root) }
        case .hosts: NavigationStack { HostsView() }
        case .builds: NavigationStack { BuildsView() }
        case .artifacts: NavigationStack { ArtifactsView() }
        case .unleashedTools: NavigationStack { UnleashedToolsView() }
        case .preferences: NavigationStack { PreferencesView() }
        case .diagnostics: NavigationStack { DiagnosticsView() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Session Selected", systemImage: "terminal")
        } description: {
            Text("Open a local \(model.preferredMode.displayName) session or connect to a remote host.")
        } actions: {
            Button("New Local Session") { Task { await model.openLocalSession() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isAvailable(model.preferredMode))
        }
        .background(HCGPalette.canvas)
    }

    private func availability(_ mode: ExecutionMode) -> Bool? {
        model.report(for: mode).map { _ in model.isAvailable(mode) }
    }

    #if DEBUG
    /// CI launch smoke tests only (Debug builds): `-HCGSmokeScenario <name>` drives the real
    /// interface into one state so a screenshot can be taken. Not compiled into Release.
    private func runSmokeScenario() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HCGSmokeScenario"), index + 1 < arguments.count else { return }
        switch arguments[index + 1] {
        case "unleashed-tap":
            model.selectMode(.unleashed)
        case "session":
            if let session = await model.openLocalSession(mode: .vanilla) {
                try? await Task.sleep(nanoseconds: 700_000_000)
                session.send(Array("help\r".utf8))
            }
        case "capabilities": selection = .access
        case "settings": selection = .preferences
        case "dashboard": selection = .dashboard
        case "files": selection = .files
        case "diagnostics": selection = .diagnostics
        case "hosts": selection = .hosts
        default: break
        }
    }
    #endif
}

struct SessionRow: View {
    let session: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ModeAccent.symbol(session.target))
                .foregroundStyle(ModeAccent.color(session.target))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text("\(session.target.label) · \(session.state.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings: mode, Capabilities & Access, appearance, Unleashed environment, build and
/// security. Capability status lives in Capabilities & Access only (no duplicate lists).
struct PreferencesView: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        List {
            Section {
                ModeSelector(selection: model.preferredMode, availability: { mode in
                    model.report(for: mode).map { _ in model.isAvailable(mode) }
                }) { model.selectMode($0) }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ExecutionMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(ModeAccent.color(mode, accent: model.appearance.accent))
                        Text(mode.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Local mode") } footer: {
                Text("Applies to new local sessions. Switching modes never disconnects SSH sessions or stops builds.")
            }

            Section {
                NavigationLink {
                    CapabilitiesAccessView()
                } label: {
                    Label("Capabilities & Access", systemImage: "switch.2")
                }
                let off = AccessControl.allCases.filter { !model.accessSettings.isOn($0) }
                Text(off.isEmpty ? "Everything is allowed that this build and device support." : "Off: " + off.map(\.title).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Access") }

            AppearanceSection()

            if model.dependencies.distribution == .unleashed {
                Section {
                    NavigationLink {
                        UnleashedEnvironmentView()
                    } label: {
                        Label("Unleashed Environment", systemImage: "cpu")
                    }
                } footer: {
                    Text("What was detected in each layer, explicit tests, and a custom bootstrap location.")
                }
            }

            BuildIdentitySection(identity: model.dependencies.buildIdentity)

            Section("Security") {
                NavigationLink("SSH Keys") { KeysView() }
                NavigationLink("Known Hosts") { KnownHostsView() }
            }

            Section {
                Text(model.dependencies.distribution == .standard
                    ? "Standard build for ordinary iOS and iPadOS distribution. It does not contain the Unleashed backend."
                    : "Unleashed build. Distributed separately; not assumed to be eligible for the App Store.")
                Text("HCG Terminal never publishes to TestFlight, App Store Connect or any other channel.")
            } header: { Text("Distribution") }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Settings")
        .hcgScreenBackground()
        .refreshable { await model.refreshCapabilities() }
        .toolbar {
            Button { Task { await model.refreshCapabilities(); await model.refreshAssessment() } } label: {
                if model.isDetecting { ProgressView() } else { Label("Re-check", systemImage: "arrow.clockwise") }
            }
        }
    }
}

/// Theme, accent, effects and terminal text size.
struct AppearanceSection: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        Section {
            Picker("Theme", selection: Binding(get: { model.appearance.theme }, set: { value in model.updateAppearance { $0.theme = value } })) {
                ForEach(AppearanceSettings.Theme.allCases) { Text($0.label).tag($0) }
            }
            Picker("Accent", selection: Binding(get: { model.appearance.accent }, set: { value in model.updateAppearance { $0.accent = value } })) {
                ForEach(AppearanceSettings.Accent.allCases) { accent in
                    Label(accent.label, systemImage: "circle.fill").foregroundStyle(HCGPalette.accent(accent)).tag(accent)
                }
            }
            Toggle("Reduce visual effects", isOn: Binding(get: { model.appearance.reducedEffects }, set: { value in model.updateAppearance { $0.reducedEffects = value } }))
            Stepper(value: Binding(get: { model.appearance.terminalFontSize }, set: { value in model.updateAppearance { $0.terminalFontSize = value } }), in: AppearanceSettings.terminalFontRange, step: 1) {
                LabeledContent("Terminal text", value: "\(Int(model.appearance.terminalFontSize)) pt")
            }
            Text("The quick brown fox · ls -la ~/projects")
                .font(.system(size: model.appearance.terminalFontSize, design: .monospaced))
                .foregroundStyle(HCGPalette.ivory)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HCGPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Terminal text preview")
        } header: { Text("Appearance") } footer: {
            Text("Unleashed always uses violet so the modes stay distinct. Reduce visual effects removes glow, gradients and animation; the system's Reduce Motion and Reduce Transparency are always honored.")
        }
    }
}
#endif
