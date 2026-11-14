import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import Diagnostics
import Foundation
import Observation
import RemoteSSH
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity

/// A question the interface must answer before work continues. Each one is resolved exactly
/// once by the user; dismissing it counts as "no".
public struct PendingDecision<Request: Sendable>: Identifiable {
    public let id = UUID()
    public let request: Request
    let resolve: (Bool) -> Void
}

public struct HostKeyPrompt: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var key: PresentedHostKey
}

/// Shown when the user taps a mode that cannot run here. Nothing about the current mode or
/// sessions changes.
public struct ModeUnavailableExplanation: Identifiable {
    public let id = UUID()
    public let mode: ExecutionMode
    public let report: CapabilityReport
    public let distribution: DistributionBuild
}

/// A host presented a different key than the one trusted before. The connection was refused;
/// the user decides explicitly whether to remove the old key and verify the new one.
public struct HostKeyChangeNotice: Identifiable {
    public let id = UUID()
    public let host: HostProfile
    public let expectedFingerprint: String
    public let presentedFingerprint: String
}

/// Result of "Test Connection" in the host editor.
public enum ConnectionTestResult: Equatable {
    case success(system: String, shell: String, tools: [String: String], elapsed: TimeInterval)
    case failure(category: String, message: String)
}

/// A pending change to a Capabilities & Access switch that needs the user's confirmation,
/// because it stops something that is running or widens what HCG Terminal may do.
public struct AccessChangeRequest: Identifiable {
    public let id = UUID()
    public let control: AccessControl
    public let enabled: Bool
    /// Switches that stop working with this change (the control and its dependents).
    public let newlyDisabled: [AccessControl]
    /// Live sessions that will be ended, with what ending them can and cannot guarantee.
    public let sessions: [AffectedSession]
    public let stopsRunningBuild: Bool
    /// Extra explanation for switches that widen access (write, privileged).
    public let caution: String?

    public struct AffectedSession: Identifiable, Hashable {
        public let id: SessionID
        public let title: String
        public let target: ExecutionTarget
        public let consequence: String
    }

    public var stopsSomething: Bool { !sessions.isEmpty || stopsRunningBuild }
    public var needsConfirmation: Bool { stopsSomething || caution != nil }
}

/// The mode-switch confirmation shown when existing local sessions could be moved.
public struct ModeSwitchConfirmation: Identifiable {
    public let id = UUID()
    public let plan: ModeSwitchPlan
}

/// Root state of the app. Owns sessions and coordinates mode changes.
@MainActor
@Observable
public final class TerminalAppModel {
    public let dependencies: AppDependencies

    // MARK: Mode
    public private(set) var preferredMode: ExecutionMode
    /// Reports as detected, with verifications from real use applied.
    public private(set) var reports: [ExecutionMode: CapabilityReport] = [:]
    @ObservationIgnored private var detectedReports: [ExecutionMode: CapabilityReport] = [:]
    /// Evidence from real use in this app session (e.g. an SSH connection that succeeded).
    @ObservationIgnored private var verifications: [ExecutionMode: [CapabilityKind: CapabilityEvidence]] = [:]
    public private(set) var isDetecting = false
    public var modeSwitchConfirmation: ModeSwitchConfirmation?
    public var modeUnavailable: ModeUnavailableExplanation?

    // MARK: Sessions
    public private(set) var sessions: [SessionModel] = []
    public var selectedSessionID: SessionID?

    // MARK: Prompts
    public var hostKeyChange: HostKeyChangeNotice?
    public var authorizationPrompt: PendingDecision<AuthorizationRequest>?
    public var hostKeyPrompt: PendingDecision<HostKeyPrompt>?
    public var errorMessage: String?

    // MARK: Remote
    public private(set) var hosts: [HostProfile] = []
    public private(set) var keys: [SSHKeyRecord] = []
    @ObservationIgnored private var connections: [UUID: SSHConnection] = [:]

    // MARK: Remote development
    public private(set) var builds: BuildCenter!

    // MARK: Capabilities & Access
    /// Mirror of the access switches for the interface. The services read the policy itself.
    public private(set) var accessSettings: AccessSettings
    public var pendingAccessChange: AccessChangeRequest?
    /// What the last confirmed change actually did (shown once).
    public var accessChangeOutcome: String?

    // MARK: Environment
    public private(set) var assessment: EnvironmentAssessment?
    /// The last explicit "Test local shell" result (Unleashed).
    public private(set) var lastShellTest: EnvironmentAssessment.Operation?
    public private(set) var isTestingShell = false
    public private(set) var appearance: AppearanceSettings

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.preferredMode = dependencies.preferences.preferredMode
        self.accessSettings = dependencies.access.settings
        self.appearance = dependencies.appearance.settings
        self.builds = BuildCenter(dependencies: dependencies) { [weak self] hostID in
            guard let self, let host = self.hosts.first(where: { $0.id == hostID }) else {
                throw RemoteSessionError.unknownHost
            }
            return try await self.connection(for: host)
        }
        self.builds.onRunFinished = { @MainActor [weak self] run in
            guard case .failed(let status) = run.status else {
                if run.status == .succeeded { self?.recordVerification(.buildOrchestration, observation: "\(run.plan.title) on \(run.plan.hostName) finished (exit 0).") }
                return
            }
            self?.recordVerification(.buildOrchestration, observation: "\(run.plan.title) on \(run.plan.hostName) ran to completion (exit \(status)).")
        }
    }

    /// Wires prompts and loads persisted state. Call once from the root view.
    public func bootstrap() async {
        await dependencies.gate.setPresenter { [weak self] request in
            await self?.ask(authorization: request) ?? false
        }
        hosts = await dependencies.hostStore.all()
        keys = dependencies.keyManager.list()
        await builds.reload()
        await refreshCapabilities()
        await refreshAssessment()
        if preferredMode != .vanilla, !isAvailable(preferredMode) {
            // A saved preference for a mode that cannot run here never takes effect.
            preferredMode = .vanilla
            dependencies.preferences.preferredMode = .vanilla
            await DiagnosticLog.shared.record(.notice, "mode", "Saved mode not available; using Vanilla")
        }
        await DiagnosticLog.shared.record(.info, "app", "Started", metadata: ["build": dependencies.distribution.rawValue, "mode": preferredMode.rawValue])
    }

    // MARK: - Capabilities

    public func refreshCapabilities() async {
        isDetecting = true
        defer { isDetecting = false }
        async let vanilla = dependencies.vanillaCapabilities.detectCapabilities()
        async let unleashed = dependencies.unleashedCapabilities.detectCapabilities()
        let (v, u) = await (vanilla, unleashed)
        detectedReports[.vanilla] = v
        detectedReports[.unleashed] = u
        applyVerifications()
    }

    private func applyVerifications() {
        for (mode, report) in detectedReports {
            reports[mode] = report
                .applying(verifications: verifications[mode] ?? [:])
                .applying(access: dependencies.access)
        }
    }

    /// Recheck: a fresh read-only scan (earlier test results keep their own times).
    public func recheckUnleashed() async {
        await dependencies.unleashedTools?.invalidateScan()
        await refreshCapabilities()
        await refreshAssessment()
    }

    /// Runs the detected shell once with a fixed, harmless command (5-second limit) and records
    /// the real result. Only "Verified working" after this (or a session) succeeded.
    public func testLocalShell() async {
        guard let tools = dependencies.unleashedTools else { return }
        isTestingShell = true
        defer { isTestingShell = false }
        lastShellTest = await tools.verifyShell()
        await refreshCapabilities()
        await refreshAssessment()
    }

    /// Re-reads the layered environment assessment (read-only).
    public func refreshAssessment() async {
        assessment = await dependencies.environmentAssessment()
    }

    // MARK: - Appearance

    public func updateAppearance(_ change: (inout AppearanceSettings) -> Void) {
        var updated = appearance
        change(&updated)
        dependencies.appearance.settings = updated
        appearance = dependencies.appearance.settings
    }

    #if DEBUG
    /// CI screenshots only (Debug builds): shows an appearance without saving it.
    public func previewAppearance(_ change: (inout AppearanceSettings) -> Void) {
        change(&appearance)
    }
    #endif

    // MARK: - Capabilities & Access

    /// The detected availability of what a switch governs, ignoring the switch itself
    /// (`nil` when no detection applies, e.g. files you pick in the system file picker).
    public func detectedAvailability(for control: AccessControl) -> CapabilityAvailability? {
        if control.requiresUnleashedBackend && dependencies.distribution == .standard {
            return .notIncluded(UnleashedNotIncludedCapabilityProvider.reason)
        }
        let mode: ExecutionMode = (control.requiresUnleashedBackend || (control == .processInspection && dependencies.distribution == .unleashed)) ? .unleashed : .vanilla
        guard let kind = control.capability(in: mode) ?? control.capability(in: .vanilla),
              let report = detectedReports[mode] ?? detectedReports[.vanilla] else { return nil }
        // Writing is its own capability in the report: available only where access(W_OK)
        // allowed it, verified only after a real write.
        return report.applying(verifications: verifications[mode] ?? [:])[kind].availability
    }

    @ObservationIgnored private var writeVerified = false

    /// Availability with the user's switch applied — what the interface shows as the status.
    public func effectiveAvailability(for control: AccessControl) -> CapabilityAvailability? {
        detectedAvailability(for: control).map {
            $0.applyingSwitch(enabled: dependencies.access.isEnabled(control), reason: dependencies.access.denial(control) ?? "")
        }
    }

    /// Asks to change a switch. Applies at once when nothing is running that it would stop and
    /// it does not widen access; otherwise `pendingAccessChange` is set for confirmation.
    public func requestAccessChange(_ control: AccessControl, enabled: Bool) async {
        guard dependencies.access.isOn(control) != enabled else { return }
        let request = accessChange(control, enabled: enabled)
        if request.needsConfirmation {
            pendingAccessChange = request
        } else {
            await applyAccessChange(request)
        }
    }

    func accessChange(_ control: AccessControl, enabled: Bool) -> AccessChangeRequest {
        let disabled = enabled ? [] : dependencies.access.newlyDisabled(ifSetting: control, to: false)
        var affected: [AccessChangeRequest.AffectedSession] = []
        for session in sessions where session.isLive {
            let consequence: String?
            switch session.backend {
            case .builtInCommands where disabled.contains(.workspaceCommands):
                consequence = "Ended (in-app session; nothing runs outside the app)."
            case .localProcess where disabled.contains(.localShell):
                consequence = "The shell and the programs it started are sent SIGHUP (then SIGKILL); the exit is confirmed before reporting."
            case .loopbackService where disabled.contains(.localhostSSH):
                consequence = "Disconnected from the device's SSH service. Programs started through it may keep running; not verified."
            case .sshShell, .sshCommand:
                consequence = disabled.contains(.remoteSSH)
                    ? "Disconnected. Programs started on the host may keep running there; HCG Terminal cannot confirm they stopped."
                    : nil
            default:
                consequence = nil
            }
            if let consequence {
                affected.append(.init(id: session.id, title: session.title, target: session.target, consequence: consequence))
            }
        }
        let caution: String? = switch (control, enabled) {
        case (.expandedFileWrite, true):
            "HCG Terminal may then change files outside its sandbox where the device allows it. System and jailbreak locations still ask before each change. Nothing on the device's permissions changes."
        case (.privilegedOperations, true):
            "Privileged commands HCG Terminal recognizes will be offered for approval one at a time instead of refused. HCG Terminal never supplies a password and never elevates by itself."
        default: nil
        }
        return AccessChangeRequest(
            control: control, enabled: enabled, newlyDisabled: disabled, sessions: affected,
            stopsRunningBuild: disabled.contains(.remoteBuilds) && builds.isRunning, caution: caution
        )
    }

    /// Confirms the pending change: sets the switch, then stops what it affects and reports
    /// exactly what is known about each stop.
    public func confirmAccessChange() async {
        guard let request = pendingAccessChange else { return }
        pendingAccessChange = nil
        await applyAccessChange(request)
    }

    /// Leaves the switch as it was; nothing is stopped.
    public func cancelAccessChange() {
        pendingAccessChange = nil
        accessSettings = dependencies.access.settings
    }

    private func applyAccessChange(_ request: AccessChangeRequest) async {
        dependencies.access.set(request.control, enabled: request.enabled)
        accessSettings = dependencies.access.settings
        var lines: [String] = []
        var localConfirmed = 0, localUnconfirmed = 0, disconnected = 0, ended = 0
        for affected in request.sessions {
            guard let model = session(affected.id) else { continue }
            switch await model.stop() {
            case .processExited: localConfirmed += 1
            case .processExitNotConfirmed: localUnconfirmed += 1
            case .disconnected: disconnected += 1
            case .ended: ended += 1
            }
        }
        if request.newlyDisabled.contains(.remoteSSH) {
            for (_, connection) in connections { await connection.close() }
            connections.removeAll()
        }
        if ended > 0 { lines.append("Ended \(ended) built-in command session\(ended == 1 ? "" : "s").") }
        if localConfirmed > 0 { lines.append("Stopped \(localConfirmed) local shell\(localConfirmed == 1 ? "" : "s"); exit confirmed.") }
        if localUnconfirmed > 0 { lines.append("Sent stop signals to \(localUnconfirmed) local shell\(localUnconfirmed == 1 ? "" : "s"), but the exit was not confirmed.") }
        if disconnected > 0 { lines.append("Disconnected \(disconnected) session\(disconnected == 1 ? "" : "s"). Programs started through them may still be running on the other side; that was not verified.") }
        if request.stopsRunningBuild {
            builds.cancel()
            lines.append("Cancelled the running build: the channel was closed and the remote process group was sent TERM. Whether it stopped is shown in the build log, not assumed.")
        }
        accessChangeOutcome = lines.isEmpty ? nil : lines.joined(separator: " ")
        await DiagnosticLog.shared.record(.notice, "access", "Switch changed", metadata: [
            "control": request.control.rawValue, "enabled": "\(request.enabled)",
            "stoppedSessions": "\(request.sessions.count)", "build": "\(request.stopsRunningBuild)",
        ])
        await refreshCapabilities()
    }

    /// Restores the factory switches (expanded write and privileged operations off). Uses the
    /// same confirmation rules for anything it would stop.
    public func resetAccessToDefaults() async {
        for control in AccessControl.allCases where dependencies.access.isOn(control) != control.defaultEnabled {
            await requestAccessChange(control, enabled: control.defaultEnabled)
            if pendingAccessChange != nil { return }
        }
    }

    /// Records a successful write (explicit write test or a saved file).
    public func noteWriteVerified() {
        writeVerified = true
    }

    /// Records that a capability was used successfully. Shared capabilities (remote SSH,
    /// builds) are recorded for both modes. Only "available, not tested" results change.
    public func recordVerification(_ kind: CapabilityKind, mode: ExecutionMode? = nil, observation: String) {
        let evidence = CapabilityEvidence(probe: "Used in this session", observation: observation, positive: true)
        for target in mode.map({ [$0] }) ?? ExecutionMode.allCases {
            verifications[target, default: [:]][kind] = evidence
        }
        applyVerifications()
    }

    public func report(for mode: ExecutionMode) -> CapabilityReport? { reports[mode] }

    /// True when the mode's local features can be used. Remote features never depend on this.
    public func isAvailable(_ mode: ExecutionMode) -> Bool {
        mode == .vanilla || (reports[mode]?.localFeaturesAvailable ?? false)
    }

    // MARK: - Mode switching

    /// Changes the preferred local mode. Never touches remote sessions and never moves a local
    /// session by itself; if local sessions could be moved, a confirmation is offered.
    public func selectMode(_ mode: ExecutionMode) {
        guard mode != preferredMode else { return }
        // A mode that cannot run here is explained, not selected: the current mode, its
        // appearance and every open session stay exactly as they are.
        guard isAvailable(mode) else {
            if let report = reports[mode] {
                modeUnavailable = ModeUnavailableExplanation(mode: mode, report: report, distribution: dependencies.distribution)
            } else {
                Task {
                    await refreshCapabilities()
                    if isAvailable(mode) { selectMode(mode) } else if let report = reports[mode] {
                        modeUnavailable = ModeUnavailableExplanation(mode: mode, report: report, distribution: dependencies.distribution)
                    }
                }
            }
            Task { await DiagnosticLog.shared.record(.info, "mode", "Mode not available; explained instead of switching", metadata: ["mode": mode.rawValue]) }
            return
        }
        let previous = preferredMode
        preferredMode = mode
        dependencies.preferences.preferredMode = mode
        let plan = ModeSwitchPolicy.plan(
            from: previous, to: mode, targetModeAvailable: isAvailable(mode),
            sessions: sessions.filter(\.isLive).map(\.snapshot)
        )
        if plan.offersMoveConfirmation {
            modeSwitchConfirmation = ModeSwitchConfirmation(plan: plan)
        }
        Task { await DiagnosticLog.shared.record(.info, "mode", "Preferred mode changed", metadata: ["from": previous.rawValue, "to": mode.rawValue, "remoteSessionsPreserved": "\(plan.preservedRemoteSessions.count)"]) }
        if reports[mode] == nil { Task { await refreshCapabilities() } }
    }

    /// Applies the user's answer to a move offer.
    public func resolveModeSwitch(_ decision: LocalSessionMoveDecision) async {
        guard let confirmation = modeSwitchConfirmation else { return }
        modeSwitchConfirmation = nil
        for action in ModeSwitchPolicy.actions(for: confirmation.plan, decision: decision) {
            guard case .restartLocalSession(let id, let mode) = action,
                  let old = sessions.first(where: { $0.id == id }), !old.state.isRunningCommand else { continue }
            await closeSession(id)
            await openLocalSession(mode: mode)
        }
    }

    // MARK: - Local sessions

    /// Opens a local session in `mode` (default: the preferred mode). Never falls back to a
    /// different mode or to a remote host.
    @discardableResult
    public func openLocalSession(mode requested: ExecutionMode? = nil) async -> SessionModel? {
        let mode = requested ?? preferredMode
        let provider: (any LocalExecutionProvider)?
        switch mode {
        case .vanilla: provider = dependencies.vanilla
        case .unleashed: provider = dependencies.unleashed
        }
        if let refusal = dependencies.access.denial(mode == .vanilla ? .workspaceCommands : .localShell), provider != nil {
            errorMessage = refusal
            return nil
        }
        guard let provider, isAvailable(mode) else {
            errorMessage = CapabilityReport.unleashedUnavailableMessage
            return nil
        }
        if mode == .unleashed, case .loopbackService? = await provider.availableBackend() {
            errorMessage = "No shell can be started directly. Use “Localhost SSH (this device)” if an SSH service runs here, and sign in with that service's account."
            return nil
        }
        do {
            let session = try await provider.makeSession()
            guard session.target == .local(mode) else {
                await session.close()
                throw ExecutionError.targetMismatch(expected: .local(mode), actual: session.target)
            }
            return await register(session, title: mode == .vanilla ? "Built-in commands" : "Local shell")
        } catch {
            errorMessage = error.localizedDescription
            await refreshCapabilities() // a failed spawn updates the Unleashed report
            return nil
        }
    }

    /// Connects to an existing terminal service on this device (Unleashed). The session's
    /// target is Local Unleashed, because the commands execute on this device.
    /// Hosts accepted for the localhost fallback (this device only; other hosts are Remote SSH).
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Signs in to an SSH service already running on this device, with that service's own
    /// account. The host key is verified like any host. Recorded as working only after the
    /// sign-in succeeded and a terminal (PTY) was opened.
    @discardableResult
    public func openLoopbackService(host: String = "127.0.0.1", port: Int, username: String, password: String) async -> SessionModel? {
        guard dependencies.distribution == .unleashed else {
            errorMessage = UnleashedNotIncludedCapabilityProvider.reason
            return nil
        }
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.loopbackHosts.contains(host), (1...65535).contains(port) else {
            errorMessage = "The localhost fallback connects only to this device (127.0.0.1, localhost or ::1) on ports 1–65535. Use Remote SSH for other hosts."
            return nil
        }
        let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "This device", hostname: host, port: port, username: username)
        do {
            let connection = try await SSHConnection.connect(
                endpoint: endpoint, authentication: .password(password), hostKeyPolicy: hostKeyPolicy,
                requiredAccess: [.localhostSSH], access: dependencies.access
            )
            let session = try await connection.openSession(
                size: .standard, target: .local(.unleashed), backend: .loopbackService(host: host, port: port)
            )
            await dependencies.unleashedTools?.recordLoopbackSignIn("\(username)@\(host):\(port)")
            await refreshCapabilities()
            return await register(session, title: "Unleashed · \(host):\(port)")
        } catch let error as SSHConnectionError {
            errorMessage = "\(error.category): \(error.localizedDescription)"
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Remote sessions

    public var hostKeyPolicy: HostKeyPolicy {
        HostKeyPolicy(knownHosts: dependencies.knownHosts) { [weak self] host, port, key in
            await self?.ask(hostKey: HostKeyPrompt(host: host, port: port, key: key)) ?? false
        }
    }

    func authentication(for host: HostProfile, enteredPassword: String? = nil) throws -> SSHAuthentication {
        func password() throws -> String {
            if let enteredPassword, !enteredPassword.isEmpty { return enteredPassword }
            guard let data = try dependencies.credentials.load(.hostPassword(host.id)) else {
                throw RemoteSessionError.missingPassword(host.name)
            }
            return String(decoding: data, as: UTF8.self)
        }
        switch host.auth {
        case .password: return .password(try password())
        case .key(let id): return .key(try dependencies.keyManager.privateKey(for: id))
        case .keyThenPassword(let id):
            return .keyThenPassword(try dependencies.keyManager.privateKey(for: id), password: try password())
        }
    }

    /// Returns the open connection for `host`, connecting if needed.
    public func connection(for host: HostProfile) async throws -> SSHConnection {
        if let existing = connections[host.id], existing.isActive { return existing }
        connections[host.id] = nil
        let connection: SSHConnection
        do {
            connection = try await SSHConnection.connect(endpoint: host.endpoint, authentication: authentication(for: host), hostKeyPolicy: hostKeyPolicy, access: dependencies.access)
        } catch let error as SSHConnectionError {
            noteHostKeyChange(error, host: host)
            throw error
        }
        connections[host.id] = connection
        recordVerification(.remoteSSH, observation: "Connected to \(host.endpoint.address).")
        return connection
    }

    private func noteHostKeyChange(_ error: SSHConnectionError, host: HostProfile) {
        if case .hostKeyChanged(let expected, let presented) = error {
            hostKeyChange = HostKeyChangeNotice(host: host, expectedFingerprint: expected, presentedFingerprint: presented)
        }
    }

    /// After the user explicitly chose to: removes the stored key for this host. The next
    /// connection asks them to verify the new fingerprint before anything is trusted.
    public func forgetHostKey(_ notice: HostKeyChangeNotice) async {
        try? await dependencies.knownHosts.forget(host: notice.host.hostname, port: notice.host.port)
        hostKeyChange = nil
        await DiagnosticLog.shared.record(.notice, "ssh", "Old host key removed by the user", metadata: ["host": notice.host.endpoint.address])
    }

    /// Connects with the given (possibly unsaved) settings, runs read-only checks and
    /// disconnects. Nothing is saved; an unknown host key still needs explicit approval.
    public func testConnection(_ host: HostProfile, enteredPassword: String?) async -> ConnectionTestResult {
        let started = Date()
        do {
            let connection = try await SSHConnection.connect(
                endpoint: host.endpoint, authentication: authentication(for: host, enteredPassword: enteredPassword), hostKeyPolicy: hostKeyPolicy,
                access: dependencies.access
            )
            defer { Task { await connection.close() } }
            let shell = try await connection.run("printf '%s' \"${SHELL:-unknown}\"").stdoutText
            let toolchains = try await ToolchainProbe.probe(connection)
            recordVerification(.remoteSSH, observation: "Connection test to \(host.endpoint.address) succeeded.")
            return .success(system: toolchains.operatingSystem, shell: shell, tools: toolchains.tools, elapsed: Date().timeIntervalSince(started))
        } catch let error as SSHConnectionError {
            noteHostKeyChange(error, host: host)
            return .failure(category: error.category, message: error.localizedDescription)
        } catch let denied as AccessDenied {
            return .failure(category: "Turned off", message: denied.localizedDescription)
        } catch {
            return .failure(category: "Error", message: error.localizedDescription)
        }
    }

    /// The saved host a remote session belongs to.
    public func host(for session: SessionModel) -> HostProfile? {
        guard let id = session.target.remoteEndpoint?.hostID else { return nil }
        return hosts.first { $0.id == id }
    }

    /// Opens a fresh shell to the same host after a session ended. Nothing from the old session
    /// (and no build) is re-run.
    @discardableResult
    public func reconnect(_ session: SessionModel) async -> SessionModel? {
        guard let host = host(for: session) else {
            errorMessage = "The host for this session is no longer saved."
            return nil
        }
        if let connection = connections[host.id], !connection.isActive { connections[host.id] = nil }
        return await openRemoteShell(host)
    }

    /// Explicitly runs an ended PTY command session again (for example Claude Code).
    @discardableResult
    public func runAgain(_ session: SessionModel) async -> SessionModel? {
        guard case .sshCommand(let command) = session.backend, let host = host(for: session) else { return nil }
        do {
            let fresh = try await connection(for: host).openSession(size: .standard, command: command)
            return await register(fresh, title: session.title)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func openRemoteShell(_ host: HostProfile) async -> SessionModel? {
        do {
            let session = try await connection(for: host).openSession(size: .standard)
            return await register(session, title: host.name)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Runs Claude Code in `projectPath` on the remote host, in its own PTY session.
    @discardableResult
    public func openClaudeCode(_ host: HostProfile, projectPath: String) async -> SessionModel? {
        do {
            let session = try await connection(for: host).openSession(size: .standard, command: ClaudeCodeLauncher.command(projectPath: projectPath))
            return await register(session, title: "Claude Code · \(host.name)")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Opens a new Local Unleashed session and types `command` into it — used after the user
    /// approved a package action. The command is visible and runs with the device's permissions.
    public func runApprovedCommandInNewUnleashedSession(_ command: String) async {
        guard let model = await openLocalSession(mode: .unleashed) else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        model.send(Array((command + "\r").utf8))
    }

    /// Registers and starts a session prepared elsewhere (e.g. a program from Unleashed Tools).
    /// Local Unleashed sessions are refused while the shell switch is off.
    @discardableResult
    public func openPreparedSession(_ session: any TerminalSession, title: String) async -> SessionModel? {
        if session.target == .local(.unleashed), let refusal = dependencies.access.denial(.localShell) {
            await session.close()
            errorMessage = refusal
            return nil
        }
        return await register(session, title: title)
    }

    public func disconnect(_ host: HostProfile) async {
        for session in sessions where session.target.remoteEndpoint?.hostID == host.id {
            await closeSession(session.id)
        }
        await connections.removeValue(forKey: host.id)?.close()
    }

    /// Test hook for registering arbitrary sessions.
    var sessionsForTesting: [SessionModel] {
        get { sessions }
        set { sessions = newValue }
    }

    public func isConnected(_ host: HostProfile) -> Bool { connections[host.id]?.isActive ?? false }

    // MARK: - Session bookkeeping

    private func register(_ session: any TerminalSession, title: String) async -> SessionModel {
        let model = SessionModel(session: session, title: title, modeAtCreation: preferredMode)
        model.attach()
        sessions.append(model)
        selectedSessionID = model.id
        do {
            try await session.start(size: .standard)
        } catch {
            errorMessage = error.localizedDescription
            await refreshCapabilities()
        }
        return model
    }

    public func session(_ id: SessionID?) -> SessionModel? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    public func closeEndedSessions() async {
        for session in sessions where !session.isLive { await closeSession(session.id) }
    }

    public func closeSession(_ id: SessionID) async {
        guard let model = sessions.first(where: { $0.id == id }) else { return }
        await model.close()
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = sessions.last?.id }
    }

    // MARK: - Hosts and keys

    public func saveHost(_ host: HostProfile, password: String?) async {
        do {
            if let password, !password.isEmpty {
                try dependencies.credentials.save(Data(password.utf8), for: .hostPassword(host.id))
            }
            try await dependencies.hostStore.save(host)
            hosts = await dependencies.hostStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteHost(_ host: HostProfile) async {
        await disconnect(host)
        try? dependencies.credentials.delete(.hostPassword(host.id))
        try? await dependencies.hostStore.delete(host.id)
        hosts = await dependencies.hostStore.all()
    }

    @discardableResult
    public func generateKey(comment: String) -> SSHKeyRecord? {
        do {
            let record = try dependencies.keyManager.generateEd25519(comment: comment)
            keys = dependencies.keyManager.list()
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Imports a private key file's text. Decryption (bcrypt, deliberately slow) runs off the
    /// main actor. The passphrase is used once and not stored. Errors are returned to the caller
    /// (the import sheet shows them in place).
    @discardableResult
    public func importKey(text: String, passphrase: String?, name: String?) async throws -> SSHKeyRecord {
        let imported = try await Task.detached(priority: .userInitiated) {
            try OpenSSHKeyImport.parse(text, passphrase: passphrase)
        }.value
        let chosen = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let comment = !chosen.isEmpty ? chosen : (!imported.comment.isEmpty ? imported.comment : "imported \(imported.key.displayName) key")
        let record = try dependencies.keyManager.importKey(imported, comment: comment)
        keys = dependencies.keyManager.list()
        return record
    }

    public func deleteKey(_ record: SSHKeyRecord) {
        try? dependencies.keyManager.delete(record.id)
        keys = dependencies.keyManager.list()
    }

    // MARK: - Prompts

    func ask(authorization request: AuthorizationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            // A new request while one is open denies the older one; nothing is ever approved implicitly.
            authorizationPrompt?.resolve(false)
            var resolved = false
            authorizationPrompt = PendingDecision(request: request) { [weak self] granted in
                guard !resolved else { return }
                resolved = true
                self?.authorizationPrompt = nil
                continuation.resume(returning: granted)
            }
        }
    }

    func ask(hostKey prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyPrompt?.resolve(false)
            var resolved = false
            hostKeyPrompt = PendingDecision(request: prompt) { [weak self] approved in
                guard !resolved else { return }
                resolved = true
                self?.hostKeyPrompt = nil
                continuation.resume(returning: approved)
            }
        }
    }

    public func answerAuthorization(_ granted: Bool) { authorizationPrompt?.resolve(granted) }
    public func answerHostKey(_ approved: Bool) { hostKeyPrompt?.resolve(approved) }
}

public enum RemoteSessionError: Error, LocalizedError, Equatable {
    case missingPassword(String)
    case unknownHost

    public var errorDescription: String? {
        switch self {
        case .missingPassword(let host): "No password is saved for \(host). Edit the host to add one."
        case .unknownHost: "The host for this build is no longer saved."
        }
    }
}
