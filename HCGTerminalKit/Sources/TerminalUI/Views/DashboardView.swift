#if canImport(UIKit) && canImport(SwiftUI)
import FileWorkspace
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// Home screen: what is running, where files are, which hosts are connected and what this
/// build and device actually allow. Every number comes from the app's real state; nothing is
/// decorative or simulated.
struct DashboardView: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var typeSize
    /// False on iPhone, where the header is at the top of the sidebar instead.
    var showHeader: Bool = true
    var openSession: (SessionID) -> Void
    var openItem: (SidebarItem) -> Void
    var newRemote: () -> Void
    @State private var workspace: WorkspaceSummary?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 320 : 280), spacing: 14, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    sessionsPanel
                    workspacePanel
                    hostsPanel
                    buildsPanel
                }
                capabilitiesPanel
            }
            .padding()
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .hcgScreenBackground()
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(showHeader ? .inline : .automatic)
        .task { workspace = await WorkspaceSummary.load(model.dependencies.workspace) }
        .refreshable {
            await model.refreshCapabilities()
            workspace = await WorkspaceSummary.load(model.dependencies.workspace)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            if showHeader { TerminalHeroHeader() }
            HStack(spacing: 8) {
                Label("\(model.preferredMode.displayName) mode", systemImage: model.preferredMode == .vanilla ? "iphone" : "bolt.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ModeAccent.color(model.preferredMode, accent: appearance.accent))
                Text("·").foregroundStyle(HCGPalette.muted).accessibilityHidden(true)
                Text(model.dependencies.distribution == .standard ? "Standard build" : "Unleashed build")
                    .font(.subheadline)
                    .foregroundStyle(HCGPalette.muted)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Panels

    private var sessionsPanel: some View {
        let live = model.sessions.filter(\.isLive)
        return DashboardPanel(title: "Active sessions", symbol: "terminal", value: "\(live.count)") {
            if live.isEmpty {
                Text("No session is running.").font(.callout).foregroundStyle(HCGPalette.muted)
            }
            ForEach(live.prefix(5)) { session in
                Button { openSession(session.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ModeAccent.symbol(session.target))
                            .foregroundStyle(ModeAccent.color(session.target))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).font(.callout.weight(.semibold)).foregroundStyle(HCGPalette.ivory).lineLimit(1)
                            Text("\(session.target.label) · \(session.state.label)").font(.caption).foregroundStyle(HCGPalette.muted).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button {
                    Task { if let session = await model.openLocalSession() { openSession(session.id) } }
                } label: { Label("Local", systemImage: "plus") }
                .disabled(!model.isAvailable(model.preferredMode))
                Button { newRemote() } label: { Label("Remote", systemImage: "plus") }
                    .disabled(!model.dependencies.access.isEnabled(.remoteSSH))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var workspacePanel: some View {
        DashboardPanel(title: "Workspace", symbol: "folder", value: workspace.map { WorkspaceSummary.format(bytes: $0.bytes) } ?? "…") {
            if let workspace {
                LabeledContent("Projects", value: "\(workspace.projects)")
                LabeledContent("Files", value: workspace.truncated ? "\(workspace.files)+" : "\(workspace.files)")
                LabeledContent("Downloaded artifacts", value: "\(model.builds.artifacts.count)")
            } else {
                ProgressView()
            }
            Button { openItem(.files) } label: { Label("Open File Command", systemImage: "folder.badge.gearshape") }
                .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    private var hostsPanel: some View {
        let connected = model.hosts.filter { model.isConnected($0) }
        return DashboardPanel(title: "Hosts", symbol: "server.rack", value: "\(connected.count)/\(model.hosts.count) connected") {
            if model.hosts.isEmpty {
                Text("No hosts saved yet.").font(.callout).foregroundStyle(HCGPalette.muted)
            }
            ForEach(model.hosts.prefix(5)) { host in
                HStack {
                    Image(systemName: model.isConnected(host) ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(model.isConnected(host) ? HCGPalette.ok : HCGPalette.muted)
                        .accessibilityHidden(true)
                    Text(host.name).font(.callout).lineLimit(1)
                    Spacer()
                    Text(model.isConnected(host) ? "Connected" : "Not connected").font(.caption).foregroundStyle(HCGPalette.muted)
                }
                .accessibilityElement(children: .combine)
            }
            Button { openItem(.hosts) } label: { Label("Hosts & Projects", systemImage: "server.rack") }
                .buttonStyle(.bordered)
        }
    }

    private var buildsPanel: some View {
        DashboardPanel(title: "Builds & tests", symbol: "hammer", value: model.builds.isRunning ? "Running" : "\(model.builds.runs.count) runs") {
            if let plan = model.builds.activePlan {
                Label("\(plan.title) on \(plan.hostName)", systemImage: "hourglass").font(.callout)
            } else if let last = model.builds.runs.first {
                Text("Last: \(last.plan.title) on \(last.plan.hostName)").font(.callout).lineLimit(2)
                Text(last.status.label).font(.caption).foregroundStyle(HCGPalette.muted)
            } else {
                Text("No build has run yet.").font(.callout).foregroundStyle(HCGPalette.muted)
            }
            Button { openItem(.builds) } label: { Label("Builds & Tests", systemImage: "hammer") }
                .buttonStyle(.bordered)
        }
    }

    private var capabilitiesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Capabilities on this device")
                Spacer()
                Button("Capabilities & Access") { openItem(.access) }
                    .font(.footnote.weight(.semibold))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : 210), spacing: 10)], spacing: 10) {
                ForEach(AccessControl.allCases) { control in
                    if let status = model.effectiveAvailability(for: control) {
                        CapabilityCard(title: control.title, symbol: control.symbolName, status: status)
                    }
                }
            }
        }
    }
}

/// One panel on the dashboard.
struct DashboardPanel<Content: View>: View {
    let title: String
    let symbol: String
    let value: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(HCGPalette.ivory)
                Spacer(minLength: 8)
                Text(value).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(HCGPalette.cyan)
            }
            .accessibilityElement(children: .combine)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hcgPanel()
    }
}

/// Compact capability card: icon, name, status. The status is the effective one (detected,
/// then your switch applied).
struct CapabilityCard: View {
    let title: String
    let symbol: String
    let status: CapabilityAvailability

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(StatusChip.color(status))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HCGPalette.ivory).fixedSize(horizontal: false, vertical: true)
                StatusChip(availability: status)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hcgPanel(tint: StatusChip.color(status), cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Real counts from the workspace folder (bounded walk).
struct WorkspaceSummary: Equatable {
    var bytes: Int64
    var files: Int
    var projects: Int
    var truncated: Bool

    /// "0 KB" rather than the formatter's default "Zero KB".
    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func load(_ workspace: FileWorkspace) async -> WorkspaceSummary {
        let root = workspace.rootURL
        let projects = ((try? workspace.list(.projects)) ?? []).count
        return await Task.detached { walk(root, projects: projects) }.value
    }

    /// Synchronous on purpose: `FileManager.DirectoryEnumerator` cannot be iterated in an async
    /// context. Bounded at 50,000 files.
    static func walk(_ root: URL, projects: Int) -> WorkspaceSummary {
        var bytes: Int64 = 0
        var files = 0
        var truncated = false
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(values.fileSize ?? 0)
                if files >= 50_000 { truncated = true; break }
            }
        }
        return WorkspaceSummary(bytes: bytes, files: files, projects: projects, truncated: truncated)
    }
}
#endif
