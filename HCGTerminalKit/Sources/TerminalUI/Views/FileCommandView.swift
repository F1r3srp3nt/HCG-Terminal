#if canImport(UIKit) && canImport(SwiftUI)
import FileWorkspace
import SwiftUI
import TerminalCore

/// The file-management entry point. Workspace paths and actual device paths are kept distinct.
struct FileCommandView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var roots: [String] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("HCG FILE COMMAND", systemImage: "folder.badge.gearshape")
                        .font(.headline).foregroundStyle(HCGPalette.cyan)
                    Text("Browse. Inspect. Edit.").font(.title2.bold())
                    Text("Manage your terminal workspace and the device locations available to this installation.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            Section("Terminal workspace") {
                NavigationLink { WorkspaceBrowserView(directory: .root) } label: {
                    Label("All Workspace Files", systemImage: "folder")
                }
                NavigationLink { WorkspaceBrowserView(directory: .home) } label: {
                    Label("Documents & Notes", systemImage: "doc.text")
                }
                NavigationLink { WorkspaceBrowserView(directory: .projects) } label: {
                    Label("Projects", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Text("Open a workspace folder to import from Files, edit UTF-8 text, or export a copy. Workspace / is not the iPhone’s system root.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Device filesystem · Unleashed") {
                if model.dependencies.unleashedTools == nil {
                    Text("System browsing needs the Unleashed build. Workspace editing and Files import/export remain available.")
                } else if let reason = model.dependencies.access.denial(.expandedFileRead) {
                    Text(reason)
                } else {
                    if roots.isEmpty {
                        Text("No readable device locations were found. Recheck after changing the installation or permissions.")
                    }
                    ForEach(roots, id: \.self) { root in
                        NavigationLink { HostDirectoryView(path: root) } label: {
                            Label(root == "/" ? "Device Root /" : root, systemImage: "internaldrive")
                        }
                    }
                }
                Text("Read and write access are separate. The device may deny individual folders even when their parent is readable. Encrypted or protected files are not automatically unlocked.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { CapabilitiesAccessView() } label: {
                    Label("Filesystem Access Settings", systemImage: "lock.shield")
                }
            }
        }
        .navigationTitle("File Command")
        .hcgScreenBackground()
        .task(id: model.accessSettings) { await reload() }
        .refreshable {
            await model.dependencies.unleashedTools?.invalidateScan()
            await reload()
        }
    }

    private func reload() async {
        guard model.dependencies.access.isEnabled(.expandedFileRead),
              let tools = model.dependencies.unleashedTools else { roots = []; return }
        roots = Array(Set(await tools.permittedRoots())).sorted()
    }
}
#endif
