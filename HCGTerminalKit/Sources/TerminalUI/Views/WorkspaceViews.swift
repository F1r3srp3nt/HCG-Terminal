#if canImport(UIKit) && canImport(SwiftUI)
import FileWorkspace
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Browses the app workspace: the same files the built-in commands see (`/home`, `/projects`,
/// `/artifacts`, `/logs`, `/tmp`). Create, rename, delete, edit text, import and export.
struct WorkspaceBrowserView: View {
    @Environment(TerminalAppModel.self) private var model
    let directory: WorkspacePath

    @State private var items: [WorkspaceItem] = []
    @State private var query = ""
    @AppStorage("hcg.fileCommand.showHidden") private var showHidden = false
    @State private var loadError: String?
    @State private var showImporter = false
    @State private var pendingImport: [URL] = []
    @State private var conflictNames: [String] = []
    @State private var showConflictChoice = false
    @State private var exportTarget: ExportTarget?
    @State private var renaming: WorkspaceItem?
    @State private var newName = ""
    @State private var deleting: WorkspaceItem?
    @State private var status: String?

    private var workspace: FileWorkspace { model.dependencies.workspace }

    var body: some View {
        List {
            Group {
                if let status {
                    Text(status).font(.footnote).foregroundStyle(HCGPalette.textSecondary)
                }
                ForEach(items.filter { (showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { item in
                    Group {
                        if item.isDirectory {
                            NavigationLink { WorkspaceBrowserView(directory: item.path) } label: { row(item) }
                        } else {
                            NavigationLink { WorkspaceFileView(path: item.path) } label: { row(item) }
                        }
                    }
                    .contextMenu { actions(for: item) }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = item }
                        Button("Rename") { newName = item.name; renaming = item }
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .overlay {
            if let loadError {
                HCGEmptyState("Cannot Open Folder", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if items.isEmpty {
                HCGEmptyState("Empty Folder", systemImage: "folder", description: Text("Create a file or import from the Files app."))
            }
        }
        .searchable(text: $query, prompt: "Search this folder")
        .navigationTitle(directory.isRoot ? "Workspace" : directory.name)
        .safeAreaInset(edge: .bottom) { Text("Workspace: " + directory.string).font(.caption.monospaced()).textSelection(.enabled).padding(6) }
        .toolbar {
            Menu {
                Toggle("Show Hidden Files", isOn: $showHidden)
                Button { create(directory: false) } label: { Label("New Text File", systemImage: "doc.badge.plus") }
                Button { create(directory: true) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { showImporter = true } label: { Label("Import from Files…", systemImage: "square.and.arrow.down") }
                if !directory.isRoot {
                    Button { export(directory) } label: { Label("Export This Folder…", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .task { reload() }
        .refreshable { reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): beginImport(urls)
            case .failure(let error): status = error.localizedDescription
            }
        }
        .confirmationDialog(conflictTitle, isPresented: $showConflictChoice, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { finishImport(.replace) }
            Button("Keep Both") { finishImport(.keepBoth) }
            Button("Skip Existing") { finishImport(.skip) }
            Button("Cancel", role: .cancel) { pendingImport = [] }
        } message: {
            Text("Replace overwrites the existing item. Keep Both imports the new one under a numbered name.")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = deleting { perform { try workspace.remove(item.path, recursive: true) } }
                deleting = nil
            }
        } message: {
            Text(deleting?.isDirectory == true ? "The folder and everything in it is removed from the workspace." : "The file is removed from the workspace.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                if let item = renaming { perform { _ = try workspace.rename(item.path, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(item: $exportTarget) { target in
            DocumentExportPicker(url: target.url).ignoresSafeArea()
        }
    }

    private var conflictTitle: String {
        conflictNames.count == 1 ? "“\(conflictNames[0])” already exists" : "\(conflictNames.count) items already exist"
    }

    @ViewBuilder
    private func actions(for item: WorkspaceItem) -> some View {
        Button { newName = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
        Button { export(item.path) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
        Button { UIPasteboard.general.string = item.path.string } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
    }

    private func row(_ item: WorkspaceItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(item.isDirectory ? HCGPalette.vanillaBlue : HCGPalette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let modified = item.modified {
                    Text(modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(HCGPalette.textSecondary)
                }
            }
            Spacer()
            if !item.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
        }
    }

    private func reload() {
        do {
            items = try workspace.list(directory, includeHidden: true)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            status = nil
        } catch {
            status = error.localizedDescription
        }
        reload()
    }

    private func create(directory makeDirectory: Bool) {
        perform { _ = try workspace.createItem(named: makeDirectory ? "New Folder" : "untitled.txt", in: directory, directory: makeDirectory) }
    }

    private func export(_ path: WorkspacePath) {
        do { exportTarget = ExportTarget(url: try workspace.exportURL(for: path)) } catch { status = error.localizedDescription }
    }

    private func beginImport(_ urls: [URL]) {
        pendingImport = urls
        conflictNames = workspace.conflicts(importing: urls, into: directory)
        if conflictNames.isEmpty { finishImport(.fail) } else { showConflictChoice = true }
    }

    private func finishImport(_ policy: ConflictPolicy) {
        var imported = 0, replaced = 0, kept = 0, skipped = 0
        var failures: [String] = []
        for url in pendingImport {
            do {
                switch try workspace.importItem(from: url, into: directory, policy: policy) {
                case .imported: imported += 1
                case .replaced: replaced += 1
                case .keptBoth: kept += 1
                case .skipped: skipped += 1
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        pendingImport = []
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) imported") }
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if kept > 0 { parts.append("\(kept) kept as copies") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        status = (parts.isEmpty ? "" : parts.joined(separator: ", ") + ". ") + failures.joined(separator: " ")
        reload()
    }
}

struct ExportTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

/// "Save to Files": exports a copy; the system picker asks before replacing at the destination.
struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// Plain-text editor for workspace files. Detects edits made elsewhere (terminal, Files app)
/// since the file was opened and asks before overwriting them.
struct TextFileEditor: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: WorkspacePath

    @State private var document: TextDocument?
    @State private var text = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var showChangedOnDisk = false
    @State private var showUnsavedChoice = false

    private var workspace: FileWorkspace { model.dependencies.workspace }
    private var hasChanges: Bool { document != nil && text != document?.text }

    var body: some View {
        Group {
            if let loadError {
                HCGEmptyState("Cannot Edit", systemImage: "doc.questionmark", description: Text(loadError))
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .hcgDocumentSurface()
            }
        }
        .background { HCGBackdrop() }
        .navigationTitle(path.name + (hasChanges ? " •" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showUnsavedChoice = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(overwrite: false) }.disabled(!hasChanges)
            }
        }
        .task { load() }
        .confirmationDialog("“\(path.name)” changed since you opened it", isPresented: $showChangedOnDisk, titleVisibility: .visible) {
            Button("Overwrite with My Version", role: .destructive) { save(overwrite: true) }
            Button("Discard My Changes and Reload") { load() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Something else (a terminal command or the Files app) modified the file.")
        }
        .confirmationDialog("Save changes to “\(path.name)”?", isPresented: $showUnsavedChoice, titleVisibility: .visible) {
            Button("Save") {
                if save(overwrite: false) { dismiss() }
            }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Could Not Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func load() {
        do {
            let opened = try workspace.openTextDocument(path)
            document = opened
            text = opened.text
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    private func save(overwrite: Bool) -> Bool {
        guard let document else { return false }
        do {
            self.document = try workspace.saveTextDocument(document, text: text, overwriteChanges: overwrite)
            return true
        } catch DocumentError.changedOnDisk {
            showChangedOnDisk = true
        } catch {
            saveError = error.localizedDescription
        }
        return false
    }
}
#endif
