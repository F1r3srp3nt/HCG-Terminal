import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import Diagnostics
import FileWorkspace
import Foundation
import Observation
import TerminalCore

/// Where a diagnostic, command, log or artifact ran. Shown next to every result.
public enum ExecutionContext: Hashable, Sendable {
    case thisDevice
    case host(name: String, address: String)

    public var label: String {
        switch self {
        case .thisDevice: "This device"
        case .host(let name, let address): "\(name) (\(address))"
        }
    }

    public var shortLabel: String {
        switch self {
        case .thisDevice: "This device"
        case .host(let name, _): name
        }
    }
}

/// The phone's link to a running job. Only describes the connection, never the job's outcome.
public enum JobLink: Equatable, Sendable {
    case following
    case reconnecting(attempt: Int, at: Date)
    /// Gave up retrying automatically; the job may still be running on the host.
    case disconnected(String)
}

/// One install attempt and what was actually confirmed.
public struct InstallAttempt: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running(String)
        case installed(String)
        case launched(String)
        case handedOff(String)
        case failed(String)
    }

    public var id: String
    public var state: State
}

/// Doctor, detached builds, the Log Console and install handoff for remote projects.
///
/// Every remote step goes through the host's existing SSH connection (host-key verification
/// and stored credentials as for any session). Nothing installs or publishes automatically.
@MainActor
@Observable
public final class DevToolsCenter {
    // Doctor
    public private(set) var doctorReports: [String: DoctorReport] = [:]
    public private(set) var doctorRunning: Set<String> = []
    public private(set) var doctorErrors: [String: String] = [:]

    // Jobs
    public private(set) var jobs: [HostJob] = []
    public private(set) var links: [UUID: JobLink] = [:]
    public private(set) var jobErrors: [UUID: String] = [:]
    public private(set) var cancelling: Set<UUID> = []

    // Console
    public private(set) var console = ConsoleBuffer(capacity: 20_000)

    // Artifacts and installs
    public private(set) var downloads: [String: Double] = [:]
    public private(set) var downloaded: [String: ArtifactRecord] = [:]
    public private(set) var installs: [String: InstallAttempt] = [:]
    public var lastError: String?

    @ObservationIgnored private let runner: HostJobRunner
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let connect: @MainActor (UUID) async throws -> any RemoteCommandExecuting
    @ObservationIgnored private let hostFor: @MainActor (UUID) -> HostProfile?
    @ObservationIgnored private let hostAllowsBuilds: @MainActor (UUID) async -> Bool
    @ObservationIgnored private let knownSecrets: @MainActor (UUID) -> [String]
    @ObservationIgnored private var drivers: [UUID: Task<Void, Never>] = [:]

    /// Seconds between automatic reattach attempts; then it stops and offers Reattach.
    static let backoff: [Double] = [2, 5, 10, 20, 30, 60]

    init(
        dependencies: AppDependencies,
        connect: @escaping @MainActor (UUID) async throws -> any RemoteCommandExecuting,
        hostFor: @escaping @MainActor (UUID) -> HostProfile?,
        hostAllowsBuilds: @escaping @MainActor (UUID) async -> Bool,
        knownSecrets: @escaping @MainActor (UUID) -> [String] = { _ in [] }
    ) {
        self.dependencies = dependencies
        let base = (try? dependencies.workspace.url(for: .logs)) ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("jobs")
        self.runner = HostJobRunner(store: HostJobStore(directory: directory), access: dependencies.access)
        self.connect = connect
        self.hostFor = hostFor
        self.hostAllowsBuilds = hostAllowsBuilds
        self.knownSecrets = knownSecrets
        loadDoctorReports()
    }

    // MARK: - Context

    public func context(for hostID: UUID) -> ExecutionContext {
        guard let host = hostFor(hostID) else { return .host(name: "Removed host", address: "") }
        return .host(name: host.name, address: host.endpoint.address)
    }

    // MARK: - Doctor

    public static func doctorKey(hostID: UUID, projectPath: String) -> String { "\(hostID.uuidString)|\(projectPath)" }

    public func report(hostID: UUID, projectPath: String) -> DoctorReport? {
        doctorReports[Self.doctorKey(hostID: hostID, projectPath: projectPath)]
    }

    /// Runs the read-only probe on the host and evaluates it.
    public func runDoctor(host: HostProfile, projectPath: String, project: ProjectKind?, scheme: String?) async {
        let key = Self.doctorKey(hostID: host.id, projectPath: projectPath)
        guard !doctorRunning.contains(key) else { return }
        doctorRunning.insert(key)
        doctorErrors[key] = nil
        defer { doctorRunning.remove(key) }
        let context = context(for: host.id)
        let runID = UUID()
        let label = "doctor-\(runID.uuidString.prefix(8).lowercased())"
        log(["Doctor started for \(projectPath) (read-only checks in the login shell)"], source: .doctor, context: context, job: label, severity: .notice)
        do {
            let executor = try await connect(host.id)
            let command = DoctorProbe.command(projectPath: projectPath, project: project, scheme: scheme, executableMakerPath: host.executableMakerPath)
            let result = try await executor.run(command)
            let facts = DoctorFacts.parse(result.stdoutText)
            let report = DoctorEvaluator.evaluate(facts: facts, host: host, projectPath: projectPath, project: project, scheme: scheme, reportID: runID)
            doctorReports[key] = report
            saveDoctorReports()
            let stderr = result.stderrText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if !stderr.isEmpty { log(stderr.prefix(40).map { "stderr: \($0)" }, source: .doctor, context: context, job: label) }
            for check in report.checks {
                let severity: ConsoleSeverity = switch check.status {
                case .passed: .info
                case .unknown: .notice
                case .warning: .warning
                case .blocked: .error
                }
                log(["\(check.status.label.uppercased()) \(check.title): \(check.summary)"], source: .doctor, context: context, job: label, severity: severity)
            }
            log(["Doctor finished: \(report.checks.filter { $0.status == .blocked }.count) blocked, \(report.checks.filter { $0.status == .warning }.count) warnings, \(report.checks.filter { $0.status == .unknown }.count) unknown"], source: .doctor, context: context, job: label, severity: .notice)
        } catch {
            doctorErrors[key] = error.localizedDescription
            log(["Doctor could not run: \(error.localizedDescription)"], source: .doctor, context: context, job: label, severity: .error)
        }
    }

    private var doctorURL: URL { directory.appendingPathComponent("doctor-reports.json") }

    private func loadDoctorReports() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: doctorURL), let list = try? decoder.decode([DoctorReport].self, from: data) {
            doctorReports = Dictionary(list.map { (Self.doctorKey(hostID: $0.hostID, projectPath: $0.projectPath), $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func saveDoctorReports() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(Array(doctorReports.values.sorted { $0.ranAt > $1.ranAt }.prefix(50))) {
            try? data.write(to: doctorURL, options: .atomic)
        }
    }

    // MARK: - Jobs

    public func reload() async {
        jobs = await runner.store.all()
    }

    public func job(_ id: UUID) -> HostJob? { jobs.first { $0.id == id } }

    /// Records and starts a build job; follows it until it ends. Returns its ID at once.
    @discardableResult
    public func start(_ plan: BuildPlan, doctorReportID: UUID?) async -> UUID {
        let job = await runner.create(plan, doctorReportID: doctorReportID)
        await reload()
        log(["Job \(job.shortID) created: \(plan.title)", "$ \(plan.commandLine)"], source: .build, context: context(for: plan.hostID), job: job.shortID, severity: .notice)
        drive(job.id)
        return job.id
    }

    /// After launch: reattach to every job that was active when the app last ran.
    public func resumeActiveJobs() async {
        await reload()
        for job in jobs where job.state.isActive { drive(job.id) }
    }

    /// Follows the job, reconnecting with backoff after a dropped connection. Never starts a
    /// second build: the host refuses an ID it has already seen.
    public func drive(_ id: UUID) {
        guard drivers[id] == nil, let job = job(id) else { return }
        let hostID = job.plan.hostID
        drivers[id] = Task { [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled {
                guard let current = self.job(id), current.state.isActive else { break }
                self.links[id] = .following
                self.jobErrors[id] = nil
                do {
                    let executor = try await self.connect(hostID)
                    await self.runner.setRedactor(SecretRedactor().adding(self.knownSecrets(hostID)))
                    let allowed = await self.hostAllowsBuilds(hostID)
                    let context = self.context(for: hostID)
                    let short = current.shortID
                    let result = await self.runner.drive(id, executor: executor, hostAllowsBuilds: allowed) { lines in
                        await MainActor.run { [weak self] in self?.log(lines, source: .build, context: context, job: short) }
                    }
                    await self.reload()
                    if let result, !result.state.isActive {
                        self.links[id] = nil
                        self.log(["Job \(short): \(result.state.label)"], source: .build, context: context, job: short, severity: result.state == .succeeded ? .notice : .error)
                        break
                    }
                    attempt = 0
                } catch {
                    self.jobErrors[id] = error.localizedDescription
                }
                guard attempt < Self.backoff.count else {
                    self.links[id] = .disconnected(self.jobErrors[id] ?? "The connection to the host was lost.")
                    break
                }
                let delay = Self.backoff[attempt]
                attempt += 1
                self.links[id] = .reconnecting(attempt: attempt, at: Date().addingTimeInterval(delay))
                try? await Task.sleep(for: .seconds(delay))
            }
            self?.drivers[id] = nil
        }
    }

    /// Manual reattach after automatic retries stopped.
    public func reattach(_ id: UUID) {
        drivers[id]?.cancel()
        drivers[id] = nil
        drive(id)
    }

    public func cancel(_ id: UUID) async {
        guard let job = job(id) else { return }
        cancelling.insert(id)
        defer { cancelling.remove(id) }
        do {
            let reply = try await runner.cancel(id, executor: connect(job.plan.hostID))
            log(["Cancel requested: \(reply)"], source: .build, context: context(for: job.plan.hostID), job: job.shortID, severity: .notice)
            await reload()
            if job.state == .starting { drivers[id]?.cancel() }
        } catch {
            jobErrors[id] = "Could not reach the host to cancel: \(error.localizedDescription). The job may still be running."
        }
    }

    /// Deletes the job's folder on the host and forgets it here (finished jobs only).
    public func remove(_ id: UUID) async {
        guard let job = job(id), !job.state.isActive else { return }
        do {
            _ = try await runner.removeEverywhere(id, executor: connect(job.plan.hostID))
        } catch {
            lastError = "Could not remove the job on \(job.plan.hostName): \(error.localizedDescription)"
        }
        await reload()
    }

    public func log(for job: HostJob) async -> String { await runner.store.log(for: job) }
    public func logURL(for job: HostJob) async -> URL { await runner.store.logURL(for: job) }

    // MARK: - Console

    public func log(_ lines: [String], source: ConsoleSource, context: ExecutionContext, job: String?, severity: ConsoleSeverity? = nil) {
        console.append(lines, source: source, host: context.label, job: job, severity: severity)
    }

    public func clearConsole() { console.clear() }

    /// Brings recent entries from the app's own diagnostic log into the console.
    public func importAppLog() async {
        let entries = await DiagnosticLog.shared.recent(limit: 300)
        let lines = entries.map { "[\($0.level.label)] \($0.category): \($0.message)" + ($0.metadata.isEmpty ? "" : " " + $0.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        log(lines, source: .app, context: .thisDevice, job: nil, severity: .info)
    }

    // MARK: - Artifacts

    /// Downloads into the workspace (`/artifacts/<date>/`), verifying the SHA-256 the host computed.
    public func download(_ artifact: JobArtifact, from job: HostJob) async -> ArtifactRecord? {
        if let record = downloaded[artifact.id] { return record }
        downloads[artifact.id] = 0
        let (stream, sink) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pump = Task { [weak self] in for await fraction in stream { self?.downloads[artifact.id] = fraction } }
        defer {
            sink.finish()
            downloads[artifact.id] = nil
        }
        do {
            let executor = try await connect(job.plan.hostID)
            let record = try await ArtifactDownloader().download(
                remotePath: artifact.remotePath, from: executor, into: dependencies.workspace,
                index: dependencies.artifactIndex, buildRunID: job.id
            ) { received, total in if total > 0 { sink.yield(Double(received) / Double(total)) } }
            sink.finish()
            await pump.value
            if record.sha256 != artifact.sha256 {
                lastError = "\(artifact.name): downloaded checksum \(record.sha256.prefix(12))… differs from the host's manifest \(artifact.sha256.prefix(12))…."
            }
            downloaded[artifact.id] = record
            log(["Downloaded \(artifact.name) (\(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)), SHA-256 \(record.sha256.prefix(16))…, verified against the host) to \(record.localPath)"], source: .install, context: .thisDevice, job: job.shortID, severity: .notice)
            return record
        } catch {
            sink.finish()
            await pump.value
            lastError = "\(artifact.name): \(error.localizedDescription)"
            return nil
        }
    }

    public func localURL(_ record: ArtifactRecord) -> URL? {
        guard let path = try? WorkspacePath(record.localPath) else { return nil }
        return try? dependencies.workspace.url(for: path)
    }

    // MARK: - Install handoff

    /// Whether this app can hand a .deb to the device's package workflow: Unleashed, with a
    /// package manager found and both package and local-shell access switched on.
    public func supportsLocalPackageInstall() async -> Bool {
        guard let tools = dependencies.unleashedTools, await tools.packageManagerAvailable() else { return false }
        return dependencies.access.denial(.packageManagement) == nil && dependencies.access.denial(.localShell) == nil
    }

    /// Reads what the build host offers for this artifact (read-only).
    public func installOptions(for artifact: JobArtifact, job: HostJob) async -> InstallOptions {
        let environment = job.doctorReportID.flatMap { id in doctorReports.values.first { $0.id == id } }?.environment
            ?? report(hostID: job.plan.hostID, projectPath: job.plan.projectPath)?.environment
        var simulators: [SimulatorDevice] = []
        var signing: SigningInspection?
        var devices: [HostVisibleDevice] = []
        do {
            let executor = try await connect(job.plan.hostID)
            switch artifact.kind {
            case .simulatorApp:
                simulators = InstallInspection.parseSimulators(try await executor.run(InstallInspection.simulatorsCommand).stdout)
            case .deviceApp, .ipa:
                signing = InstallInspection.parseSigning(try await executor.run(InstallInspection.signingCommand(path: artifact.sourcePath)).stdoutText)
                devices = InstallInspection.parseDevices(try await executor.run(InstallInspection.devicesCommand).stdout)
            default:
                break
            }
        } catch {
            lastError = "Could not inspect \(artifact.name) on \(job.plan.hostName): \(error.localizedDescription)"
        }
        return InstallPlanner.options(
            for: artifact, buildHost: job.plan.hostName, hostEnvironment: environment, simulators: simulators,
            signing: signing, hostDevices: devices, appSupportsLocalPackageInstall: await supportsLocalPackageInstall()
        )
    }

    /// Runs one confirmed install. The state says only what the host confirmed.
    public func install(_ option: InstallOptions.Option, artifact: JobArtifact, job: HostJob, model: TerminalAppModel) async {
        let key = artifact.id
        let context = context(for: job.plan.hostID)
        switch option {
        case .download:
            _ = await download(artifact, from: job)
        case .simulator(let device, _):
            installs[key] = InstallAttempt(id: key, state: .running("Installing in \(device.name) (\(device.runtime)) on \(job.plan.hostName)…"))
            await runInstall(InstallCommands.simulator(appPath: artifact.sourcePath, udid: device.udid, bundleID: artifact.bundleIdentifier), key: key, job: job, context: context, target: "\(device.name) Simulator on \(job.plan.hostName)")
        case .deviceThroughHost(let device, _):
            installs[key] = InstallAttempt(id: key, state: .running("Installing on \(device.name) through \(job.plan.hostName)…"))
            await runInstall(InstallCommands.device(appPath: artifact.sourcePath, udid: device.udid), key: key, job: job, context: context, target: "\(device.name)")
        case .jailbreakPackage:
            guard let tools = dependencies.unleashedTools else { return }
            guard let record = await download(artifact, from: job), let url = localURL(record) else { return }
            do {
                let command = try await tools.authorizedPackageCommand(.installFile(url.path))
                await model.runApprovedCommandInNewUnleashedSession(command)
                installs[key] = InstallAttempt(id: key, state: .handedOff("Opened a Local Unleashed session running `\(command)`. Check its output there: HCG Terminal does not report the package as installed."))
                log(["Handed \(artifact.name) to dpkg in a visible local session (approved)."], source: .install, context: .thisDevice, job: job.shortID, severity: .notice)
            } catch {
                installs[key] = InstallAttempt(id: key, state: .failed(error.localizedDescription))
            }
        }
    }

    private func runInstall(_ command: String, key: String, job: HostJob, context: ExecutionContext, target: String) async {
        do {
            let executor = try await connect(job.plan.hostID)
            var output = ""
            var status: Int32 = -1
            var assembler = LineAssembler()
            for try await event in executor.stream(command) {
                switch event {
                case .stdout(let data), .stderr(let data):
                    let text = String(decoding: data, as: UTF8.self)
                    output += text
                    log(assembler.append(text), source: .install, context: context, job: job.shortID)
                case .exit(let code): status = code
                }
            }
            log(assembler.flush(), source: .install, context: context, job: job.shortID)
            switch InstallCommands.outcome(output: output, exitStatus: status) {
            case .installedAndLaunched(let pid):
                installs[key] = InstallAttempt(id: key, state: .launched("Installed and launched in \(target) (process \(pid))."))
            case .installed:
                installs[key] = InstallAttempt(id: key, state: .installed(status == 0 ? "Installed on \(target). Open it there." : "Installed on \(target), but launching failed (exit \(status)). See the Log Console."))
            case .failed(let code):
                installs[key] = InstallAttempt(id: key, state: .failed("Not installed (exit \(code)). See the Log Console for the host's output."))
            }
        } catch {
            installs[key] = InstallAttempt(id: key, state: .failed("Not installed: \(error.localizedDescription)"))
        }
    }

    #if DEBUG
    /// CI screenshots only: a synthetic Doctor report, finished job and console lines for a
    /// sample host. Every line says it is a sample; nothing is sent anywhere.
    public func seedSmokeSample(host: HostProfile) async -> UUID {
        let facts = DoctorFacts.parse(Self.sampleFacts)
        let report = DoctorEvaluator.evaluate(facts: facts, host: host, projectPath: "~/Developer/Sample App", project: .xcodeProject("SampleApp.xcodeproj"), scheme: "SampleApp")
        doctorReports[Self.doctorKey(hostID: host.id, projectPath: "~/Developer/Sample App")] = report
        var plan = (try? BuildPlanner.plan(host: host, projectPath: "~/Developer/Sample App", system: .executableMaker(ExecutableMakerBuild(output: .iosSimulatorApp, toolPath: "~/HCG-Executable-Maker", scheme: "SampleApp")), action: .build))
            ?? (try! BuildPlanner.custom(host: host, projectPath: "~/Developer/Sample App", command: "true"))
        plan.hostID = host.id
        var job = await runner.create(plan)
        let lines = [
            "[hcg] job \(job.shortID) · \(plan.title) (synthetic sample for screenshots)",
            "[hcg] PATH=/opt/homebrew/bin:/usr/bin:/bin",
            "   [Preparing] Importing project",
            "   [Compiling] xcodebuild build",
            "   CompileSwift normal arm64 /Users/dev/Developer/Sample App/Sources/ErrorView.swift",
            "   /Users/dev/Developer/Sample App/Sources/ContentView.swift:42:17: error: cannot find 'accentColour' in scope",
            "   export API_TOKEN=[REDACTED]",
            "** BUILD FAILED **",
            "Result: Failed Compilation failed in 00:00:41.2",
            "[hcg] exit 1",
        ]
        await runner.store.appendLog(lines, to: job)
        job.state = .failed(exitStatus: 1)
        job.finishedAt = job.createdAt.addingTimeInterval(41)
        job.receivedBytes = Int64(lines.joined(separator: "\n").utf8.count)
        if let failure = FailureLocator.firstFailure(in: lines) { job.firstFailure = StoredFailure(failure) }
        await runner.store.save(job)
        await reload()
        let context = context(for: host.id)
        log(["Doctor (synthetic sample): Xcode 26.1 found, scheme SampleApp, iOS 17.0 deployment target"], source: .doctor, context: context, job: "doctor-sample", severity: .notice)
        log(["WARNING Disk space: 8.2 GB free. Xcode builds can need several GB."], source: .doctor, context: context, job: "doctor-sample", severity: .warning)
        log(lines, source: .build, context: context, job: job.shortID)
        return job.id
    }

    static let sampleFacts = """
    K\tos.kernel\tDarwin
    K\tos.arch\tarm64
    K\tos.product\tmacOS 15.5
    K\tenv.shell\t/bin/zsh
    K\tenv.path\t/opt/homebrew/bin:/usr/bin:/bin
    K\tdisk.project_kb\t8000000
    K\ttool.xcodebuild\t/usr/bin/xcodebuild
    K\txcode.select\t/Applications/Xcode.app/Contents/Developer
    K\txcode.app\t/Applications/Xcode.app
    BEGIN\txcode.version
    Xcode 26.1
    Build version 17B55
    END\txcode.version
    K\txcode.first_launch_status\t0
    K\tsdk.iphoneos\t26.1
    K\tsdk.iphonesimulator\t26.1
    BEGIN\tsimulator.runtimes
    iOS 26.1 (26.1 - 23B80) - com.apple.CoreSimulator.SimRuntime.iOS-26-1
    END\tsimulator.runtimes
    BEGIN\txcode.list
    {"project":{"schemes":["SampleApp"]}}
    END\txcode.list
    BEGIN\txcode.settings
    [{"buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","IPHONEOS_DEPLOYMENT_TARGET":"17.0","SUPPORTED_PLATFORMS":"iphoneos iphonesimulator","PRODUCT_BUNDLE_IDENTIFIER":"com.example.sample","CODE_SIGN_STYLE":"Automatic"}}]
    END\txcode.settings
    K\ttool.dotnet\t/usr/local/share/dotnet/dotnet
    BEGIN\tdotnet.version
    10.0.100
    END\tdotnet.version
    BEGIN\tdotnet.sdks
    10.0.100 [/usr/local/share/dotnet/sdk]
    END\tdotnet.sdks
    K\tem.path\t/Users/dev/HCG-Executable-Maker
    BEGIN\tsigning.identities
         0 valid identities found
    END\tsigning.identities
    K\tprobe.done\t1
    """
    #endif
}
