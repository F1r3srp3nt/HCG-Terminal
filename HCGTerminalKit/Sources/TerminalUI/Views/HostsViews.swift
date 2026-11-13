#if canImport(UIKit) && canImport(SwiftUI)
import BuildOrchestrator
import DeveloperWorkspace
import SwiftUI
import UIKit
import TerminalCore
import TerminalSecurity

struct HostsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var editing: HostProfile?

    var body: some View {
        List {
            Group {
                if model.hosts.isEmpty {
                    HCGEmptyState("No Hosts", systemImage: "server.rack", description: Text("Add your Mac or another SSH host to browse projects, build, test and run Claude Code remotely.")) {
                        Button { editing = HostProfile(name: "", hostname: "", username: "", auth: .password) } label: {
                            Label("Add Host", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                ForEach(model.hosts) { host in
                    NavigationLink {
                        HostDetailView(host: host)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(host.name)
                                if model.isConnected(host) { Circle().fill(HCGPalette.vanillaGreen).frame(width: 6, height: 6) }
                            }
                            Text(host.endpoint.address).font(.caption).foregroundStyle(HCGPalette.textSecondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await model.deleteHost(host) } }
                        Button("Edit") { editing = host }
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .navigationTitle("Hosts & Projects")
        .toolbar {
            Button { editing = HostProfile(name: "", hostname: "", username: "", auth: .password) } label: { Label("Add Host", systemImage: "plus") }
        }
        .sheet(item: $editing) { host in
            NavigationStack { HostEditor(host: host) }.environment(model)
        }
    }
}

/// Picks a host for a new remote session.
struct HostPickerView: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPick: (HostProfile) -> Void

    var body: some View {
        List(model.hosts) { host in
            Group {
                Button { onPick(host) } label: {
                    VStack(alignment: .leading) {
                        Text(host.name)
                        Text(host.endpoint.address).font(.caption).foregroundStyle(HCGPalette.textSecondary)
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .overlay {
            if model.hosts.isEmpty {
                HCGEmptyState("No Hosts", systemImage: "server.rack", description: Text("Add a host under Hosts & Projects first."))
            }
        }
        .navigationTitle("Remote Host Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct HostEditor: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: HostProfile
    @State private var password = ""
    @State private var portText = ""
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?
    @State private var showIssues = false

    private enum AuthChoice: String, CaseIterable { case password = "Password", key = "SSH key", keyThenPassword = "SSH key, then password" }
    @State private var authChoice: AuthChoice = .password
    @State private var keyID: UUID?

    private var passwordSaved: Bool {
        ((try? model.dependencies.credentials.load(.hostPassword(host.id))) ?? nil) != nil
    }

    private var draft: HostProfile {
        var updated = host
        updated.name = host.name.trimmingCharacters(in: .whitespaces)
        updated.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        updated.username = host.username.trimmingCharacters(in: .whitespaces)
        updated.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        switch authChoice {
        case .password: updated.auth = .password
        case .key: if let keyID { updated.auth = .key(keyID) }
        case .keyThenPassword: if let keyID { updated.auth = .keyThenPassword(keyID) }
        }
        return updated
    }

    private var issues: [HostProfileValidator.Field: String] {
        let auth: HostAuthMethod? = switch authChoice {
        case .password: .password
        case .key: keyID.map { .key($0) }
        case .keyThenPassword: keyID.map { .keyThenPassword($0) }
        }
        return HostProfileValidator.validate(
            name: host.name, hostname: host.hostname, port: portText, username: host.username, auth: auth,
            passwordEntered: !password.isEmpty, passwordSaved: passwordSaved,
            keyExists: keyID.map { id in model.keys.contains { $0.id == id } } ?? false
        )
    }

    var body: some View {
        Form {
            Group {
                Section {
                    field("Name", text: $host.name, prompt: "My Mac", issue: .name)
                    field("Hostname or IP", text: $host.hostname, prompt: "ana-mac.local or 192.168.1.20", issue: .hostname, keyboard: .URL)
                    field("Port", text: $portText, prompt: "22", issue: .port, keyboard: .numberPad)
                    field("Username", text: $host.username, prompt: "ana", issue: .username)
                    field("Projects folder", text: Binding(get: { host.projectsPath ?? "" }, set: { host.projectsPath = $0.isEmpty ? nil : $0 }), prompt: "~/Developer (optional)", issue: nil)
                } header: { Text("Host") } footer: {
                    Text("On a Mac, turn on System Settings → General → Sharing → Remote Login. Its local hostname is shown there too.")
                }

                Section {
                    Picker("Sign in with", selection: $authChoice) {
                        ForEach(AuthChoice.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    if authChoice != .key {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Password") {
                                SecureField(passwordSaved ? "Saved — leave empty to keep" : "Required", text: $password)
                                    .multilineTextAlignment(.trailing)
                            }
                            issueText(.password)
                        }
                    }
                    if authChoice != .password {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("Key", selection: $keyID) {
                                Text("Choose…").tag(UUID?.none)
                                ForEach(model.keys) { Text($0.comment.isEmpty ? $0.fingerprint : $0.comment).tag(UUID?.some($0.id)) }
                            }
                            issueText(.key)
                        }
                        NavigationLink("Manage SSH Keys") { KeysView() }
                    }
                } header: { Text("Authentication") } footer: {
                    Text("Passwords and private keys stay in this device's Keychain. Ed25519 keys are supported; add the public key to ~/.ssh/authorized_keys on the host.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text(testing ? "Testing…" : "Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !issues.isEmpty)
                    if let testResult { TestResultView(result: testResult) }
                } footer: {
                    Text("Connects with these settings, checks the shell and installed tools, and disconnects. Nothing is saved. A new host key is shown for you to verify first.")
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .navigationTitle(host.name.isEmpty ? "New Host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            portText = String(host.port)
            switch host.auth {
            case .password: authChoice = .password
            case .key(let id): authChoice = .key; keyID = id
            case .keyThenPassword(let id): authChoice = .keyThenPassword; keyID = id
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard issues.isEmpty else { showIssues = true; return }
                    Task {
                        await model.saveHost(draft, password: authChoice == .key ? nil : password)
                        dismiss()
                    }
                }
            }
        }
        .alert("Check these fields", isPresented: $showIssues) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(HostProfileValidator.Field.allCases.compactMap { issues[$0] }.joined(separator: "\n"))
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, issue: HostProfileValidator.Field?, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                TextField(label, text: text, prompt: Text(prompt))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(keyboard)
            }
            if let issue { issueText(issue) }
        }
    }

    @ViewBuilder
    private func issueText(_ field: HostProfileValidator.Field) -> some View {
        if let message = issues[field], fieldTouched(field) {
            Text(message).font(.caption).foregroundStyle(HCGPalette.warn)
        }
    }

    /// Shows a field's issue once the user has typed something anywhere, so a new form is not
    /// covered in warnings.
    private func fieldTouched(_ field: HostProfileValidator.Field) -> Bool {
        !host.name.isEmpty || !host.hostname.isEmpty || !host.username.isEmpty || showIssues
    }

    private func test() async {
        testing = true
        testResult = nil
        testResult = await model.testConnection(draft, enteredPassword: password.isEmpty ? nil : password)
        testing = false
    }
}

struct TestResultView: View {
    let result: ConnectionTestResult

    var body: some View {
        switch result {
        case .success(let system, let shell, let tools, let elapsed):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected in \(String(format: "%.1f", elapsed)) s", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(HCGPalette.vanillaGreen)
                Text("\(system) · login shell \(shell)").font(.caption)
                Text(ToolchainProbe.tools.map { "\($0) \(tools[$0] == nil ? "✗" : "✓")" }.joined(separator: "  "))
                    .font(.caption.monospaced()).foregroundStyle(HCGPalette.textSecondary)
            }
        case .failure(let category, let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(category, systemImage: "xmark.octagon.fill").foregroundStyle(HCGPalette.loss)
                Text(message).font(.caption)
            }
        }
    }
}

/// Actions for one host: shell, Claude Code, project browsing, toolchains.
struct HostDetailView: View {
    @Environment(TerminalAppModel.self) private var model
    let host: HostProfile
    @State private var toolchains: RemoteToolchains?
    @State private var probing = false

    var body: some View {
        List {
            Group {
                Section {
                    Button { Task { await model.openRemoteShell(host) } } label: { Label("Open Shell", systemImage: "terminal") }
                    NavigationLink { RemoteBrowserView(host: host, startPath: host.projectsPath ?? "~") } label: {
                        Label("Browse Projects", systemImage: "folder")
                    }
                    if model.isConnected(host) {
                        Button(role: .destructive) { Task { await model.disconnect(host) } } label: { Label("Disconnect", systemImage: "bolt.slash") }
                    }
                } header: { Text(host.endpoint.address) } footer: {
                    Text("Remote sessions run on \(host.name) and are independent of the local mode.")
                }
                Section("Toolchains") {
                    if let toolchains {
                        LabeledContent("System", value: toolchains.operatingSystem)
                        ForEach(ToolchainProbe.tools, id: \.self) { tool in
                            LabeledContent(tool, value: toolchains.tools[tool] ?? "not found")
                        }
                    } else {
                        Button(probing ? "Checking…" : "Check Installed Tools") { Task { await probe() } }.disabled(probing)
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .navigationTitle(host.name)
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        do { toolchains = try await ToolchainProbe.probe(model.connection(for: host)) } catch { model.errorMessage = error.localizedDescription }
    }
}

/// Browses a remote directory, recognises projects and starts builds, tests or Claude Code.
struct RemoteBrowserView: View {
    @Environment(TerminalAppModel.self) private var model
    let host: HostProfile
    let startPath: String
    @State private var directory = ""
    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var planning: ProjectKind?

    var body: some View {
        List {
            Group {
                let projects = ProjectDetector.detect(entries)
                if !projects.isEmpty {
                    Section("Project") {
                        ForEach(projects, id: \.self) { project in
                            Button { planning = project } label: { Label(project.label, systemImage: "hammer") }
                        }
                        Button { Task { await model.openClaudeCode(host, projectPath: directory) } } label: {
                            Label("Claude Code in This Folder", systemImage: "sparkles")
                        }
                    }
                }
                Section(directory) {
                    ForEach(entries) { entry in
                        if entry.kind == .directory || entry.kind == .symlink {
                            NavigationLink { RemoteBrowserView(host: host, startPath: entry.path) } label: { row(entry) }
                        } else {
                            row(entry)
                        }
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .overlay { if loading { ProgressView() } }
        .navigationTitle((directory as NSString).lastPathComponent.isEmpty ? "Projects" : (directory as NSString).lastPathComponent)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            Button { Task { await model.openClaudeCode(host, projectPath: directory.isEmpty ? startPath : directory) } } label: {
                Label("Claude Code", systemImage: "sparkles")
            }
        }
        .sheet(item: Binding(get: { planning.map(PlanningTarget.init) }, set: { planning = $0?.kind })) { target in
            NavigationStack { BuildPlanSheet(host: host, projectPath: directory, project: target.kind) }.environment(model)
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack {
            Image(systemName: entry.kind == .directory ? "folder" : entry.kind == .symlink ? "arrow.turn.up.right" : "doc")
                .foregroundStyle(entry.kind == .directory ? HCGPalette.vanillaBlue : HCGPalette.muted)
            Text(entry.name)
            Spacer()
            if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(HCGPalette.textSecondary) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await RemoteProjectBrowser(executor: model.connection(for: host)).list(directory.isEmpty ? startPath : directory)
            directory = result.directory
            entries = result.entries
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct PlanningTarget: Identifiable {
    let kind: ProjectKind
    var id: String { kind.label }
}
#endif
