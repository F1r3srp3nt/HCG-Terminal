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
        preferences: ModePreferenceStore = ModePreferenceStore()
    ) -> AppDependencies {
        var dependencies = AppDependencies.standard(
            workspace: workspace, supportDirectory: supportDirectory, credentials: credentials, preferences: preferences
        )
        let observations = RuntimeObservations()
        let capabilities = UnleashedCapabilityProvider(observations: observations)
        dependencies.distribution = .unleashed
        dependencies.buildIdentity = BuildIdentity.current(linkedBackend: .unleashed)
        dependencies.unleashedCapabilities = capabilities
        dependencies.unleashed = UnleashedExecutionProvider(capabilities: capabilities, observations: observations, gate: dependencies.gate)
        dependencies.unleashedTools = UnleashedToolsAdapter(capabilities: capabilities, gate: dependencies.gate)
        return dependencies
    }
}

/// Bridges the Unleashed module to the interface's `UnleashedTools` protocol.
actor UnleashedToolsAdapter: UnleashedTools {
    private let capabilities: UnleashedCapabilityProvider
    private let gate: AuthorizationGate
    private var cachedScan: (UnleashedEnvironmentScan, Date)?

    init(capabilities: UnleashedCapabilityProvider, gate: AuthorizationGate) {
        self.capabilities = capabilities
        self.gate = gate
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
        try await PackageManagerClient(scan: scan(), gate: gate).listInstalled()
            .map { PackageRow(name: $0.name, version: $0.version, status: $0.status) }
    }

    func authorizedPackageCommand(_ request: PackageRequest) async throws -> String {
        let action: PackageAction = switch request {
        case .install(let name): .install(name)
        case .remove(let name): .remove(name)
        case .refreshIndexes: .refreshIndexes
        }
        return try await PackageManagerClient(scan: scan(), gate: gate).authorizedCommand(for: action)
    }

    private func files() -> HostFileSystem { HostFileSystem(scan: scan(), gate: gate) }

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
}
