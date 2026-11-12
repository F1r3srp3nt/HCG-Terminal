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
                availability: .notIncluded("Not part of Vanilla mode: iOS does not let ordinary apps start other programs."),
                summary: "Only HCG built-in commands run locally; use a remote host for system tools.",
                evidence: [CapabilityEvidence(probe: "Vanilla policy", observation: "no process execution", positive: false)]
            ),
            CapabilityResult(
                kind: .filesystemPermissions,
                availability: writable && created
                    ? .verified("The workspace and its folders were created at launch and are writable.")
                    : .permissionDenied("The app workspace is not writable."),
                summary: "List the app's workspace (also visible in the Files app). Nothing outside it.",
                evidence: [
                    CapabilityEvidence(probe: "access(workspace, W_OK)", observation: writable ? "writable" : "not writable", positive: writable),
                    CapabilityEvidence(probe: "standard folders (/home, /projects, /artifacts, /logs, /tmp)", observation: created ? "created" : "missing", positive: created),
                ]
            ),
            CapabilityResult(
                kind: .localhostSSH,
                availability: .notIncluded("Not part of Vanilla mode: connecting to services on this device is an Unleashed feature."),
                summary: "Use Remote SSH for other hosts."
            ),
            CapabilityResult(
                kind: .fileReading,
                availability: writable && created ? .verified("Workspace files are read by the built-in commands.") : .permissionDenied("The app workspace is not accessible."),
                summary: "Read files in the app workspace."
            ),
            CapabilityResult(
                kind: .fileWriting,
                availability: writable && created ? .verified("The workspace folders were created at launch.") : .permissionDenied("The app workspace is not writable."),
                summary: "Write files in the app workspace. Nothing outside it."
            ),
            CapabilityResult(
                kind: .packageChanges,
                availability: .notIncluded("Not part of Vanilla mode: standard iOS has no package manager for apps."),
                summary: "Install toolchains on a remote host instead."
            ),
            CapabilityResult(
                kind: .packageManager,
                availability: .notIncluded("Not part of Vanilla mode: standard iOS has no package manager for apps."),
                summary: "Install toolchains on a remote host instead."
            ),
            processInspectionResult(processCount),
            CapabilityResult(
                kind: .privilegedOperations,
                availability: .notIncluded("Not part of Vanilla mode: it never performs privileged operations."),
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
    private let persistence: ShellPersistence
    private let access: AccessPolicy

    public init(workspace: FileWorkspace, capabilities: VanillaCapabilityProvider, access: AccessPolicy = .shared) {
        self.workspace = workspace
        self.capabilities = capabilities
        self.persistence = ShellPersistence(workspace: workspace)
        self.access = access
    }

    public func availableBackend() async -> SessionBackend? { .builtInCommands }

    public func makeSession() async throws -> any TerminalSession {
        try access.require(.workspaceCommands)
        let capabilities = self.capabilities
        let access = self.access
        let session = BuiltinShellSession(
            configuration: BuiltinShellConfiguration(
                target: .local(.vanilla),
                workspace: workspace,
                environment: ["USER": "mobile", "SHELL": "hcg-builtin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
                banner: Self.banner,
                promptLabel: "hcg",
                promptColor: ANSI.cyan,
                sessionDescription: [
                    "Target:   Local Vanilla (this device, app sandbox)",
                    "Backend:  \(SessionBackend.builtInCommands.label) — in-app command interpreter, not a system shell",
                    "Mode:     Vanilla",
                    "Files:    app workspace; history and last folder kept in /home/.hcg_history and /home/.hcg_cwd",
                ],
                capabilityDescription: { CapabilityReportFormatter.text(await capabilities.detectCapabilities()) },
                persistence: persistence,
                commandGate: { access.denial(.workspaceCommands) }
            ),
            external: RefusingExternalCommandHandler(
                policyDescription: "Only HCG built-in commands run here. Other programs are not executed on this device and are never sent to a remote host automatically; open a Remote Host session for system tools.",
                explanation: "It is not an HCG built-in command."
            )
        )
        await session.refreshCapabilityDescription()
        await DiagnosticLog.shared.record(.info, "session", "Opened Local Vanilla session", metadata: ["session": session.id.description])
        return session
    }

    static let banner = """
    \(ANSI.cyan)HCG Terminal\(ANSI.reset) · \(ANSI.bold)Local Vanilla\(ANSI.reset) · HCG built-in commands
    An in-app command interpreter for the app workspace — not a system shell.
    Type \(ANSI.bold)help\(ANSI.reset) for commands. For system tools, open a Remote Host session;
    nothing typed here is sent anywhere else.

    """
}
