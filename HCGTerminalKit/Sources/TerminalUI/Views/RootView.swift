#if canImport(UIKit) && canImport(SwiftUI)
import FileWorkspace
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore
import UIKit

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
    /// Nothing selected at launch: iPhone shows the home list (header, mode selector, New
    /// Session); iPad shows the dashboard, which is also the detail for no selection.
    @State private var selection: SidebarItem?
    /// iPhone (compact width) opens on the sidebar: header, mode selector and New Session first.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    /// Read outside the split view: inside it, the sidebar column always reports compact.
    @Environment(\.horizontalSizeClass) private var windowSizeClass
    @State private var showNewRemote = false
    @State private var showLoopback = false
    @State private var renamingSession: SessionModel?
    @State private var renameTitle = ""
    #if DEBUG
    @State private var smokeEditorPath: WorkspacePath?
    @State private var smokeKeyImport = false
    #endif

    public init(model: TerminalAppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
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
            if let id {
                selection = .session(id)
                compactColumn = .detail
            }
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
        #if DEBUG
        .sheet(isPresented: $smokeKeyImport) {
            NavigationStack { KeyImportSheet() }
                .environment(model)
                .environment(\.hcgAppearance, model.appearance)
        }
        .sheet(isPresented: Binding(get: { smokeEditorPath != nil }, set: { if !$0 { smokeEditorPath = nil } })) {
            if let path = smokeEditorPath {
                NavigationStack { TextFileEditor(path: path) }
                    .environment(model)
                    .environment(\.hcgAppearance, model.appearance)
            }
        }
        #endif
    }

    /// On iPhone the header sits at the top of the sidebar (the home screen there); on wider
    /// layouts it is centred on the dashboard instead, so it never appears twice.
    private var headerInSidebar: Bool { windowSizeClass != .regular }

    private var sidebar: some View {
        List(selection: $selection) {
            Group {
                if headerInSidebar {
                    Section {
                        TerminalHeroHeader(reduced: true)
                            .padding(.vertical, 2)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        ModeSelector(selection: model.preferredMode, availability: availability) { model.selectMode($0) }
                        ModeStatusLine(mode: model.preferredMode, available: availability(model.preferredMode))
                        newSessionMenu
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
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
                    if model.sessions.isEmpty {
                        Text("No sessions yet. Start one with New Session.")
                            .font(.footnote)
                            .foregroundStyle(HCGPalette.textSecondary)
                    }
                    if model.sessions.contains(where: { !$0.isLive }) {
                        Button(role: .destructive) { Task { await model.closeEndedSessions() } } label: {
                            Label("Close Ended Sessions", systemImage: "xmark.circle")
                        }
                    }
                } header: { Eyebrow("Sessions") }

                Section {
                    NavigationLink(value: SidebarItem.dashboard) {
                        Label { Text("Dashboard") } icon: { HCGMark(size: 24) }
                    }
                    NavigationLink(value: SidebarItem.files) { Label("File Command", systemImage: "folder.badge.gearshape") }
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
            .hcgRows()
        }
        .hcgTileLabels()
        .listSectionSpacing(.compact)
        // iPhone: no empty navigation bar above the header (pushed screens keep their own bar).
        .toolbar(headerInSidebar ? .hidden : .automatic, for: .navigationBar)
        .contentMargins(.top, headerInSidebar ? 4 : 0, for: .scrollContent)
        // The title stays for back buttons and the app switcher, but is not drawn: the header
        // artwork is the visible title (and is exposed to VoiceOver once, as a heading).
        .navigationTitle("HCG Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
        .hcgScreenBackground()
    }

    /// The primary action: a new session in the current local mode, the device's localhost SSH
    /// service (Unleashed build) or a remote host. Unavailable choices stay disabled.
    private var newSessionMenu: some View {
        Menu {
            Button {
                Task { await model.openLocalSession() }
            } label: {
                Label("Local \(model.preferredMode.displayName) Session", systemImage: "iphone")
            }
            .disabled(!model.isAvailable(model.preferredMode))
            if model.dependencies.distribution == .unleashed {
                Button { showLoopback = true } label: {
                    Label("Localhost SSH (this device)", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(!model.dependencies.access.isEnabled(.localhostSSH))
            }
            Button { showNewRemote = true } label: {
                Label("Remote Host Session", systemImage: "desktopcomputer")
            }
        } label: {
            PrimaryActionLabel(title: "New Session", systemImage: "plus", color: ModeAccent.color(model.preferredMode, accent: model.appearance.accent))
        }
        .accessibilityHint("Choose a local, localhost SSH or remote session")
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard, nil:
            NavigationStack {
                DashboardView(
                    showHeader: !headerInSidebar,
                    openSession: { selection = .session($0) },
                    openItem: { selection = $0 },
                    newRemote: { showNewRemote = true }
                )
            }
        case .access: NavigationStack { CapabilitiesAccessView() }
        case .session(let id):
            if let session = model.session(id) {
                SessionScreen(session: session, onBack: headerInSidebar ? {
                    selection = nil
                    compactColumn = .sidebar
                } : nil)
            } else {
                emptyState
            }
        case .files: NavigationStack { FileCommandView() }
        case .hosts: NavigationStack { HostsView() }
        case .builds: NavigationStack { BuildsView() }
        case .artifacts: NavigationStack { ArtifactsView() }
        case .unleashedTools: NavigationStack { UnleashedToolsView() }
        case .preferences: NavigationStack { PreferencesView() }
        case .diagnostics: NavigationStack { DiagnosticsView() }
        }
    }

    private var emptyState: some View {
        HCGEmptyState("No Session Selected", systemImage: nil, description: Text("Open a local \(model.preferredMode.displayName) session or connect to a remote host.")) {
            Button("New Local Session") { Task { await model.openLocalSession() } }
                .buttonStyle(.hcgProminent)
                .disabled(!model.isAvailable(model.preferredMode))
        }
        .background { HCGBackdrop() }
    }

    private func availability(_ mode: ExecutionMode) -> Bool? {
        model.report(for: mode).map { _ in model.isAvailable(mode) }
    }

    #if DEBUG
    /// CI launch smoke tests only (Debug builds): `-HCGSmokeScenario <name>` drives the real
    /// interface into one state so a screenshot can be taken. Not compiled into Release.
    ///
    /// Modifiers: `-HCGSmokeLandscape` rotates to landscape; `-HCGSmokeKeyboardHidden` keeps the
    /// software keyboard closed in sessions. Appearance scenarios (`classic…`, `enhanced…`,
    /// `reduced…`) are shown without being saved.
    private func runSmokeScenario() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HCGSmokeScenario"), index + 1 < arguments.count else { return }
        if arguments.contains("-HCGSmokeLandscape"),
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        var scenario = arguments[index + 1]
        let appearanceVariants: [(String, (inout AppearanceSettings) -> Void)] = [
            ("classic-", { $0.style = .classic }),
            ("enhanced-", { $0.backgroundDetail = .enhanced }),
            ("reduced-", { $0.reducedEffects = true }),
            ("detailoff-", { $0.backgroundDetail = .off }),
        ]
        for (prefix, change) in appearanceVariants where scenario.hasPrefix(prefix) {
            model.previewAppearance(change)
            scenario.removeFirst(prefix.count)
        }
        switch scenario {
        case "unleashed-tap":
            model.selectMode(.unleashed)
        case "session":
            if let session = await model.openLocalSession(mode: .vanilla) {
                try? await Task.sleep(nanoseconds: 700_000_000)
                session.send(Array("help\r".utf8))
            }
        case "long-name":
            if let session = await model.openLocalSession(mode: .vanilla) {
                session.title = "Release build of the HCG Terminal Unleashed package on build-mac.local with very long name"
                try? await Task.sleep(nanoseconds: 700_000_000)
                session.send(Array("ls\r".utf8))
            }
        case "ansi":
            // Synthetic output fed to the real renderer: long scrollback, then 16/256/true colour
            // foregrounds and backgrounds and text attributes.
            if let session = await model.openLocalSession(mode: .vanilla) {
                // After the shell's own banner, so the sample is drawn last.
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                session.handle(.output(SmokeTerminalContent.ansi()))
            }
        case "fullscreen":
            // A full-screen program's drawing (alternate screen, cursor addressing, background
            // fills to the line end), fed to the real renderer.
            if let session = await model.openLocalSession(mode: .vanilla) {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                session.handle(.output(SmokeTerminalContent.fullScreen()))
            }
        case "unleashed-checks":
            // Opens the Unleashed checks sheet with the current report, whatever the result.
            if let report = model.report(for: .unleashed) {
                model.modeUnavailable = ModeUnavailableExplanation(mode: .unleashed, report: report, distribution: model.dependencies.distribution)
            }
        case "editor":
            let path = WorkspacePath.home.appending("README.md")
            try? model.dependencies.workspace.write("# My workspace\n\nProjects, scripts and notes.\n\nThis file was written by the CI screenshot run.\n", to: path)
            smokeEditorPath = path
        case "new-remote": showNewRemote = true
        case "key-import": smokeKeyImport = true
        case "no-session":
            selection = .session(SessionID())
            compactColumn = .detail
        case "capabilities": selection = .access
        case "settings": selection = .preferences
        case "dashboard": selection = .dashboard
        case "files": selection = .files
        case "diagnostics": selection = .diagnostics
        case "hosts": selection = .hosts
        case "builds": selection = .builds
        case "artifacts": selection = .artifacts
        case "tools": selection = model.dependencies.distribution == .unleashed ? SidebarItem.unleashedTools : SidebarItem.access
        default: break
        }
    }
    #endif
}

#if DEBUG
/// Synthetic terminal output for the CI screenshots (Debug builds only).
enum SmokeTerminalContent {
    private static let esc = "\u{1B}["

    static func ansi() -> [UInt8] {
        var s = ""
        for n in 1...200 {
            s += String(format: "%04d", n) + "  build step · \(esc)32mok\(esc)0m · \(esc)33mwarn\(esc)0m · \(esc)31merror\(esc)0m · the quick brown fox jumps over the lazy dog\r\n"
        }
        s += "\r\n\(esc)1mANSI colour check (synthetic output)\(esc)0m\r\n"
        for code in 30...37 { s += "\(esc)\(code)m fg\(code)\(esc)0m" }
        s += "\r\n"
        for code in 90...97 { s += "\(esc)\(code)m fg\(code)\(esc)0m" }
        s += "\r\n"
        for code in 40...47 { s += "\(esc)\(code)m bg\(code)\(esc)0m" }
        s += "\r\n"
        for code in 100...107 { s += "\(esc)30;\(code)m bg\(code)\(esc)0m" }
        s += "\r\n"
        for color in stride(from: 16, to: 232, by: 6) { s += "\(esc)48;5;\(color)m  " }
        s += "\(esc)0m\r\n"
        for color in 232...255 { s += "\(esc)48;5;\(color)m " }
        s += "\(esc)0m\r\n"
        for step in 0..<40 { s += "\(esc)48;2;\(step * 6);\(255 - step * 6);200m " }
        s += "\(esc)0m\r\n"
        s += "\(esc)1mbold\(esc)0m \(esc)2mdim\(esc)0m \(esc)3mitalic\(esc)0m \(esc)4munderline\(esc)0m \(esc)7minverse\(esc)0m \(esc)9mstrike\(esc)0m\r\n"
        s += "Scroll up for 200 lines of earlier output.\r\n"
        return Array(s.utf8)
    }

    static func fullScreen() -> [UInt8] {
        var s = "\(esc)?1049h\(esc)H\(esc)2J"
        s += "\(esc)1;1H\(esc)44;97m  hcg-top · synthetic full-screen program\(esc)K\(esc)0m"
        let rows = [
            ("PID", "COMMAND", "CPU"), ("101", "swift-build", "62.0"), ("214", "xcodebuild", "31.5"),
            ("318", "sshd", "0.4"), ("422", "zsh", "0.1"), ("530", "claude", "4.2"),
        ]
        for (offset, row) in rows.enumerated() {
            let line = row.0.padding(toLength: 6, withPad: " ", startingAt: 0) + row.1.padding(toLength: 16, withPad: " ", startingAt: 0) + row.2
            let style = offset == 0 ? "\(esc)1;36m" : offset == 2 ? "\(esc)30;46m" : ""
            s += "\(esc)\(offset + 3);2H\(style)\(line)\(esc)K\(esc)0m"
        }
        s += "\(esc)10;2H┌──────────────────────────┐"
        s += "\(esc)11;2H│ \(esc)32m*\(esc)0m alternate screen active│"
        s += "\(esc)12;2H│ \(esc)41;97m ERR \(esc)0m \(esc)43;30m WARN \(esc)0m \(esc)42;30m OK \(esc)0m        │"
        s += "\(esc)13;2H└──────────────────────────┘"
        s += "\(esc)999;1H\(esc)7m q quit  ↑↓ select  / search \(esc)K\(esc)0m"
        return Array(s.utf8)
    }
}
#endif

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
                    .foregroundStyle(HCGPalette.textSecondary)
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
            Group {
                Section {
                    ModeSelector(selection: model.preferredMode, availability: { mode in
                        model.report(for: mode).map { _ in model.isAvailable(mode) }
                    }) { model.selectMode($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(ExecutionMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(ModeAccent.color(mode, accent: model.appearance.accent))
                            Text(mode.summary).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
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
                        .font(.footnote).foregroundStyle(HCGPalette.textSecondary)
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
                .foregroundStyle(HCGPalette.textSecondary)
            }
            .hcgRows()
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

/// Look, background detail, ambient motion, theme, accent, effects and terminal text size.
/// Appearance only: nothing here changes what the app may do.
struct AppearanceSection: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        Section {
            Picker("Style", selection: Binding(get: { model.appearance.style }, set: { value in model.updateAppearance { $0.style = value } })) {
                ForEach(AppearanceSettings.Style.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Interface style")
            VStack(alignment: .leading, spacing: 6) {
                Text("Background detail").font(.subheadline)
                Picker("Background detail", selection: Binding(get: { model.appearance.backgroundDetail }, set: { value in model.updateAppearance { $0.backgroundDetail = value } })) {
                    ForEach(AppearanceSettings.BackgroundDetail.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.appearance.style == .classic)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Ambient motion", isOn: Binding(get: { model.appearance.ambientMotion }, set: { value in model.updateAppearance { $0.ambientMotion = value } }))
                    .disabled(model.appearance.style == .classic)
                Text("A very slow glow at the screen edges. Never runs in a terminal session, in the background, in Low Power Mode or with Reduce Motion.")
                    .font(.footnote)
                    .foregroundStyle(HCGPalette.textSecondary)
            }
            Picker("Theme", selection: Binding(get: { model.appearance.theme }, set: { value in model.updateAppearance { $0.theme = value } })) {
                ForEach(AppearanceSettings.Theme.allCases) { Text($0.label).tag($0) }
            }
            Picker("Accent", selection: Binding(get: { model.appearance.accent }, set: { value in model.updateAppearance { $0.accent = value } })) {
                ForEach(AppearanceSettings.Accent.allCases) { accent in
                    Label(accent.label, systemImage: "circle.fill").foregroundStyle(HCGPalette.accent(accent)).tag(accent)
                }
            }
            Toggle("Reduce visual effects", isOn: Binding(get: { model.appearance.reducedEffects }, set: { value in model.updateAppearance { $0.reducedEffects = value } }))
            if TerminalHeroAnimation.isBundled {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Animated header", isOn: Binding(get: { model.appearance.animatedHeader }, set: { value in model.updateAppearance { $0.animatedHeader = value } }))
                    Text("Animate the HCG logo on the home screen. Turn off for a still image and lower power use.")
                        .font(.footnote)
                        .foregroundStyle(HCGPalette.textSecondary)
                }
            }
            Stepper(value: Binding(get: { model.appearance.terminalFontSize }, set: { value in model.updateAppearance { $0.terminalFontSize = value } }), in: AppearanceSettings.terminalFontRange, step: 1) {
                LabeledContent("Terminal text", value: "\(Int(model.appearance.terminalFontSize)) pt")
            }
            Text("The quick brown fox · ls -la ~/projects")
                .font(.system(size: model.appearance.terminalFontSize, design: .monospaced))
                .foregroundStyle(Color(uiColor: HCGPalette.terminalTextUI))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HCGPalette.terminalSurface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Terminal text preview")
        } header: { Text("Appearance") } footer: {
            Text("Event Horizon adds a subtle background and edge-lit panels; Classic is the earlier flat look. The terminal itself always stays on an opaque dark surface. Reduce visual effects, and the system's Reduce Transparency and Increase Contrast, give opaque surfaces with no glow. Unleashed always uses violet so the modes stay distinct. Appearance never changes what this build or device allows.")
        }
    }
}
#endif
