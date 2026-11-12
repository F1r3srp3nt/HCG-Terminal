#if canImport(UIKit) && canImport(SwiftUI)
import Diagnostics
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// Unleashed build only: packages, permitted locations and logs. Every view states what it
/// can and cannot do on this device; nothing is attempted without a user action.
struct UnleashedToolsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var packages: [PackageRow] = []
    @State private var packageFilter = ""
    @State private var packageName = ""
    @State private var roots: [String] = []
    @State private var logRoots: [String] = []
    @State private var packagesAvailable = false
    @State private var loading = false

    var body: some View {
        List {
            if !model.isAvailable(.unleashed) {
                Section {
                    Text(CapabilityReport.unleashedUnavailableMessage).foregroundStyle(HCGPalette.warn)
                }
            }
            Section {
                NavigationLink { ProgramsView() } label: { Label("Programs", systemImage: "apple.terminal") }
                NavigationLink { ProcessListView() } label: { Label("Processes", systemImage: "list.bullet.rectangle") }
                NavigationLink { UnleashedEnvironmentView() } label: { Label("Environment and Tests", systemImage: "cpu") }
            }
            Section {
                if let refusal = model.dependencies.access.denial(.packageManagement) {
                    Text(refusal).foregroundStyle(.secondary)
                } else if packagesAvailable {
                    HStack {
                        TextField("Package name", text: $packageName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Install") { request(.install(packageName)) }.disabled(packageName.isEmpty)
                    }
                    Button("Refresh Package Lists") { request(.refreshIndexes) }
                    TextField("Filter installed packages", text: $packageFilter)
                    ForEach(packages.filter { packageFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(packageFilter) }.prefix(300)) { package in
                        HStack {
                            Text(package.name)
                            Spacer()
                            Text(package.version).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { request(.remove(package.name)) } }
                    }
                } else {
                    Text("No supported package manager was found.").foregroundStyle(.secondary)
                }
            } header: { Text("Packages") } footer: {
                Text("Listing is read-only. Install, remove and refresh need your approval each time, then run visibly in a new Local Unleashed session with the permissions the device grants. HCG Terminal never adds sudo.")
            }
            Section("Permitted locations") {
                if let refusal = model.dependencies.access.denial(.expandedFileRead) {
                    Text(refusal).foregroundStyle(.secondary)
                } else if roots.isEmpty { Text("No location outside the app sandbox is readable.").foregroundStyle(.secondary) }
                ForEach(roots, id: \.self) { root in
                    NavigationLink(root) { HostDirectoryView(path: root) }
                }
            }
            Section("Logs") {
                if logRoots.isEmpty { Text("No readable log directories.").foregroundStyle(.secondary) }
                ForEach(logRoots, id: \.self) { root in
                    NavigationLink(root) { HostDirectoryView(path: root) }
                }
            }
        }
        .navigationTitle("Unleashed Tools")
        .hcgScreenBackground()
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let tools = model.dependencies.unleashedTools else { return }
        loading = true
        defer { loading = false }
        packagesAvailable = await tools.packageManagerAvailable()
        if model.dependencies.access.isEnabled(.expandedFileRead) {
            roots = await tools.permittedRoots()
            logRoots = await tools.logRoots()
        } else {
            roots = []
            logRoots = []
        }
        if packagesAvailable, model.dependencies.access.isEnabled(.packageManagement) {
            do {
                packages = try await tools.installedPackages()
                model.recordVerification(.packageManager, mode: .unleashed, observation: "Listed \(packages.count) installed packages.")
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func request(_ request: PackageRequest) {
        guard let tools = model.dependencies.unleashedTools else { return }
        Task {
            do {
                let command = try await tools.authorizedPackageCommand(request)
                await model.runApprovedCommandInNewUnleashedSession(command)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

/// A permitted directory outside the sandbox. Changes are offered only where this app may
/// write; system and jailbreak locations ask for approval each time.
struct HostDirectoryView: View {
    @Environment(TerminalAppModel.self) private var model
    let path: String
    @State private var rows: [HostFileRow] = []
    @State private var writable = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: HostFileRow?
    @State private var newName = ""
    @State private var deleting: HostFileRow?
    @State private var status: String?

    private var tools: (any UnleashedTools)? { model.dependencies.unleashedTools }

    var body: some View {
        List {
            Section {
                Label(writable ? "This app may change items here." : "Read-only for this app.", systemImage: writable ? "pencil" : "lock")
                    .font(.footnote).foregroundStyle(.secondary)
                if let status { Text(status).font(.footnote).foregroundStyle(HCGPalette.warn) }
            }
            ForEach(rows) { row in
                Group {
                    if row.isDirectory {
                        NavigationLink { HostDirectoryView(path: row.path) } label: { label(row) }
                    } else {
                        NavigationLink { HostFileView(path: row.path, writable: row.writable) } label: { label(row) }
                    }
                }
                .swipeActions {
                    if row.writable && writable {
                        Button("Delete", role: .destructive) { deleting = row }
                        Button("Rename") { newName = row.name; renaming = row }
                    }
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            if writable {
                Button { newFolderName = ""; showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { change { try await $0.createDirectory(named: newFolderName, in: path) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let row = renaming { change { try await $0.rename(row.path, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let row = deleting { change { try await $0.delete(row.path) } }
                deleting = nil
            }
        } message: {
            Text("This removes it from the device, outside HCG Terminal's own storage. It cannot be undone.")
        }
    }

    private func label(_ row: HostFileRow) -> some View {
        HStack {
            Label(row.name, systemImage: row.isDirectory ? "folder" : "doc.text")
            Spacer()
            if !row.writable { Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary) }
            if !row.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard let tools else { return }
        writable = await tools.canWrite(path)
        do { rows = try await tools.list(path) } catch { status = error.localizedDescription }
    }

    private func change(_ action: @escaping (any UnleashedTools) async throws -> Void) {
        guard let tools else { return }
        Task {
            do {
                try await action(tools)
                status = nil
                model.recordVerification(.filesystemPermissions, mode: .unleashed, observation: "Changed an item in \(path).")
            } catch {
                status = error.localizedDescription
            }
            await load()
        }
    }
}

/// Shows a file (the end of large logs); text files this app may write can be edited.
struct HostFileView: View {
    @Environment(TerminalAppModel.self) private var model
    let path: String
    let writable: Bool
    @State private var text = ""
    @State private var original = ""
    @State private var editing = false
    @State private var status: String?

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                ScrollView {
                    Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .safeAreaInset(edge: .top) {
            if let status { Text(status).font(.footnote).foregroundStyle(HCGPalette.warn).padding(6) }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if writable {
                if editing {
                    Button("Save") { Task { await save() } }.disabled(text == original)
                } else {
                    Button("Edit") { Task { await startEditing() } }
                }
            }
        }
        .task {
            do { text = try await model.dependencies.unleashedTools?.readTail(path) ?? "" } catch { text = error.localizedDescription }
        }
    }

    private func startEditing() async {
        do {
            let full = try await model.dependencies.unleashedTools?.readText(path) ?? ""
            text = full
            original = full
            editing = true
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() async {
        do {
            try await model.dependencies.unleashedTools?.writeText(text, to: path)
            original = text
            status = "Saved."
            model.recordVerification(.filesystemPermissions, mode: .unleashed, observation: "Wrote \(path).")
            model.noteWriteVerified()
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Sign-in to an existing terminal service on this device (loopback SSH).
struct LoopbackServiceSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ports: [Int] = []
    @State private var port = 22
    @State private var username = "mobile"
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if ports.isEmpty {
                    Text("No terminal service is accepting connections on 127.0.0.1.").foregroundStyle(.secondary)
                } else {
                    Picker("Port", selection: $port) { ForEach(ports, id: \.self) { Text("127.0.0.1:\($0)") } }
                }
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
            } footer: {
                Text("Uses the service's own account. The password is used for this connection only and is not stored. Commands run on this device (Local Unleashed).")
            }
        }
        .navigationTitle("Local Terminal Service")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ports = await model.dependencies.unleashedTools?.loopbackServicePorts() ?? []
            if let first = ports.first { port = first }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") {
                    Task {
                        await model.openLoopbackService(port: port, username: username, password: password)
                        password = ""
                        dismiss()
                    }
                }
                .disabled(ports.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
    }
}

/// The installed build: variant (from the linked code), version, build number, revision.
struct BuildIdentitySection: View {
    let identity: BuildIdentity

    var body: some View {
        Section {
            LabeledContent("Variant", value: identity.variantLabel)
            LabeledContent("Version", value: identity.versionLabel)
            LabeledContent("Source revision", value: identity.sourceRevision)
            LabeledContent("Bundle ID", value: identity.bundleIdentifier)
            LabeledContent("Display name", value: identity.displayName)
            LabeledContent("Declared variant (Info.plist)", value: identity.declaredVariant)
            ForEach(identity.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(HCGPalette.loss)
                    .font(.footnote)
            }
        } header: {
            Text("Build")
        } footer: {
            Text("The variant is determined by the code linked into this binary, not by the app's name. The TestFlight or App Store listing name comes from App Store Connect and can differ.")
        }
    }
}

/// System snapshot, read-only process list and the app's own diagnostic log.
struct DiagnosticsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var snapshot: SystemSnapshot?
    @State private var processes: ProcessListing?
    @State private var entries: [LogEntry] = []
    @State private var exportText = ""

    var body: some View {
        List {
            BuildIdentitySection(identity: model.dependencies.buildIdentity)
            if let assessment = model.assessment {
                EnvironmentAssessmentSections(assessment: assessment)
            }
            if let snapshot {
                Section("Device") {
                    ForEach(snapshot.lines, id: \.0) { row in LabeledContent(row.0, value: row.1) }
                }
            }
            Section("Processes") {
                switch processes {
                case .listed(let list, let complete)?:
                    if !complete { Text("The system shows only part of the process table to this app.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(list.prefix(400)) { process in
                        HStack {
                            Text("\(process.pid)").font(.caption.monospaced()).frame(width: 56, alignment: .leading)
                            Text(process.name)
                            Spacer()
                            Text("uid \(process.userID)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .restricted(let reason)?, .disabled(let reason)?:
                    Text(reason).foregroundStyle(.secondary)
                case nil:
                    ProgressView()
                }
            }
            Section("Log") {
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.level.label) · \(entry.category)").font(.caption.weight(.semibold))
                        Text(entry.message).font(.footnote)
                        if !entry.metadata.isEmpty {
                            Text(entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !exportText.isEmpty { ShareLink("Export Log", item: exportText) }
            }
        }
        .navigationTitle("Diagnostics")
        .hcgScreenBackground()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await model.refreshAssessment()
        snapshot = SystemSnapshot.capture(sandboxURL: model.dependencies.workspace.rootURL)
        processes = await Task.detached { ProcessInspector.listProcesses() }.value
        entries = await DiagnosticLog.shared.recent()
        exportText = await DiagnosticLog.shared.exportText()
    }
}
#endif
