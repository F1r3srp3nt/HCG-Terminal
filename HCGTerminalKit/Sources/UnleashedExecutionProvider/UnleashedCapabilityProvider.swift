import Foundation
import TerminalCapabilityProvider
import TerminalCore

/// Capability report for Unleashed, built from the read-only scan plus runtime observations.
public struct UnleashedCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .unleashed
    private let scanner: UnleashedEnvironmentScanner
    private let observations: RuntimeObservations

    public init(probe: any SystemProbing = LiveSystemProbe(), observations: RuntimeObservations, customRoots: @escaping @Sendable () -> [String] = { [] }) {
        self.scanner = UnleashedEnvironmentScanner(probe: probe, customRoots: customRoots)
        self.observations = observations
    }

    public func scan() -> UnleashedEnvironmentScan { scanner.scan() }

    public func detectCapabilities() async -> CapabilityReport {
        let scan = scanner.scan()
        return await Self.report(for: scan, observations: observations)
    }

    /// Builds the report from the read-only scan and what real use has shown.
    ///
    /// Decision order for each capability:
    /// 1. real use (spawn succeeded / failed with errno) decides first;
    /// 2. then read-only checks: found → "available, not tested";
    /// 3. a probe the system refused (EPERM/EACCES) → "permission denied";
    /// 4. a visible environment without the needed program → "required tool missing";
    /// 5. nothing of a shell environment visible → "unsupported environment".
    /// Linked modules or a jailbreak marker alone never make anything available.
    public static func report(for scan: UnleashedEnvironmentScan, observations: RuntimeObservations) async -> CapabilityReport {
        let denied = scan.deniedPaths
        let deniedNote = denied.isEmpty ? nil : "The system refused this app access to \(denied.joined(separator: ", "))."
        let stockReason = "No shell environment is observable from this app. A sandboxed install sees this even on a jailbroken device, so it does not show whether the device is jailbroken."
        func absent(_ tool: String) -> CapabilityAvailability {
            if let deniedNote, !scan.environmentVisible { return .permissionDenied(deniedNote) }
            return scan.environmentVisible ? .toolMissing("\(tool) was not found in the visible environment.") : .environmentUnknown(stockReason)
        }
        func spawnState(_ code: Int32, _ message: String) -> CapabilityAvailability {
            switch code {
            case EPERM, EACCES: .permissionDenied("The system refused to start it: \(message). Apps installed through TestFlight, the App Store or Xcode run in the sandbox and cannot start processes.")
            case ENOENT: .toolMissing("It disappeared before it could be started: \(message).")
            case ENOEXEC: .toolMissing("It is not a program this device can run: \(message).")
            default: .environmentUnknown("Starting it failed: \(message).")
            }
        }

        // Local shell
        let shellChecks = scan.evidence.filter { $0.probe.contains("X_OK") || $0.probe.contains("127.0.0.1") || $0.probe.hasPrefix("lstat") }
        var shellOutcome: RuntimeObservations.SpawnOutcome?
        if let shell = scan.shells.first { shellOutcome = await observations.outcome(for: shell) }
        var shellAvailability: CapabilityAvailability
        var shellSummary = "Start a shell on this device in a pseudo-terminal."
        if let shell = scan.shells.first {
            switch shellOutcome {
            case .succeeded(let pid)?:
                shellAvailability = .verified("\(shell) started in a pseudo-terminal (pid \(pid)).")
            case .failed(let code, let message)?:
                shellAvailability = spawnState(code, message)
            case nil:
                shellAvailability = .availableUntested("\(shell) exists and is executable; it has not been started yet.")
            }
            if !shellAvailability.isUsable, let port = scan.loopbackServicePorts.first {
                shellSummary = "Start a shell on this device, or sign in to the terminal service on 127.0.0.1:\(port)."
                shellAvailability = .availableUntested("\(shellAvailability.reason) A terminal service accepts connections on 127.0.0.1:\(port); signing in has not been tested.")
            }
        } else if let port = scan.loopbackServicePorts.first {
            shellSummary = "Sign in to the terminal service running on this device."
            shellAvailability = .availableUntested("A terminal service accepts connections on 127.0.0.1:\(port) (no data sent). Signing in uses that service's own account and has not been tested.")
        } else {
            shellAvailability = absent("No shell (sh, bash, zsh, dash) and no terminal service on 127.0.0.1:22/2222")
        }
        let shellResult = CapabilityResult(kind: .localShell, availability: shellAvailability, summary: shellSummary, evidence: shellChecks)

        // Executable access
        let executableCount = scan.executableDirectories.values.reduce(0, +)
        let executableChecks = scan.evidence.filter { $0.probe.hasPrefix("list ") }
        let executableAvailability: CapabilityAvailability
        if executableCount == 0 {
            executableAvailability = absent("No directory with executables")
        } else if case .failed(let code, let message)? = shellOutcome {
            executableAvailability = spawnState(code, message)
        } else if await observations.anySucceeded() {
            executableAvailability = .verified("Processes started successfully; \(executableCount) executables visible.")
        } else {
            executableAvailability = .availableUntested("\(executableCount) executables visible in \(scan.executableDirectories.keys.sorted().joined(separator: ", ")); none started yet.")
        }
        let executableResult = CapabilityResult(kind: .executableAccess, availability: executableAvailability, summary: "Run installed command-line tools from a local shell.", evidence: executableChecks)

        // Filesystem
        let listable = scan.locations.filter(\.listable).map(\.path)
        let writable = scan.locations.filter(\.writable).map(\.path)
        let fsChecks = scan.locations.map { location in
            CapabilityEvidence(
                probe: "lstat/list \(location.path)",
                observation: location.exists
                    ? "listable=\(location.listable) readable=\(location.readable) writable(access)=\(location.writable)"
                    : (scan.pathProbes[location.path]?.description ?? "not found"),
                positive: location.listable
            )
        }
        let fsAvailability: CapabilityAvailability
        if !listable.isEmpty {
            fsAvailability = .verified("Listed \(listable.joined(separator: ", ")). Writable per access(2), not yet written: \(writable.isEmpty ? "none" : writable.joined(separator: ", ")).")
        } else if scan.locations.contains(where: { scan.pathProbes[$0.path]?.isDenied == true || ($0.exists && !$0.listable) }) {
            fsAvailability = .permissionDenied("Locations outside the app sandbox exist but this app may not list them.")
        } else {
            fsAvailability = .environmentUnknown("No location outside the app sandbox is visible to this app.")
        }
        let filesystemResult = CapabilityResult(kind: .filesystemPermissions, availability: fsAvailability, summary: "Browse and read permitted locations outside the app sandbox; access is exactly what the device grants.", evidence: fsChecks)

        // Package manager
        let packageChecks = scan.packageManagers.map { CapabilityEvidence(probe: "access(\($0.path), X_OK)", observation: "executable", positive: true) }
        let packageAvailability: CapabilityAvailability = scan.packageManagers.isEmpty
            ? absent("No apt or dpkg")
            : .availableUntested("\(scan.packageManagers.map(\.name).joined(separator: ", ")) found; listing installed packages has not run yet.")
        let packageResult = CapabilityResult(
            kind: .packageManager, availability: packageAvailability,
            summary: "List installed packages (read-only); install or remove only after your approval, with the device's permissions.",
            evidence: packageChecks, requiresAuthorization: !scan.packageManagers.isEmpty
        )

        // Process inspection
        let processChecks = scan.evidence.filter { $0.probe.hasPrefix("sysctl") }
        let processAvailability: CapabilityAvailability
        switch scan.visibleProcessCount {
        case .some(let count) where count > 1: processAvailability = .verified("The process table returned \(count) processes.")
        case .some: processAvailability = .permissionDenied("The system shows this app only its own process.")
        case nil: processAvailability = .permissionDenied("sysctl(KERN_PROC_ALL) was refused.")
        }
        let processResult = CapabilityResult(kind: .processInspection, availability: processAvailability, summary: "List running processes (read-only).", evidence: processChecks)

        // Privileged operations
        let privilegeChecks = scan.evidence.filter { $0.probe == "geteuid()" }
            + scan.elevationTools.map { CapabilityEvidence(probe: "access(\($0.path), X_OK)", observation: "executable", positive: true) }
        let privilegedAvailability: CapabilityAvailability
        if scan.effectiveUserID == 0 {
            privilegedAvailability = .availableUntested("This app process runs as root (euid 0).")
        } else if let tool = scan.elevationTools.first {
            privilegedAvailability = .availableUntested("\(tool.name) found at \(tool.path). It asks for its own password, which HCG Terminal never supplies or stores.")
        } else {
            privilegedAvailability = absent("No sudo or su (commands would run as uid \(scan.effectiveUserID))")
        }
        let privilegedResult = CapabilityResult(
            kind: .privilegedOperations, availability: privilegedAvailability,
            summary: "Run privileged commands only after you approve each one; HCG Terminal never elevates by itself.",
            evidence: privilegeChecks, requiresAuthorization: true
        )

        let localAvailable = shellResult.availability.isUsable
        var notes = ["Unleashed build: backend linked. \(scan.operatingSystem)"]
        if let deniedNote { notes.append(deniedNote) }
        return CapabilityReport(
            mode: .unleashed,
            results: [
                shellResult, executableResult, filesystemResult, packageResult, processResult, privilegedResult,
                SharedCapabilities.remoteSSH(), SharedCapabilities.buildOrchestration(),
            ],
            localFeaturesAvailable: localAvailable,
            headline: localAvailable
                ? "Unleashed: \(shellResult.availability.label.lowercased()). Nothing is installed or elevated automatically."
                : CapabilityReport.unleashedUnavailableMessage,
            buildNotes: notes
        )
    }
}

public extension UnleashedCapabilityProvider {
    /// The full layered assessment (read-only; nothing is executed or written).
    func assessment(variant: String = "unleashed", operations: [EnvironmentAssessment.Operation] = [], shellEnabled: Bool) async -> EnvironmentAssessment {
        let scan = scan()
        let report = await Self.report(for: scan, observations: observations)
        let process = HostIdentity.process(deniedProbes: scan.deniedPaths)
        let shell: EnvironmentAssessment.ShellVerdict
        if !shellEnabled {
            shell = .disabledByUser
        } else {
            switch report[.localShell].availability {
            case .verified(let s): shell = .verified(s)
            case .permissionDenied(let s): shell = .permissionDenied(s)
            case .availableUntested(let s): shell = .availableUntested(s)
            case .toolMissing(let s): shell = .toolMissing(s)
            case .environmentUnknown(let s), .notIncluded(let s), .disabledByUser(let s): shell = .unknown(s)
            }
        }
        return EnvironmentAssessment(
            build: .init(variant: variant, backendLinked: true, backendComponents: UnleashedBackend.components),
            device: HostIdentity.device(),
            bootstrap: .init(
                roots: scan.roots, indicators: scan.indicators, resolvedTools: scan.resolvedTools,
                verdict: EnvironmentAssessment.verdict(indicators: scan.indicators, process: process)
            ),
            process: process,
            operations: operations,
            shell: shell
        )
    }
}

/// Identifies the Unleashed backend inside a built binary. The marker string is referenced at
/// runtime (Diagnostics), so it survives dead stripping; build checks search the executable for
/// it to prove the backend is really linked (a name or bundle ID alone proves nothing).
public enum UnleashedBackend {
    public static let marker = "HCG-UNLEASHED-BACKEND-LINKED-v1"
    public static let components = ["PTY shell", "program launcher", "environment scanner", "host filesystem", "package client", "explicit verification"]
}
