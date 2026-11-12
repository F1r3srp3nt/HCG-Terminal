import Diagnostics
import FileWorkspace
import Foundation
import LocalCommandEngine
import TerminalCapabilityProvider
import TerminalCore

/// Capability report for the standard iOS/iPadOS environment.
///
/// Vanilla never probes outside the app container except for one read-only process-table
/// count, and never attempts process execution or private APIs.
public struct VanillaCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .vanilla
    private let workspace: FileWorkspace
    private let probe: any SystemProbing

    public init(workspace: FileWorkspace, probe: any SystemProbing = LiveSystemProbe()) {
        self.workspace = workspace
        self.probe = probe
    }

    public func detectCapabilities() async -> CapabilityReport {
        let builtinCount = BuiltinRegistry.standard.commands.count
        let rootPath = workspace.rootURL.path
        let writable = probe.isWritable(rootPath)
        let created = FileWorkspace.standardDirectories.allSatisfy { workspace.isDirectory($0) }
        let processCount = probe.visibleProcessCount()

        let results: [CapabilityResult] = [
            CapabilityResult(
                kind: .localShell,
                availability: .verified("Runs inside the app; no external process is needed."),
                summary: "HCG built-in commands (\(builtinCount)) with pipes, redirection and history. This is an in-app command interpreter, not a system shell.",
                evidence: [CapabilityEvidence(probe: "Built-in command registry", observation: "\(builtinCount) commands", positive: true)]
            ),
            CapabilityResult(
                kind: .executableAccess,
                availability: .unsupportedEnvironment("iOS does not let App Store apps start other programs."),
                summary: "Only HCG built-in commands run locally; use a remote host for system tools.",
                evidence: [CapabilityEvidence(probe: "Vanilla policy", observation: "no process execution", positive: false)]
            ),
            CapabilityResult(
                kind: .filesystemPermissions,
                availability: writable && created
                    ? .verified("The workspace and its folders were created at launch and are writable.")
                    : .permissionDenied("The app workspace is not writable."),
                summary: "Read and write inside the app's workspace (also visible in the Files app). Nothing outside it.",
                evidence: [
                    CapabilityEvidence(probe: "access(workspace, W_OK)", observation: writable ? "writable" : "not writable", positive: writable),
                    CapabilityEvidence(probe: "standard folders (/home, /projects, /artifacts, /logs, /tmp)", observation: created ? "created" : "missing", positive: created),
                ]
            ),
            CapabilityResult(
                kind: .packageManager,
                availability: .unsupportedEnvironment("There is no package manager on standard iOS."),
                summary: "Install toolchains on a remote host instead."
            ),
            processInspectionResult(processCount),
            CapabilityResult(
                kind: .privilegedOperations,
                availability: .unsupportedEnvironment("Vanilla never performs privileged operations."),
                summary: "Everything runs with the app's ordinary sandbox permissions."
            ),
            SharedCapabilities.remoteSSH(),
            SharedCapabilities.buildOrchestration(),
        ]
        return CapabilityReport(
            mode: .vanilla,
            results: results,
            localFeaturesAvailable: true,
            headline: "Vanilla: built-in commands on the app workspace, plus remote development.",
            buildNotes: []
        )
    }

    private func processInspectionResult(_ count: Int?) -> CapabilityResult {
        let evidence = CapabilityEvidence(
            probe: "sysctl(KERN_PROC_ALL)",
            observation: count.map { "\($0) process(es) visible" } ?? "refused",
            positive: (count ?? 0) > 1
        )
        let availability: CapabilityAvailability = switch count {
        case .some(let n) where n > 1: .verified("The process table returned \(n) processes.")
        case .some: .permissionDenied("The sandbox shows this app only its own process.")
        case nil: .permissionDenied("The process table is not accessible to this app.")
        }
        return CapabilityResult(kind: .processInspection, availability: availability, summary: "List running processes (read-only).", evidence: [evidence])
    }
}

/// Creates Local Vanilla sessions: built-in commands on the app workspace. Commands that are
/// not built-ins are refused with an explanation — never executed elsewhere.
public struct VanillaExecutionProvider: LocalExecutionProvider {
    public let mode: ExecutionMode = .vanilla
    private let workspace: FileWorkspace
    private let capabilities: VanillaCapabilityProvider

    public init(workspace: FileWorkspace, capabilities: VanillaCapabilityProvider) {
        self.workspace = workspace
        self.capabilities = capabilities
    }

    public func availableBackend() async -> SessionBackend? { .builtInCommands }

    public func makeSession() async throws -> any TerminalSession {
        let capabilities = self.capabilities
        let session = BuiltinShellSession(
            configuration: BuiltinShellConfiguration(
                target: .local(.vanilla),
                workspace: workspace,
                environment: ["USER": "mobile", "SHELL": "hcg-builtin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
                banner: Self.banner,
                promptLabel: "vanilla",
                promptColor: ANSI.cyan,
                sessionDescription: [
                    "Target:   Local Vanilla (this device, app sandbox)",
                    "Backend:  \(SessionBackend.builtInCommands.label)",
                    "Mode:     Vanilla",
                ],
                capabilityDescription: { CapabilityReportFormatter.text(await capabilities.detectCapabilities()) }
            ),
            external: RefusingExternalCommandHandler(
                policyDescription: "Vanilla runs built-in commands only. Other programs are not executed on this device and are never sent to a remote host automatically; open a Remote Host session for system tools.",
                explanation: "Vanilla runs built-in commands only (type `help`). For system tools, open a Remote Host session."
            )
        )
        await session.refreshCapabilityDescription()
        await DiagnosticLog.shared.record(.info, "session", "Opened Local Vanilla session", metadata: ["session": session.id.description])
        return session
    }

    static let banner = """
    \(ANSI.cyan)HCG Terminal\(ANSI.reset) · \(ANSI.bold)Local Vanilla\(ANSI.reset)
    Built-in commands on the app workspace. Type \(ANSI.bold)help\(ANSI.reset) for the list.
    Remote hosts run in their own sessions; nothing typed here is sent anywhere else.

    """
}
