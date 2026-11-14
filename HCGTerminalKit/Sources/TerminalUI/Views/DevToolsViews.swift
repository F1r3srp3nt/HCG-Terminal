#if canImport(UIKit) && canImport(SwiftUI)
import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import Diagnostics
import SwiftUI
import TerminalCore
import UIKit

// MARK: - Shared pieces

/// Where something ran. Shown on every diagnostic, job, log line and artifact.
struct ExecutionHostLabel: View {
    let context: ExecutionContext

    var body: some View {
        Label(context.label, systemImage: context == .thisDevice ? "iphone" : "server.rack")
            .font(.caption.weight(.semibold))
            .foregroundStyle(HCGPalette.textSecondary)
            .lineLimit(2)
            .accessibilityLabel("Runs on \(context.label)")
    }
}

extension DoctorCheck.Status {
    var color: Color {
        switch self {
        case .passed: HCGPalette.ok
        case .warning: HCGPalette.warn
        case .blocked: HCGPalette.loss
        case .unknown: HCGPalette.textSecondary
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension HostJobState {
    var color: Color {
        switch self {
        case .succeeded: HCGPalette.ok
        case .starting, .running: HCGPalette.accentPrimary
        case .cancelled: HCGPalette.textSecondary
        case .failed, .lost, .couldNotStart: HCGPalette.loss
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .starting, .running: "hammer"
        case .cancelled: "stop.circle"
        case .failed, .couldNotStart: "xmark.octagon.fill"
        case .lost: "questionmark.diamond"
        }
    }
}

extension ConsoleSeverity {
    var color: Color {
        switch self {
        case .error: HCGPalette.loss
        case .warning: HCGPalette.warn
        case .notice: HCGPalette.accentSecondary
        case .info, .debug: HCGPalette.textPrimary
        }
    }
}

// MARK: - Doctor

/// Read-only diagnostics for one project on one host.
struct DoctorView: View {
    @Environment(TerminalAppModel.self) private var model
    let host: HostProfile
    let projectPath: String
    let project: ProjectKind?
    @State private var scheme = ""
    @State private var schemes: [String] = []
    @State private var expanded: Set<String> = []
    @State private var showBuild = false

    private var tools: DevToolsCenter { model.devTools }
    private var key: String { DevToolsCenter.doctorKey(hostID: host.id, projectPath: projectPath) }
    private var report: DoctorReport? { tools.doctorReports[key] }
    private var running: Bool { tools.doctorRunning.contains(key) }
    private var isXcode: Bool {
        switch project {
        case .xcodeProject?, .xcodeWorkspace?: true
        default: false
        }
    }

    var body: some View {
        List {
            Group {
                Section {
                    ExecutionHostLabel(context: tools.context(for: host.id))
                    LabeledContent("Project", value: projectPath)
                    LabeledContent("Type", value: project?.label ?? "Folder")
                    if isXcode {
                        Picker("Scheme", selection: $scheme) {
                            Text("Not chosen").tag("")
                            ForEach(schemes, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button { Task { await run() } } label: {
                        Label(running ? "Checking…" : (report == nil ? "Run Doctor" : "Run Again"), systemImage: "stethoscope")
                    }
                    .disabled(running)
                } footer: {
                    Text("Doctor only reads: it runs version queries and listings in your login shell on \(host.name), the same environment builds use. It installs nothing and changes no settings.")
                }

                if let error = tools.doctorErrors[key] {
                    Section {
                        Label(error, systemImage: "bolt.horizontal.circle").foregroundStyle(HCGPalette.warn)
                        Button("Try Again") { Task { await run() } }
                    } header: { Text("Could not reach \(host.name)") }
                }

                if let report {
                    Section {
                        ForEach(report.outputs, id: \.self) { output in
                            let blockers = report.blockers(for: output)
                            let warnings = report.warnings(for: output)
                            HStack {
                                Image(systemName: blockers.isEmpty ? (warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "xmark.octagon.fill")
                                    .foregroundStyle(blockers.isEmpty ? (warnings.isEmpty ? HCGPalette.ok : HCGPalette.warn) : HCGPalette.loss)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(output.label)
                                    Text(blockers.isEmpty ? (warnings.isEmpty ? "No blockers found" : "\(warnings.count) to check") : "Blocked by \(blockers.map(\.title).joined(separator: ", "))")
                                        .font(.caption).foregroundStyle(HCGPalette.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button { showBuild = true } label: { Label("Build & Install…", systemImage: "hammer") }
                            .disabled(!host.remoteBuildsAllowed)
                    } header: {
                        Text("Outputs")
                    } footer: {
                        Text("Checked \(report.ranAt.formatted(date: .abbreviated, time: .shortened))\(report.scheme.map { " for scheme \($0)" } ?? "")." + (report.complete ? "" : " The check did not finish; missing results are shown as unknown."))
                    }

                    ForEach(DoctorCheck.Status.allCases.reversed(), id: \.self) { status in
                        let checks = report.checks.filter { $0.status == status }
                        if !checks.isEmpty {
                            Section(status.label) {
                                ForEach(checks) { check in DoctorCheckRow(check: check, expanded: expandedBinding(check.id)) }
                            }
                        }
                    }
                } else if !running && tools.doctorErrors[key] == nil {
                    Section {
                        Text("Doctor has not run for this project yet.").foregroundStyle(HCGPalette.textSecondary)
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .overlay { if running && report == nil { ProgressView("Running checks on \(host.name)…") } }
        .navigationTitle("Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSchemes() }
        .sheet(isPresented: $showBuild) {
            NavigationStack { BuildInstallSheet(host: host, projectPath: projectPath, project: project, report: report) }
                .environment(model)
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func run() async {
        await tools.runDoctor(host: host, projectPath: projectPath, project: project, scheme: scheme.isEmpty ? nil : scheme)
        if let report, schemes.isEmpty { schemes = report.schemes }
        // Doctor needs a scheme for build settings; choose the first and check again once.
        if isXcode, scheme.isEmpty, let first = report?.schemes.first {
            scheme = first
            await tools.runDoctor(host: host, projectPath: projectPath, project: project, scheme: first)
        }
    }

    private func loadSchemes() async {
        if let report { schemes = report.schemes; scheme = report.scheme ?? report.schemes.first ?? "" }
        guard isXcode, schemes.isEmpty, let project, let command = XcodeSchemeLister.command(projectDirectory: projectPath, container: project) else { return }
        if let result = try? await model.connection(for: host).run(command) {
            schemes = XcodeSchemeLister.parse(result.stdout)
            if scheme.isEmpty { scheme = schemes.first ?? "" }
        }
    }
}

struct DoctorCheckRow: View {
    let check: DoctorCheck
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let presence = check.presence {
                    LabeledContent("State", value: presence.label).font(.footnote)
                }
                ForEach(check.evidence, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(.caption.weight(.semibold)).foregroundStyle(HCGPalette.textSecondary)
                        Text(item.value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if !check.affects.isEmpty {
                    Text("Affects: " + check.affects.map(\.label).joined(separator: ", ")).font(.caption).foregroundStyle(HCGPalette.textSecondary)
                }
                ForEach(check.nextSteps, id: \.self) { step in
                    Label(step, systemImage: "arrow.right.circle").font(.footnote).textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: check.status.symbol).foregroundStyle(check.status.color).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title).font(.subheadline.weight(.semibold))
                    Text(check.summary).font(.caption).foregroundStyle(HCGPalette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(check.title), \(check.status.label). \(check.summary)")
        }
    }
}

// MARK: - Build & Install plan

/// Chooses output, scheme, configuration and signing, previews the exact plan, then starts a
/// detached job on the host.
struct BuildInstallSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    let projectPath: String
    let project: ProjectKind?
    let report: DoctorReport?

    enum Engine: String, CaseIterable, Identifiable {
        case executableMaker = "HCG Executable Maker"
        case direct = "Direct build"
        var id: String { rawValue }
    }

    @State private var output: BuildOutput?
    @State private var engine: Engine = .executableMaker
    @State private var configuration: BuildConfiguration = .debug
    @State private var scheme = ""
    @State private var signingMode: ExecutableMakerSigning.Mode = .project
    @State private var team = ""
    @State private var profile = ""
    @State private var export: ExecutableMakerSigning.Export = .debugging
    @State private var startedJob: UUID?

    private var outputs: [BuildOutput] { report?.outputs ?? [] }

    var body: some View {
        Form {
            Group {
                Section {
                    ExecutionHostLabel(context: model.devTools.context(for: host.id))
                    LabeledContent("Project", value: projectPath)
                    if report == nil {
                        Label("Run Doctor first: the plan uses the tools and paths it found.", systemImage: "stethoscope").foregroundStyle(HCGPalette.warn)
                    }
                }
                if !outputs.isEmpty {
                    Section("Output") {
                        Picker("Output", selection: $output) {
                            ForEach(outputs, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }
                        if let output, output.usesExecutableMaker {
                            Picker("Engine", selection: $engine) { ForEach(Engine.allCases) { Text($0.rawValue).tag($0) } }
                        }
                        Picker("Configuration", selection: $configuration) { ForEach(BuildConfiguration.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if !(report?.schemes.isEmpty ?? true), engine == .direct || !(output?.usesExecutableMaker ?? false) {
                            Picker("Scheme", selection: $scheme) { ForEach(report?.schemes ?? [], id: \.self) { Text($0).tag($0) } }
                        }
                    }
                    if let output, output.usesExecutableMaker, engine == .executableMaker, output != .iosSimulatorApp {
                        Section {
                            Picker("Signing", selection: $signingMode) {
                                ForEach(ExecutableMakerSigning.Mode.allCases.filter { output == .iosIPA ? $0 != .unsigned : true }, id: \.self) { Text($0.label).tag($0) }
                            }
                            if signingMode == .automatic || signingMode == .manual {
                                TextField("Team ID", text: $team).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            }
                            if signingMode == .manual {
                                Picker("Profile", selection: $profile) {
                                    Text("Choose").tag("")
                                    ForEach(matchingProfiles, id: \.self) { Text($0.name).tag($0.name) }
                                }
                            }
                            if output == .iosIPA {
                                Picker("Export", selection: $export) { ForEach(ExecutableMakerSigning.Export.allCases, id: \.self) { Text($0.label).tag($0) } }
                            }
                        } header: { Text("Signing") } footer: {
                            Text("Uses signing assets already on \(host.name); nothing is exported or uploaded. App Store export is not offered.")
                        }
                    }
                }
                planSection
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .navigationTitle("Build & Install")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if output == nil { output = outputs.first }
            if scheme.isEmpty { scheme = report?.scheme ?? report?.schemes.first ?? "" }
            if team.isEmpty { team = report?.environment.developmentTeam ?? "" }
            if report?.environment.executableMakerPath == nil { engine = .direct }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    guard let plan = try? makePlan() else { return }
                    Task {
                        startedJob = await model.devTools.start(plan, doctorReportID: report?.id)
                    }
                }
                .disabled((try? makePlan()) == nil || !blockers.isEmpty || startedJob != nil)
            }
        }
        .navigationDestination(item: $startedJob) { id in JobDetailView(jobID: id) }
    }

    private var matchingProfiles: [ProvisioningProfileInfo] {
        let bundle = report?.environment.bundleIdentifier
        return (report?.environment.profiles ?? []).filter { bundle == nil || $0.covers(bundleID: bundle!) }.filter { !$0.isExpired() }
    }

    private var blockers: [DoctorCheck] {
        guard let report, let output else { return [] }
        return report.blockers(for: output).filter { engine == .executableMaker || $0.id != "executable-maker" }
    }

    @ViewBuilder
    private var planSection: some View {
        Section {
            switch Result(catching: makePlan) {
            case .success(let plan):
                LabeledContent("Runs on", value: "\(host.name) · \(host.endpoint.address)")
                LabeledContent("Engine", value: engineDescription(plan))
                LabeledContent("Environment", value: "Login shell \(report?.environment.shell ?? "of \(host.username)") (same as Doctor)")
                if let path = report?.environment.path {
                    Text("PATH: \(path)").font(.system(.caption2, design: .monospaced)).foregroundStyle(HCGPalette.textSecondary).lineLimit(3)
                }
                Text(plan.commandLine).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                ForEach(blockers) { check in
                    Label("\(check.title): \(check.summary)", systemImage: "xmark.octagon.fill").foregroundStyle(HCGPalette.loss).font(.footnote)
                }
                if let output, let warnings = report?.warnings(for: output), !warnings.isEmpty {
                    ForEach(warnings) { check in
                        Label("\(check.title): \(check.summary)", systemImage: check.status.symbol).foregroundStyle(check.status.color).font(.footnote)
                    }
                }
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(HCGPalette.warn)
            }
        } header: { Text("Plan") } footer: {
            Text("Runs as a job on \(host.name) that keeps going if this phone disconnects. HCG Terminal reattaches to it and never starts it twice. Nothing is uploaded, published or installed automatically.")
        }
    }

    private func engineDescription(_ plan: BuildPlan) -> String {
        switch plan.system {
        case .executableMaker(let build): "HCG Executable Maker at \(build.toolPath)" + (report?.environment.executableMakerRevision.map { " (\($0))" } ?? "")
        case .theos: "Theos make (\(report?.environment.gnuMake ?? "make"))"
        case .xcodeProject, .xcodeWorkspace: "xcodebuild"
        case .swiftPackage: "swift build"
        case .dotnet: "dotnet"
        }
    }

    private func makePlan() throws -> BuildPlan {
        guard let output else { throw BuildPlanError.unsupported(report == nil ? "Run Doctor first." : "This project has no buildable output.") }
        let system: BuildSystem
        switch output {
        case .iosSimulatorApp, .iosArchive, .iosIPA, .macApp:
            if output.usesExecutableMaker, engine == .executableMaker {
            guard let toolPath = report?.environment.executableMakerPath else { throw BuildPlanError.unsupported("HCG Executable Maker was not found on \(host.name). Choose Direct build or set its folder in the host's settings.") }
            let signing = ExecutableMakerSigning(
                mode: output == .iosSimulatorApp ? .project : signingMode,
                team: team.isEmpty ? nil : team, profile: profile.isEmpty ? nil : profile, export: output == .iosIPA ? export : nil
            )
            system = .executableMaker(ExecutableMakerBuild(output: output, toolPath: toolPath, scheme: report?.scheme, signing: signing))
            } else {
            guard !scheme.isEmpty else { throw BuildPlanError.unsupported("Choose a scheme.") }
            let destination: XcodeDestination = switch output {
            case .macApp: .macOS
            case .iosSimulatorApp: .custom("generic/platform=iOS Simulator")
            default: .genericIOS
            }
            switch project {
            case .xcodeWorkspace(let name)?: system = .xcodeWorkspace(name: name, scheme: scheme, destination: destination)
            case .xcodeProject(let name)?: system = .xcodeProject(name: name, scheme: scheme, destination: destination)
            default: throw BuildPlanError.unsupported("Not an Xcode project.")
            }
            }
        case .swiftPackage: system = .swiftPackage
        case .dotnet:
            switch project {
            case .dotnetSolution(let name)?, .dotnetProject(let name)?: system = .dotnet(target: name)
            default: system = .dotnet(target: nil)
            }
        case .theosPackage: system = .theos
        }
        return try BuildPlanner.plan(host: host, projectPath: projectPath, system: system, action: .build, configuration: configuration, gnuMake: report?.environment.gnuMake)
    }
}

// MARK: - Jobs

struct JobRow: View {
    @Environment(TerminalAppModel.self) private var model
    let job: HostJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.state.symbol).foregroundStyle(job.state.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.plan.title).lineLimit(1)
                Text("\(job.plan.hostName) · job \(job.shortID) · \(statusText)")
                    .font(.caption).foregroundStyle(HCGPalette.textSecondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if job.state.isActive {
            switch model.devTools.links[job.id] {
            case .reconnecting?: return "running on host · reconnecting"
            case .disconnected?: return "running on host · not connected"
            default: return job.state.label
            }
        }
        return job.state.label
    }
}

/// One job: live status, connection state, first failure, log and artifacts.
struct JobDetailView: View {
    @Environment(TerminalAppModel.self) private var model
    let jobID: UUID
    @State private var confirmCancel = false
    @State private var confirmRemove = false
    @State private var installing: JobArtifact?

    private var tools: DevToolsCenter { model.devTools }

    var body: some View {
        Group {
            if let job = tools.job(jobID) {
                content(job)
            } else {
                HCGEmptyState("Job Not Found", systemImage: "questionmark.folder", description: Text("It may have been removed."))
            }
        }
        .hcgScreenBackground()
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
        .task { await tools.reload() }
    }

    @ViewBuilder
    private func content(_ job: HostJob) -> some View {
        List {
            Group {
                Section {
                    HStack {
                        Image(systemName: job.state.symbol).foregroundStyle(job.state.color).accessibilityHidden(true)
                        Text(job.state.label).font(.headline)
                    }
                    ExecutionHostLabel(context: tools.context(for: job.plan.hostID))
                    LabeledContent("Job", value: job.id.uuidString.lowercased()).font(.caption.monospaced())
                    LabeledContent("Project", value: job.plan.projectPath)
                    LabeledContent("Started", value: job.createdAt.formatted(date: .abbreviated, time: .standard))
                    if let finished = job.finishedAt {
                        LabeledContent("Duration", value: Duration.seconds(finished.timeIntervalSince(job.createdAt)).formatted(.units(allowed: [.hours, .minutes, .seconds])))
                    }
                    if let em = job.executableMakerBuildID { LabeledContent("Executable Maker build", value: em).font(.caption.monospaced()) }
                    Text(job.plan.commandLine).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } header: { Text(job.plan.title) }

                if job.state.isActive {
                    Section {
                        linkStatus(job)
                        Button(role: .destructive) { confirmCancel = true } label: { Label(tools.cancelling.contains(job.id) ? "Stopping…" : "Stop Build", systemImage: "stop.circle") }
                            .disabled(tools.cancelling.contains(job.id))
                    } header: { Text("Connection") } footer: {
                        Text("The build runs on \(job.plan.hostName) independently of this phone. Losing the connection does not stop or fail it.")
                    }
                }

                if let failure = job.firstFailure {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(failure.before.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(HCGPalette.textSecondary) }
                            Text(failure.line).foregroundStyle(HCGPalette.loss).fontWeight(.semibold)
                            ForEach(Array(failure.after.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(HCGPalette.textSecondary) }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    } header: { Text(failure.isSummaryOnly ? "Failure (no specific cause found)" : "First failure") } footer: {
                        if failure.isSummaryOnly { Text("Only a generic summary line was found. Read the full log for the cause.") }
                    }
                }

                if !job.artifacts.isEmpty {
                    Section("Artifacts") {
                        ForEach(job.artifacts) { artifact in
                            ArtifactRow(artifact: artifact, job: job) { installing = artifact }
                        }
                    }
                } else if job.state == .succeeded {
                    Section("Artifacts") { Text("The build finished, but no products were found in the expected folders.").foregroundStyle(HCGPalette.textSecondary) }
                }

                Section {
                    NavigationLink { LogConsoleView(jobFilter: job.shortID, title: "Job \(job.shortID)") } label: {
                        Label("Live Log", systemImage: "text.alignleft")
                    }
                    JobLogShareLink(job: job)
                } header: { Text("Log") } footer: {
                    Text("The full log is kept on this device (credentials removed) and on \(job.plan.hostName) in ~/.hcg-terminal/jobs.")
                }

                if !job.state.isActive {
                    Section {
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove Job from Host", systemImage: "trash") }
                    } footer: { Text("Deletes the job's folder (log and packed products) on \(job.plan.hostName).") }
                }
            }
            .hcgRows()
        }
        .confirmationDialog("Stop this build on \(job.plan.hostName)?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop Build", role: .destructive) { Task { await tools.cancel(job.id) } }
        } message: { Text("The host sends it TERM, then KILL after 15 seconds.") }
        .confirmationDialog("Remove job \(job.shortID) from \(job.plan.hostName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await tools.remove(job.id) } }
        }
        .sheet(item: $installing) { artifact in
            NavigationStack { InstallSheet(artifact: artifact, job: job) }.environment(model)
        }
    }

    @ViewBuilder
    private func linkStatus(_ job: HostJob) -> some View {
        switch tools.links[job.id] {
        case .following?, nil where job.state == .running:
            Label("Following live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(HCGPalette.accentPrimary)
        case .reconnecting(let attempt, let at)?:
            Label("Connection lost. Reconnecting (attempt \(attempt)) \(at.formatted(.relative(presentation: .named)))…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(HCGPalette.warn)
        case .disconnected(let reason)?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Not connected: \(reason)", systemImage: "bolt.horizontal.circle").foregroundStyle(HCGPalette.warn)
                Button("Reattach") { tools.reattach(job.id) }
            }
        default:
            Label(job.state == .starting ? "Sending to \(job.plan.hostName)…" : "Waiting for the host…", systemImage: "clock")
        }
        if let error = tools.jobErrors[job.id] {
            Text(error).font(.caption).foregroundStyle(HCGPalette.textSecondary)
        }
        Text("\(ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)) of log received" + (job.lastContact.map { " · last contact \($0.formatted(date: .omitted, time: .standard))" } ?? ""))
            .font(.caption).foregroundStyle(HCGPalette.textSecondary)
    }
}

struct JobLogShareLink: View {
    @Environment(TerminalAppModel.self) private var model
    let job: HostJob
    @State private var url: URL?

    var body: some View {
        Group {
            if let url { ShareLink(item: url) { Label("Export Full Log", systemImage: "square.and.arrow.up") } }
        }
        .task(id: job.receivedBytes) { url = await model.devTools.logURL(for: job) }
    }
}

struct ArtifactRow: View {
    @Environment(TerminalAppModel.self) private var model
    let artifact: JobArtifact
    let job: HostJob
    let onInstall: () -> Void

    var body: some View {
        let tools: DevToolsCenter = model.devTools
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(artifact.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file)).font(.caption).foregroundStyle(HCGPalette.textSecondary)
            }
            Text(artifact.kind.label + (artifact.wasPacked ? " · packed for download" : "") + (artifact.verification.map { " · Executable Maker: \($0)" } ?? ""))
                .font(.caption).foregroundStyle(HCGPalette.textSecondary)
            Text("SHA-256 \(artifact.sha256)").font(.caption2.monospaced()).foregroundStyle(HCGPalette.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text("Job \(job.shortID) on \(job.plan.hostName)").font(.caption2).foregroundStyle(HCGPalette.textSecondary)
            HStack {
                if let progress = tools.downloads[artifact.id] {
                    ProgressView(value: progress)
                } else if let record = tools.downloaded[artifact.id], let url = tools.localURL(record) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                } else {
                    Button { Task { _ = await tools.download(artifact, from: job) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
                Spacer()
                Button { onInstall() } label: { Label("Next Step…", systemImage: "arrow.right.circle") }
            }
            .buttonStyle(.borderless)
            if let attempt = tools.installs[artifact.id] { InstallStateLine(state: attempt.state) }
        }
        .padding(.vertical, 2)
    }
}

struct InstallStateLine: View {
    let state: InstallAttempt.State

    var body: some View {
        switch state {
        case .running(let text): Label(text, systemImage: "clock").font(.caption)
        case .installed(let text): Label(text, systemImage: "checkmark.circle").font(.caption).foregroundStyle(HCGPalette.ok)
        case .launched(let text): Label(text, systemImage: "play.circle.fill").font(.caption).foregroundStyle(HCGPalette.ok)
        case .handedOff(let text): Label(text, systemImage: "arrow.uturn.right.circle").font(.caption).foregroundStyle(HCGPalette.accentSecondary)
        case .failed(let text): Label(text, systemImage: "xmark.octagon").font(.caption).foregroundStyle(HCGPalette.loss)
        }
    }
}

// MARK: - Install

/// The next step for one artifact: only methods the artifact, its signing and the visible
/// devices support. Each needs confirmation; outcomes are what the host confirmed.
struct InstallSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let artifact: JobArtifact
    let job: HostJob
    @State private var options: InstallOptions?
    @State private var pending: InstallOptions.Option?

    var body: some View {
        List {
            Group {
                Section {
                    LabeledContent("Artifact", value: artifact.name)
                    LabeledContent("Type", value: artifact.kind.label)
                    ExecutionHostLabel(context: model.devTools.context(for: job.plan.hostID))
                    if let bundle = artifact.bundleIdentifier { LabeledContent("Bundle ID", value: bundle) }
                    if let minimum = artifact.minimumOS { LabeledContent("Minimum OS", value: minimum) }
                }
                if let options {
                    if !options.compatibility.isEmpty {
                        Section("Where it runs") { ForEach(options.compatibility, id: \.self) { Text($0).font(.footnote) } }
                    }
                    Section("Available") {
                        ForEach(options.options) { option in
                            Button { pending = option } label: { Label(title(option), systemImage: symbol(option)) }
                        }
                    }
                    if !options.notOffered.isEmpty {
                        Section("Not offered") {
                            ForEach(options.notOffered, id: \.self) { Text($0).font(.footnote).foregroundStyle(HCGPalette.textSecondary) }
                        }
                    }
                    if let attempt = model.devTools.installs[artifact.id] {
                        Section("Result") { InstallStateLine(state: attempt.state) }
                    }
                }
            }
            .hcgRows()
        }
        .hcgScreenBackground()
        .overlay { if options == nil { ProgressView("Checking \(job.plan.hostName)…") } }
        .navigationTitle("Next Step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { options = await model.devTools.installOptions(for: artifact, job: job) }
        .confirmationDialog(pending.map(title) ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let option = pending {
                Button(confirmLabel(option)) {
                    let chosen = option
                    pending = nil
                    Task { await model.devTools.install(chosen, artifact: artifact, job: job, model: model) }
                }
            }
        } message: {
            if let option = pending { Text(confirmMessage(option)) }
        }
    }

    private func title(_ option: InstallOptions.Option) -> String {
        switch option {
        case .download: "Download to This Device"
        case .simulator(let device, let host): "Install and Launch in \(device.name) (\(device.runtime)) on \(host)"
        case .deviceThroughHost(let device, let host): "Install on \(device.name) through \(host)"
        case .jailbreakPackage: "Install Package on This Device (dpkg)"
        }
    }

    private func symbol(_ option: InstallOptions.Option) -> String {
        switch option {
        case .download: "arrow.down.circle"
        case .simulator: "iphone.gen3"
        case .deviceThroughHost: "cable.connector"
        case .jailbreakPackage: "shippingbox"
        }
    }

    private func confirmLabel(_ option: InstallOptions.Option) -> String {
        switch option {
        case .download: "Download"
        case .simulator: "Install and Launch"
        case .deviceThroughHost, .jailbreakPackage: "Install"
        }
    }

    private func confirmMessage(_ option: InstallOptions.Option) -> String {
        switch option {
        case .download: "Saves \(artifact.name) in the workspace under /artifacts and checks its SHA-256 against the host."
        case .simulator(_, let host): "Boots the Simulator on \(host) if needed, installs the app there and launches it."
        case .deviceThroughHost(let device, let host): "Runs `xcrun devicectl device install app` on \(host) for \(device.name)."
        case .jailbreakPackage: "Downloads the package, asks for approval, then runs dpkg in a visible Local Unleashed session. The device is not resprung."
        }
    }
}

// MARK: - Log Console

/// Live, bounded, redacted output from Doctor, builds, installs and the app itself.
struct LogConsoleView: View {
    @Environment(TerminalAppModel.self) private var model
    var jobFilter: String?
    var title = "Log Console"
    @State private var search = ""
    @State private var minimum: ConsoleSeverity = .debug
    @State private var sources: Set<ConsoleSource> = Set(ConsoleSource.allCases)
    @State private var paused = false
    @State private var frozen: [ConsoleLine] = []
    @State private var exportURL: URL?

    private var live: [ConsoleLine] {
        model.devTools.console.filtered(search: search, minimumSeverity: minimum, sources: sources, job: jobFilter)
    }

    var body: some View {
        let shown = paused ? frozen : live
        let newWhilePaused = paused ? max(0, live.count - frozen.count) : 0
        VStack(spacing: 0) {
            if let failure = jobFilter.flatMap({ model.devTools.console.firstFailures[$0] }) {
                Label("First failure: \(failure.text)", systemImage: "xmark.octagon.fill")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(HCGPalette.loss)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HCGPalette.surfaceElevated)
            }
            if model.devTools.console.droppedCount > 0 {
                Text("\(model.devTools.console.droppedCount) older lines are no longer shown here; job logs keep everything.")
                    .font(.caption2).foregroundStyle(HCGPalette.textSecondary).padding(.horizontal).padding(.top, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { line in ConsoleLineView(line: line, showJob: jobFilter == nil) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .background(HCGPalette.surfaceDeep)
                .onChange(of: shown.last?.id) { _, last in
                    if !paused, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .overlay {
                if shown.isEmpty {
                    HCGEmptyState(search.isEmpty ? "No Output Yet" : "No Matches", systemImage: "text.alignleft",
                                  description: Text(search.isEmpty ? "Run Doctor or start a build; their output appears here with its host and job." : "Nothing matches the search and filters."))
                }
            }
            if paused {
                Button { paused = false } label: { Label("Resume (\(newWhilePaused) new)", systemImage: "play.fill") }
                    .buttonStyle(.hcgProminent)
                    .padding(8)
            }
        }
        .searchable(text: $search, prompt: "Search output")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if paused { paused = false } else { frozen = live; paused = true }
                } label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play" : "pause") }
                Menu {
                    Picker("Minimum severity", selection: $minimum) {
                        ForEach(ConsoleSeverity.allCases.reversed(), id: \.self) { Text($0.label).tag($0) }
                    }
                    Section("Sources") {
                        ForEach(ConsoleSource.allCases, id: \.self) { source in
                            Toggle(source.label, isOn: Binding(get: { sources.contains(source) }, set: { if $0 { sources.insert(source) } else { sources.remove(source) } }))
                        }
                    }
                    Divider()
                    Button { UIPasteboard.general.string = ConsoleBuffer.export(shown) } label: { Label("Copy Shown Lines", systemImage: "doc.on.doc") }
                    Button { exportURL = writeExport(shown) } label: { Label("Export Shown Lines…", systemImage: "square.and.arrow.up") }
                    if jobFilter == nil {
                        Button { Task { await model.devTools.importAppLog() } } label: { Label("Add App Log (This Device)", systemImage: "iphone") }
                        Button(role: .destructive) { model.devTools.clearConsole() } label: { Label("Clear", systemImage: "trash") }
                    }
                } label: { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
        .sheet(item: Binding(get: { exportURL.map(ExportFile.init) }, set: { exportURL = $0?.url })) { file in
            ShareLink(item: file.url) { Label("Share \(file.url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                .padding()
                .presentationDetents([.height(140)])
        }
    }

    private func writeExport(_ lines: [ConsoleLine]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-console-\(Int(Date().timeIntervalSince1970)).log")
        do {
            try ConsoleBuffer.export(lines).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ConsoleLineView: View {
    let line: ConsoleLine
    let showJob: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(line.date.formatted(date: .omitted, time: .standard)) · \(line.source.label) · \(line.host)\(showJob ? line.job.map { " · \($0)" } ?? "" : "")")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(HCGPalette.textSecondary)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(line.severity.color)
                .fontWeight(line.failure != nil && line.failure != .summary ? .semibold : .regular)
        }
        .id(line.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.severity.label), \(line.host): \(line.text)")
    }
}

// MARK: - Jobs list (inside Builds)

struct JobsSection: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        let jobs = model.devTools.jobs
        if !jobs.isEmpty {
            Section {
                ForEach(jobs.prefix(30)) { job in
                    NavigationLink { JobDetailView(jobID: job.id) } label: { JobRow(job: job) }
                }
            } header: { Text("Build Jobs") } footer: {
                Text("Jobs run on the host and continue while this phone is disconnected.")
            }
        }
    }
}
#endif
