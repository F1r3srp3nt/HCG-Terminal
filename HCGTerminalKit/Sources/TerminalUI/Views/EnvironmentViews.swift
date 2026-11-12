#if canImport(UIKit) && canImport(SwiftUI)
import Diagnostics
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// The layered environment assessment: build, device, bootstrap evidence, process identity and
/// real operations. "Jailbreak indicators" and "can run a shell" are shown separately.
struct EnvironmentAssessmentSections: View {
    let assessment: EnvironmentAssessment

    var body: some View {
        Section {
            LabeledContent("Variant", value: assessment.build.variant)
            LabeledContent("Unleashed backend", value: assessment.build.backendLinked ? "Linked" : "Not included")
            if !assessment.build.backendComponents.isEmpty {
                Text(assessment.build.backendComponents.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("1 · Build") }

        Section {
            LabeledContent("Model", value: assessment.device.model)
            LabeledContent("Architecture", value: assessment.device.architecture)
            LabeledContent("System", value: assessment.device.operatingSystem)
            LabeledContent("Kernel", value: assessment.device.kernel)
            if assessment.device.isSimulator { Text("Running in the iOS Simulator.").font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("2 · Device") }

        Section {
            LabeledContent("Jailbreak indicators", value: assessment.bootstrap.verdict.label)
            switch assessment.bootstrap.verdict {
            case .notChecked(let reason), .notObservable(let reason):
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .found:
                Text("Indicators show that bootstrap files exist. They do not show that this app may use them; see “Shell” below.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .noneFound:
                Text("None of the checked locations exist. This is not proof that the device is not jailbroken.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(assessment.bootstrap.roots.filter { $0.probe != .missing }, id: \.path) { root in
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.layout.label).font(.subheadline.weight(.semibold))
                    Text(root.path.isEmpty ? "/" : root.path).font(.caption.monospaced())
                    if let resolved = root.resolvedPath, resolved != root.path, !root.path.isEmpty {
                        Text("→ \(resolved)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(root.probe.description).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(assessment.bootstrap.indicators.filter { $0.probe != .missing }, id: \.path) { indicator in
                LabeledContent {
                    Text(indicator.probe.description).font(.caption)
                } label: {
                    Text(indicator.path).font(.caption.monospaced())
                    Text(indicator.strength == .strong ? "strong indicator" : "weak indicator").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(assessment.bootstrap.resolvedTools.keys.sorted(), id: \.self) { tool in
                LabeledContent(tool) {
                    Text(assessment.bootstrap.resolvedTools[tool] ?? "").font(.caption.monospaced()).multilineTextAlignment(.trailing)
                }
            }
        } header: { Text("3 · Bootstrap evidence") }

        Section {
            LabeledContent("User", value: "uid \(assessment.process.userID) · euid \(assessment.process.effectiveUserID) · gid \(assessment.process.groupID)")
            LabeledContent("Container", value: assessment.process.containerized ? "App container (sandboxed)" : "Not an app container")
            LabeledContent("Installed via", value: assessment.process.installRoute.label)
            if !assessment.process.deniedProbes.isEmpty {
                Text("Refused by the system: \(assessment.process.deniedProbes.joined(separator: ", "))").font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("4 · This app's process") }

        Section {
            LabeledContent("Shell", value: assessment.shell.label)
            switch assessment.shell {
            case .verified(let s), .permissionDenied(let s), .availableUntested(let s), .toolMissing(let s), .unknown(let s):
                Text(s).font(.footnote).foregroundStyle(.secondary)
            case .notIncluded, .disabledByUser:
                EmptyView()
            }
            if assessment.operations.isEmpty {
                Text("No explicit test has run in this app session.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(assessment.operations.indices, id: \.self) { index in
                let operation = assessment.operations[index]
                VStack(alignment: .leading, spacing: 2) {
                    Label(operation.name, systemImage: operation.succeeded ? "checkmark.seal" : "xmark.octagon")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(operation.succeeded ? HCGPalette.ok : HCGPalette.warn)
                    Text(operation.outcome).font(.footnote)
                }
            }
        } header: { Text("5 · What actually happened") }
    }
}

/// Unleashed build: the assessment plus explicit, bounded tests and a custom bootstrap root.
struct UnleashedEnvironmentView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var roots: [String] = []
    @State private var customRoot = ""
    @State private var writeTarget = ""
    @State private var running = false

    private var tools: (any UnleashedTools)? { model.dependencies.unleashedTools }

    var body: some View {
        List {
            Section {
                Button {
                    run { _ = await $0.verifyShell() }
                } label: { Label("Run Shell Test", systemImage: "terminal") }
                .disabled(running || !model.dependencies.access.isEnabled(.localShell))
                Text("Starts the detected shell once with `printf HCG_SHELL_OK; id -u`, limited to 5 seconds. Nothing else is run.")
                    .font(.footnote).foregroundStyle(.secondary)

                Picker("Write test location", selection: $writeTarget) {
                    Text("Choose…").tag("")
                    ForEach(roots, id: \.self) { Text($0).tag($0) }
                }
                Button {
                    let target = writeTarget
                    run { _ = await $0.verifyWrite(in: target) }
                } label: { Label("Run Write Test", systemImage: "square.and.pencil") }
                .disabled(running || writeTarget.isEmpty || !model.dependencies.access.isEnabled(.expandedFileWrite))
                Text(model.dependencies.access.isEnabled(.expandedFileWrite)
                     ? "Creates one hidden test file, reads it back and deletes it. System and jailbreak locations ask first."
                     : "Turn on “Expanded filesystem: write” in Capabilities & Access to run this test.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Explicit tests") } footer: {
                Text("Detection is read-only. Only these buttons execute or write anything, and only when you tap them.")
            }

            Section {
                TextField("/private/preboot/…/procursus", text: $customRoot)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Save and Re-check") {
                    let value = customRoot
                    Task {
                        await tools?.setCustomBootstrapRoots(value.isEmpty ? [] : [value])
                        await model.refreshCapabilities()
                        await model.refreshAssessment()
                    }
                }
            } header: { Text("Custom bootstrap root") } footer: {
                Text("For relocated installs the scan cannot find. The path is only checked read-only, like the built-in locations.")
            }

            if let assessment = model.assessment {
                EnvironmentAssessmentSections(assessment: assessment)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Unleashed Environment")
        .hcgScreenBackground()
        .task {
            roots = await tools?.permittedRoots() ?? []
            customRoot = (await tools?.customBootstrapRoots() ?? []).first ?? ""
            await model.refreshAssessment()
        }
        .refreshable { await model.refreshAssessment() }
        .overlay { if running { ProgressView() } }
    }

    private func run(_ action: @escaping (any UnleashedTools) async -> Void) {
        guard let tools else { return }
        running = true
        Task {
            await action(tools)
            await model.refreshCapabilities()
            await model.refreshAssessment()
            if model.assessment?.operations.last.map({ $0.succeeded && $0.name.hasPrefix("Write test") }) == true {
                model.noteWriteVerified()
            }
            running = false
        }
    }
}

/// Installed programs (Unleashed). Each can be run with a time limit or opened in a terminal.
struct ProgramsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var tools: [ToolRow] = []
    @State private var filter = ""
    @State private var loaded = false

    var body: some View {
        List {
            if let refusal = model.dependencies.access.denial(.localShell) {
                Section { Text(refusal).foregroundStyle(HCGPalette.warn) }
            } else if loaded && tools.isEmpty {
                Section { Text("No program folder is visible to this app.").foregroundStyle(.secondary) }
            }
            ForEach(tools.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.prefix(500)) { tool in
                NavigationLink {
                    ToolRunView(tool: tool)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.body.monospaced())
                        Text(tool.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter programs")
        .navigationTitle("Programs")
        .hcgScreenBackground()
        .task {
            tools = await model.dependencies.unleashedTools?.installedTools() ?? []
            loaded = true
        }
    }
}

/// Runs one program: bounded (output shown here) or interactive (new terminal session).
struct ToolRunView: View {
    @Environment(TerminalAppModel.self) private var model
    let tool: ToolRow
    @State private var arguments = ""
    @State private var output: ToolRunOutput?
    @State private var error: String?
    @State private var running = false

    var body: some View {
        List {
            Section {
                TextField("Arguments", text: $arguments)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button { Task { await run() } } label: { Label("Run (20 s limit)", systemImage: "play") }
                    .disabled(running)
                Button { Task { await openSession() } } label: { Label("Open in Terminal Session", systemImage: "terminal") }
                    .disabled(running)
            } header: { Text(tool.path) } footer: {
                Text("Runs with this app's permissions. Privileged commands are refused or need your approval, depending on Capabilities & Access. Arguments are split on spaces; use a terminal session for quoting.")
            }
            if let error {
                Section { Text(error).foregroundStyle(HCGPalette.warn) }
            }
            if let output {
                Section("Result") {
                    Label(output.summary, systemImage: output.succeeded ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(output.succeeded ? HCGPalette.ok : HCGPalette.warn)
                    if !output.stdout.isEmpty {
                        Text(output.stdout).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !output.stderr.isEmpty {
                        Text(output.stderr).font(.caption.monospaced()).foregroundStyle(HCGPalette.warn).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(tool.name)
        .navigationBarTitleDisplayMode(.inline)
        .hcgScreenBackground()
        .overlay { if running { ProgressView() } }
    }

    private var argumentList: [String] {
        arguments.split(separator: " ").map(String.init)
    }

    private func run() async {
        guard let tools = model.dependencies.unleashedTools else { return }
        running = true
        defer { running = false }
        do {
            output = try await tools.runTool(tool.path, arguments: argumentList)
            error = nil
            await model.refreshCapabilities()
        } catch {
            self.error = error.localizedDescription
            output = nil
            await model.refreshCapabilities()
        }
    }

    private func openSession() async {
        guard let tools = model.dependencies.unleashedTools else { return }
        do {
            let session = try await tools.toolSession(tool.path, arguments: argumentList)
            await model.openPreparedSession(session, title: tool.name)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Process table as far as the system shows it (and only while process inspection is on).
struct ProcessListView: View {
    @State private var listing: ProcessListing?
    @State private var filter = ""

    var body: some View {
        List {
            switch listing {
            case .listed(let processes, let complete)?:
                if !complete {
                    Text("The system shows only part of the process table to this app.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(processes.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.prefix(1000)) { process in
                    HStack {
                        Text("\(process.pid)").font(.caption.monospaced()).frame(minWidth: 56, alignment: .leading)
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text("uid \(process.userID)").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            case .restricted(let reason)?, .disabled(let reason)?:
                Text(reason).foregroundStyle(.secondary)
            case nil:
                ProgressView()
            }
        }
        .searchable(text: $filter, prompt: "Filter processes")
        .navigationTitle("Processes")
        .hcgScreenBackground()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        listing = await Task.detached { ProcessInspector.listProcesses() }.value
    }
}
#endif
