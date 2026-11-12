import FileWorkspace
import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
import TerminalUI
import UnleashedExecutionProvider

/// Composition for the Unleashed app target. Linked only by that target, so the standard
/// build contains no Unleashed code at all.
public enum UnleashedIntegration {
    public static func dependencies(
        workspace: FileWorkspace,
        supportDirectory: URL,
        credentials: any CredentialStore = DefaultCredentialStore.make(),
        preferences: ModePreferenceStore = ModePreferenceStore(),
        access: AccessPolicy = .shared,
        appearance: AppearanceStore = AppearanceStore()
    ) -> AppDependencies {
        var dependencies = AppDependencies.standard(
            workspace: workspace, supportDirectory: supportDirectory, credentials: credentials, preferences: preferences,
            access: access, appearance: appearance
        )
        let observations = RuntimeObservations()
        let capabilities = UnleashedCapabilityProvider(observations: observations, customRoots: { BootstrapRootPreference.load() })
        dependencies.distribution = .unleashed
        var identity = BuildIdentity.current(linkedBackend: .unleashed)
        identity.backendMarker = UnleashedBackend.marker
        dependencies.buildIdentity = identity
        dependencies.unleashedCapabilities = capabilities
        dependencies.unleashed = UnleashedExecutionProvider(capabilities: capabilities, observations: observations, gate: dependencies.gate, access: access)
        let tools = UnleashedToolsAdapter(capabilities: capabilities, observations: observations, gate: dependencies.gate, access: access)
        dependencies.unleashedTools = tools
        dependencies.environmentAssessment = { await tools.assessment() }
        return dependencies
    }
}

/// Bridges the Unleashed module to the interface's `UnleashedTools` protocol.
actor UnleashedToolsAdapter: UnleashedTools {
    private let capabilities: UnleashedCapabilityProvider
    private let observations: RuntimeObservations
    private let gate: AuthorizationGate
    private let access: AccessPolicy
    private var cachedScan: (UnleashedEnvironmentScan, Date)?

    init(capabilities: UnleashedCapabilityProvider, observations: RuntimeObservations, gate: AuthorizationGate, access: AccessPolicy) {
        self.capabilities = capabilities
        self.observations = observations
        self.gate = gate
        self.access = access
    }

    /// Read-only scan, cached briefly so one screen does not rescan repeatedly.
    private func scan() -> UnleashedEnvironmentScan {
        if let (scan, date) = cachedScan, Date().timeIntervalSince(date) < 10 { return scan }
        let scan = capabilities.scan()
        cachedScan = (scan, Date())
        return scan
    }

    func loopbackServicePorts() async -> [Int] { scan().loopbackServicePorts }

    func packageManagerAvailable() async -> Bool { !scan().packageManagers.isEmpty }

    func installedPackages() async throws -> [PackageRow] {
        try await PackageManagerClient(scan: scan(), gate: gate, access: access).listInstalled()
            .map { PackageRow(name: $0.name, version: $0.version, status: $0.status) }
    }

    func authorizedPackageCommand(_ request: PackageRequest) async throws -> String {
        let action: PackageAction = switch request {
        case .install(let name): .install(name)
        case .remove(let name): .remove(name)
        case .refreshIndexes: .refreshIndexes
        }
        return try await PackageManagerClient(scan: scan(), gate: gate, access: access).authorizedCommand(for: action)
    }

    private func files() -> HostFileSystem { HostFileSystem(scan: scan(), gate: gate, access: access) }

    func permittedRoots() async -> [String] { files().roots }

    func logRoots() async -> [String] { files().logRoots }

    func list(_ path: String) async throws -> [HostFileRow] {
        try files().list(path).map { HostFileRow(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, size: $0.size, writable: $0.writable) }
    }

    func readTail(_ path: String) async throws -> String { try files().readTail(path) }

    func canWrite(_ path: String) async -> Bool { files().isWritable(path) }

    func readText(_ path: String) async throws -> String { try files().readText(path) }

    func writeText(_ text: String, to path: String) async throws { try await files().writeText(text, to: path) }

    func createDirectory(named name: String, in directory: String) async throws {
        try await files().createDirectory(named: name, in: directory)
    }

    func rename(_ path: String, to newName: String) async throws { try await files().rename(path, to: newName) }

    func delete(_ path: String) async throws { try await files().delete(path) }

    // MARK: Assessment, programs, verification

    private var operations: [EnvironmentAssessment.Operation] = []

    private func remember(_ operation: EnvironmentAssessment.Operation) {
        operations.append(operation)
        if operations.count > 20 { operations.removeFirst(operations.count - 20) }
    }

    func assessment() async -> EnvironmentAssessment {
        await capabilities.assessment(operations: operations, shellEnabled: access.isEnabled(.localShell))
    }

    private func programs() -> UnleashedOperations {
        UnleashedOperations(scan: scan(), observations: observations, gate: gate, access: access)
    }

    func installedTools() async -> [ToolRow] {
        guard access.isEnabled(.localShell) else { return [] }
        return programs().installedTools().map { ToolRow(name: $0.name, path: $0.path) }
    }

    func runTool(_ path: String, arguments: [String]) async throws -> ToolRunOutput {
        let result = try await programs().run(path, arguments: arguments)
        let succeeded = !result.timedOut && result.signal == nil && result.status == 0
        remember(.init(name: "Run \((path as NSString).lastPathComponent)", outcome: result.summary, succeeded: succeeded))
        return ToolRunOutput(commandLine: result.commandLine, summary: result.summary, stdout: result.stdout, stderr: result.stderr, succeeded: succeeded)
    }

    func toolSession(_ path: String, arguments: [String]) async throws -> any TerminalSession {
        let scan = scan()
        let shell = scan.shells.first ?? path
        return try await programs().launchSession(path, arguments: arguments, environment: UnleashedExecutionProvider.environment(for: scan, shell: shell))
    }

    func verifyShell() async -> EnvironmentAssessment.Operation {
        cachedScan = nil
        let result = await programs().verifyShell()
        remember(result)
        return result
    }

    func verifyWrite(in directory: String) async -> EnvironmentAssessment.Operation {
        let result = await files().verifyWriteAccess(in: directory)
        remember(result)
        return result
    }

    func customBootstrapRoots() async -> [String] { BootstrapRootPreference.load() }

    func setCustomBootstrapRoots(_ roots: [String]) async {
        BootstrapRootPreference.save(roots)
        cachedScan = nil
    }
}
