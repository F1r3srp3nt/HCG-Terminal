#if canImport(UIKit) && canImport(SwiftUI)
import DeveloperWorkspace
import FileWorkspace
import RemoteSSH
import SwiftUI
import TerminalCore

/// Remote Files (SFTP) for one host: browse, download into the workspace, upload from the
/// workspace, new folder, delete with confirmation. Transfers show progress and can be
/// cancelled; a cancelled or failed transfer leaves nothing behind.
struct RemoteFilesView: View {
    @Environment(TerminalAppModel.self) private var model
    let host: HostProfile
    @State private var files: RemoteFilesModel?
    @State private var showUpload = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SFTPEntry?
    @State private var pendingReplace: WorkspacePath?

    var body: some View {
        Group {
            if let files {
                content(files)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { HCGBackdrop() }
        .navigationTitle("Remote Files")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if files == nil { files = RemoteFilesModel(host: host, app: model) }
            await files?.start()
        }
        .onDisappear { let files = files; Task { await files?.stop() } }
    }

    @ViewBuilder
    private func content(_ files: RemoteFilesModel) -> some View {
        List {
            Group {
                if !files.transfers.isEmpty {
                    Section {
                        ForEach(files.transfers) { TransferRow(transfer: $0) }
                    } header: {
                        HStack {
                            Text("Transfers")
                            Spacer()
                            if files.transfers.contains(where: { $0.state != .running }) {
                                Button("Clear") { files.clearFinishedTransfers() }.font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                Section {
                    if files.canGoUp {
                        Button { Task { await files.goUp() } } label: {
                            Label("Up to \(SFTPClient.parent(of: files.path))", systemImage: "arrow.turn.left.up")
                        }
                    }
                    ForEach(files.entries) { entry in
                        RemoteEntryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if entry.isDirectory { Task { await files.open(entry.path) } }
                            }
                            .contextMenu {
                                if !entry.isDirectory {
                                    Button { _ = files.download(entry) } label: { Label("Download to Workspace", systemImage: "arrow.down.circle") }
                                }
                                Button(role: .destructive) { pendingDelete = entry } label: { Label("Delete…", systemImage: "trash") }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = entry } label: { Label("Delete", systemImage: "trash") }
                                if !entry.isDirectory {
                                    Button { _ = files.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                        .tint(HCGPalette.accentPrimary)
                                }
                            }
                            .accessibilityAction(named: "Download to Workspace") { if !entry.isDirectory { _ = files.download(entry) } }
                    }
                    if files.entries.isEmpty && !files.loading && files.errorMessage == nil {
                        Text("This folder is empty.").font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                    }
                } header: {
                    Text(files.path.isEmpty ? host.endpoint.address : files.path)
                        .font(.caption.monospaced())
                        .textCase(nil)
                        .lineLimit(2)
                        .truncationMode(.head)
                } footer: {
                    Text("Downloads are saved in the workspace under \(files.downloadFolder.string). Nothing is overwritten: a name already in use gets a number. Only empty folders can be deleted here.")
                }
                if let error = files.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(HCGPalette.warn).font(.footnote)
                        Button("Try Again") { Task { await files.start() } }
                    }
                }
            }
            .hcgRows()
        }
        .scrollContentBackground(.hidden)
        .overlay { if files.loading && files.entries.isEmpty { ProgressView() } }
        .refreshable { await files.reload() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { showUpload = true } label: { Label("Upload from Workspace…", systemImage: "arrow.up.circle") }
                    Button { newFolderName = ""; showNewFolder = true } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
                    Button { Task { await files.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(files.path.isEmpty)
            }
        }
        .sheet(isPresented: $showUpload) {
            NavigationStack {
                WorkspaceFilePicker(title: "Upload to \(host.name)") { item in
                    showUpload = false
                    if files.exists(item.name) { pendingReplace = item } else { _ = files.upload(item, replace: false) }
                }
            }
            .environment(model)
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await files.makeFolder(named: newFolderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { Task { await files.delete(entry) } }
                pendingDelete = nil
            }
        } message: {
            Text("This deletes it on \(host.name). It cannot be undone from HCG Terminal.")
        }
        .confirmationDialog("Replace “\(pendingReplace?.name ?? "")” on \(host.name)?", isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let item = pendingReplace { _ = files.upload(item, replace: true) }
                pendingReplace = nil
            }
        } message: {
            Text("A file with this name already exists in this folder.")
        }
    }

    private var deleteTitle: String {
        guard let entry = pendingDelete else { return "Delete?" }
        return entry.isDirectory ? "Delete the folder “\(entry.name)”?" : "Delete “\(entry.name)”?"
    }
}

struct RemoteEntryRow: View {
    let entry: SFTPEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : entry.isSymbolicLink ? "link" : "doc")
                .foregroundStyle(entry.isDirectory ? HCGPalette.accentPrimary : HCGPalette.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(HCGPalette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isDirectory {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HCGPalette.textSecondary).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.isDirectory ? .isButton : [])
    }

    private var detail: String {
        var parts: [String] = []
        if entry.isDirectory { parts.append("Folder") } else if let size = entry.size { parts.append(WorkspaceSummary.format(bytes: Int64(clamping: size))) }
        if let modified = entry.modified { parts.append(modified.formatted(date: .abbreviated, time: .shortened)) }
        if let mode = entry.modeText { parts.append(mode) }
        return parts.joined(separator: " · ")
    }
}

struct TransferRow: View {
    let transfer: RemoteTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(HCGPalette.accentPrimary)
                    .accessibilityHidden(true)
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if transfer.state == .running {
                    Button("Cancel") { transfer.cancel() }.buttonStyle(.borderless).font(.caption.weight(.semibold))
                }
            }
            switch transfer.state {
            case .running:
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction).tint(HCGPalette.accentPrimary)
                } else {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(progressText).font(.caption.monospacedDigit()).foregroundStyle(HCGPalette.textSecondary)
            case .finished(let message):
                Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(HCGPalette.ok)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(HCGPalette.warn)
            case .cancelled:
                Label("Cancelled. Nothing was kept.", systemImage: "xmark.circle").font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        let done = WorkspaceSummary.format(bytes: Int64(clamping: transfer.done))
        guard let total = transfer.total else { return done }
        return "\(done) of \(WorkspaceSummary.format(bytes: Int64(clamping: total)))"
    }
}

/// Picks one file from the workspace (searchable, all folders).
struct WorkspaceFilePicker: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (WorkspacePath) -> Void
    @State private var items: [WorkspaceItem] = []
    @State private var search = ""
    @State private var loaded = false

    private var shown: [WorkspaceItem] {
        search.isEmpty ? items : items.filter { $0.path.string.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Group {
                ForEach(shown) { item in
                    Button { onPick(item.path) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).foregroundStyle(HCGPalette.textPrimary)
                            Text("\(item.path.string) · \(WorkspaceSummary.format(bytes: item.size))")
                                .font(.caption).foregroundStyle(HCGPalette.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .overlay {
            if loaded && items.isEmpty {
                HCGEmptyState("No Files in the Workspace", systemImage: "doc", description: Text("Create or import a file in File Command first."))
            } else if !loaded {
                ProgressView()
            }
        }
        .searchable(text: $search)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task {
            let workspace = model.dependencies.workspace
            items = await Task.detached { Self.allFiles(in: workspace) }.value
            loaded = true
        }
    }

    /// Every file in the workspace (bounded), newest first.
    nonisolated static func allFiles(in workspace: FileWorkspace, limit: Int = 2000) -> [WorkspaceItem] {
        var result: [WorkspaceItem] = []
        var folders: [WorkspacePath] = [.root]
        while let folder = folders.popLast(), result.count < limit {
            for item in (try? workspace.list(folder)) ?? [] {
                if item.isDirectory { folders.append(item.path) } else { result.append(item) }
            }
        }
        return result.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}
#endif
