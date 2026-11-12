import Foundation
import TerminalCapabilityProvider
import TerminalCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Capability report for Unleashed, built from the read-only scan plus runtime observations.
public struct UnleashedCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .unleashed
    private let scanner: UnleashedEnvironmentScanner
    private let observations: RuntimeObservations

    public init(
        probe: any SystemProbing = LiveSystemProbe(),
        observations: RuntimeObservations,
        customRoots: @escaping @Sendable () -> [String] = { [] },
        prefixResolver: @escaping @Sendable () -> String? = { JailbreakPrefixResolver.prefixFromLoadedResolver() }
    ) {
        self.scanner = UnleashedEnvironmentScanner(probe: probe, customRoots: customRoots, prefixResolver: prefixResolver)
        self.observations = observations
    }

    public func scan() -> UnleashedEnvironmentScan { scanner.scan() }

    public func detectCapabilities() async -> CapabilityReport {
        let scan = scanner.scan()
        return await Self.report(for: scan, observations: observations)
    }

    // MARK: - Report

    /// Builds the report. Every capability is decided independently from its own evidence:
    /// 1. what real use showed (a launch, a sign-in, a write) — but only while the thing used
    ///    still exists (older results for something no longer found are reported as stale);
    /// 2. read-only checks that passed → "available, untested";
    /// 3. EPERM/EACCES → "permission denied" (never "missing");
    /// 4. ENOENT for every candidate in roots that could be inspected → "tool missing";
    /// 5. otherwise "environment unknown".
    /// Bootstrap markers never make anything available.
    public static func report(for scan: UnleashedEnvironmentScan, observations: RuntimeObservations) async -> CapabilityReport {
        let spawns = await observations.allObservations()
        let signIn = await observations.loopbackSignIn()
        let writes = await observations.verifiedWrites()
        let time = scan.scannedAt
        let sandboxNote = "Apps installed from Xcode, TestFlight or the App Store run in the iOS sandbox, which refuses this. Reinstalling the tools will not change it; see Setup requirements."

        func record(_ probe: ProbeRecord) -> CapabilityEvidence { CapabilityEvidence(probe) }
        func candidateEvidence(_ candidate: ToolCandidate) -> CapabilityEvidence {
            let last = candidate.probes.last
            return CapabilityEvidence(
                probe: candidate.path + (candidate.resolvedPath.map { $0 == candidate.path ? "" : " → \($0)" } ?? ""),
                observation: candidate.state.label, positive: candidate.state == .executable,
                returnValue: last?.returnValue, errorCode: last?.errorCode, timestamp: last?.timestamp
            )
        }
        func launchState(_ path: String, _ observation: RuntimeObservations.Observation) -> CapabilityAvailability {
            let when = observation.date.formatted(date: .omitted, time: .standard)
            switch observation.outcome {
            case .succeeded(let pid):
                return .verified("\(path) was launched at \(when) (pid \(pid)) and completed.")
            case .failed(let code, let message):
                switch code {
                case EPERM, EACCES: return .permissionDenied("Launching \(path) was refused at \(when): \(message). \(sandboxNote)")
                case ENOENT: return .toolMissing("\(path) was not there when launched at \(when): \(message).")
                case ENOEXEC: return .toolMissing("\(path) is not a program this device can run (\(message)).")
                default: return .environmentUnknown("Launching \(path) failed at \(when): \(message).")
                }
            }
        }
        /// Observations for paths that still exist; others are stale.
        func currentObservations(_ candidates: [ToolCandidate]) -> (current: [(String, RuntimeObservations.Observation)], stale: [String]) {
            var current: [(String, RuntimeObservations.Observation)] = []
            var stale: [String] = []
            for (path, observation) in spawns {
                guard let candidate = candidates.first(where: { $0.path == path }) else { continue }
                if candidate.state.exists { current.append((path, observation)) } else { stale.append(path) }
            }
            return (current.sorted { $0.1.date > $1.1.date }, stale)
        }
        let deniedRoots = scan.roots.filter { $0.probe.isDenied }.map { $0.path.isEmpty ? "/" : $0.path }
        let visibleRoots = scan.roots.filter { !$0.path.isEmpty && $0.probe == .present }.map(\.path)
        /// For tools not found: absence only when the roots they live in could be inspected.
        func notFound(_ what: String, candidates: [ToolCandidate]) -> CapabilityAvailability {
            let denied = candidates.filter { if case .denied = $0.state { true } else { false } }
            if let first = denied.first, case .denied(let operation, let code) = first.state {
                let paths = denied.prefix(4).map(\.path).joined(separator: ", ")
                let roots = deniedRoots.isEmpty ? "" : " Access to \(deniedRoots.joined(separator: ", ")) was refused as well."
                if operation == "lstat" {
                    return .permissionDenied("\(paths) could not be inspected (lstat refused: \(PathProbe.errnoName(code))).\(roots) Whether \(what) is installed cannot be determined. \(sandboxNote)")
                }
                return .permissionDenied("\(paths) \(denied.count == 1 ? "exists" : "exist") but \(operation) was refused (\(PathProbe.errnoName(code))). That does not mean \(what) is missing. \(sandboxNote)")
            }
            if let broken = candidates.first(where: { if case .brokenSymlink = $0.state { true } else { false } }), case .brokenSymlink(let target) = broken.state {
                return .toolMissing("\(broken.path) is a symlink to \(target), which does not exist.")
            }
            if candidates.contains(where: { $0.state == .notExecutable }) {
                return .toolMissing("\(what.capitalized) exists but has no execute permission: \(candidates.filter { $0.state == .notExecutable }.map(\.path).joined(separator: ", ")).")
            }
            if !visibleRoots.isEmpty || !scan.programFolderListings.filter(\.succeeded).isEmpty {
                return .toolMissing("No \(what) found. Checked \(candidates.count) paths under \(visibleRoots.isEmpty ? "/" : visibleRoots.joined(separator: ", ")) (all ENOENT).")
            }
            if !deniedRoots.isEmpty {
                return .permissionDenied("The system refused this app access to \(deniedRoots.joined(separator: ", ")); whether \(what) is installed cannot be determined.")
            }
            return .environmentUnknown("No bootstrap root is visible to this app. A sandboxed install sees this even on a jailbroken device, so it says nothing about whether the device is jailbroken.")
        }

        var results: [CapabilityResult] = []

        // Local shell -------------------------------------------------------------
        let (shellObservations, staleShells) = currentObservations(scan.shellCandidates)
        var shellAvailability: CapabilityAvailability
        if let success = shellObservations.first(where: { if case .succeeded = $0.1.outcome { true } else { false } }) {
            shellAvailability = launchState(success.0, success.1)
        } else if let failure = shellObservations.first {
            shellAvailability = launchState(failure.0, failure.1)
        } else if let shell = scan.shellCandidates.first(where: { $0.state == .executable }) {
            shellAvailability = .availableUntested("\(shell.path) passed access(X_OK). It has not been launched yet; use Test local shell.")
        } else {
            shellAvailability = notFound("a shell", candidates: scan.shellCandidates)
        }
        var shellEvidence = scan.shellCandidates.filter { $0.state != .missing }.map(candidateEvidence)
        let missingShells = scan.shellCandidates.filter { $0.state == .missing }.map(\.path)
        for root in scan.roots where root.probe.isDenied {
            shellEvidence.append(CapabilityEvidence(probe: "lstat(\(root.path.isEmpty ? "/" : root.path))", observation: root.probe.description, positive: false, returnValue: -1, errorCode: { if case .denied(let c) = root.probe { c } else { nil } }(), timestamp: time))
        }
        if !missingShells.isEmpty {
            shellEvidence.append(CapabilityEvidence(probe: "lstat: " + missingShells.joined(separator: ", "), observation: "not found (ENOENT)", positive: false, returnValue: -1, errorCode: ENOENT, timestamp: time))
        }
        for path in staleShells {
            shellEvidence.append(CapabilityEvidence(probe: "earlier result for \(path)", observation: "no longer applies: the file is not found now", positive: false, timestamp: time))
        }
        results.append(CapabilityResult(kind: .localShell, availability: shellAvailability, summary: "Start a shell on this device in a pseudo-terminal.", evidence: shellEvidence))

        // Localhost SSH fallback ----------------------------------------------------
        let loopbackAvailability: CapabilityAvailability
        if let (endpoint, date) = signIn {
            loopbackAvailability = .verified("Signed in to \(endpoint) and opened a terminal at \(date.formatted(date: .omitted, time: .standard)).")
        } else if let open = scan.loopbackProbes.first(where: \.succeeded) {
            loopbackAvailability = .availableUntested("\(open.path) accepts connections. Sign-in and a terminal have not been tested; an open port alone proves neither.")
        } else if !scan.loopbackProbes.isEmpty, scan.loopbackProbes.allSatisfy({ $0.errorCode == ECONNREFUSED }) {
            loopbackAvailability = .toolMissing("Nothing is listening on \(scan.loopbackProbes.map(\.path).joined(separator: " or ")) (connection refused). If your SSH service uses another port, enter it in Configure connection.")
        } else {
            loopbackAvailability = .environmentUnknown("No answer from \(scan.loopbackProbes.map(\.path).joined(separator: " or ")) (filtered or busy).")
        }
        results.append(CapabilityResult(kind: .localhostSSH, availability: loopbackAvailability, summary: "Sign in to an SSH service already running on this device; host key verified.", evidence: scan.loopbackProbes.map(record)))

        // Running programs ---------------------------------------------------------
        let allCandidates = scan.shellCandidates + scan.toolCandidates
        let (programObservations, _) = currentObservations(allCandidates)
        let programAvailability: CapabilityAvailability
        let deniedFolders = scan.programFolderListings.filter(\.showsDenial)
        if let success = programObservations.first(where: { if case .succeeded = $0.1.outcome { true } else { false } }) {
            programAvailability = launchState(success.0, success.1)
        } else if let failure = programObservations.first {
            programAvailability = launchState(failure.0, failure.1)
        } else if let tool = allCandidates.first(where: { $0.state == .executable }) {
            programAvailability = .availableUntested("\(tool.path) passed access(X_OK); nothing has been launched yet.")
        } else if !scan.executableDirectories.isEmpty {
            programAvailability = .availableUntested("Executables are listed in \(scan.executableDirectories.keys.sorted().joined(separator: ", ")); none launched yet.")
        } else if !deniedFolders.isEmpty || allCandidates.contains(where: { if case .denied = $0.state { true } else { false } }) {
            let folders = deniedFolders.map(\.path).joined(separator: ", ")
            let deniedTools = allCandidates.filter { if case .denied = $0.state { true } else { false } }
            let parts = [folders.isEmpty ? nil : "listing \(folders) was refused (EPERM)", deniedTools.isEmpty ? nil : "access to \(deniedTools.prefix(3).map(\.path).joined(separator: ", ")) was refused"].compactMap { $0 }
            programAvailability = .permissionDenied("The system refused this app: \(parts.joined(separator: "; ")). That does not mean the programs are missing. \(sandboxNote)")
        } else {
            programAvailability = notFound("any program", candidates: allCandidates)
        }
        results.append(CapabilityResult(kind: .executableAccess, availability: programAvailability, summary: "Run installed command-line programs from a local shell or Unleashed Tools.", evidence: scan.programFolderListings.map(record)))

        // Filesystem: listing, reading, writing (separate) --------------------------
        let listed = scan.locationProbes.filter(\.listing.succeeded)
        let listDenied = scan.locationProbes.filter(\.listing.showsDenial)
        let listingAvailability: CapabilityAvailability
        if !listed.isEmpty {
            listingAvailability = .verified("Listed \(listed.map(\.path).joined(separator: ", ")) at \(time.formatted(date: .omitted, time: .standard)).")
        } else if !listDenied.isEmpty {
            listingAvailability = .permissionDenied("Listing was refused for \(listDenied.map(\.path).joined(separator: ", ")).")
        } else {
            listingAvailability = .environmentUnknown("No location outside the app sandbox is visible to this app.")
        }
        results.append(CapabilityResult(
            kind: .filesystemPermissions, availability: listingAvailability,
            summary: "List folders outside the app sandbox. Listing a folder does not prove its files can be read.",
            evidence: scan.locationProbes.map { record($0.listing) },
            partial: !listed.isEmpty && !listDenied.isEmpty, scope: listed.map(\.path)
        ))

        let reads = scan.locationProbes.compactMap(\.fileRead)
        let readOK = reads.filter(\.succeeded)
        let readAvailability: CapabilityAvailability
        if !readOK.isEmpty {
            readAvailability = .verified("Read \(readOK.map(\.path).joined(separator: ", ")).")
        } else if let denied = reads.first(where: \.showsDenial) {
            readAvailability = .permissionDenied("Opening \(denied.path) was refused (\(PathProbe.errnoName(denied.errorCode ?? EPERM))).")
        } else if !listed.isEmpty {
            readAvailability = .availableUntested("Folders can be listed, but no file in them has been read yet.")
        } else {
            readAvailability = listingAvailability.isUsable ? .availableUntested("Not tested yet.") : listingAvailability
        }
        results.append(CapabilityResult(
            kind: .fileReading, availability: readAvailability,
            summary: "Read file contents outside the app sandbox (one byte of one file per folder is read during the check).",
            evidence: reads.map(record),
            partial: !readOK.isEmpty && (readOK.count < reads.count || !listDenied.isEmpty),
            scope: readOK.map { ($0.path as NSString).deletingLastPathComponent }
        ))

        let writable = scan.locationProbes.filter { $0.writeCheck?.succeeded == true }
        let writeAvailability: CapabilityAvailability
        if let (directory, date) = writes.max(by: { $0.value < $1.value }) {
            writeAvailability = .verified("A test file was written, read back and removed in \(directory) at \(date.formatted(date: .omitted, time: .standard)).")
        } else if !writable.isEmpty {
            writeAvailability = .availableUntested("access(W_OK) passes in \(writable.map(\.path).joined(separator: ", ")). Nothing has been written; run the write test to verify.")
        } else if !listed.isEmpty {
            writeAvailability = .permissionDenied("access(W_OK) was refused in every listed location (\(listed.map(\.path).joined(separator: ", "))).")
        } else {
            writeAvailability = .environmentUnknown("No location outside the app sandbox is visible to this app.")
        }
        results.append(CapabilityResult(
            kind: .fileWriting, availability: writeAvailability,
            summary: "Create or change files outside the sandbox; always controlled by you, with approval for system locations.",
            evidence: scan.locationProbes.compactMap(\.writeCheck).map(record),
            partial: writes.isEmpty == false && writable.count > writes.count,
            scope: writes.isEmpty ? writable.map(\.path) : Array(writes.keys)
        ))

        // Packages: inventory and changes (separate) --------------------------------
        let packageTools = scan.toolCandidates.filter { UnleashedEnvironmentScanner.packageToolNames.contains($0.name) }
        let inventoryAvailability: CapabilityAvailability
        if let database = scan.packageDatabase {
            inventoryAvailability = .availableUntested("The dpkg status database \(database) is readable; the inventory is read from it without running apt.")
        } else if let query = packageTools.first(where: { ($0.name == "dpkg-query" || $0.name == "dpkg") && $0.state == .executable }) {
            inventoryAvailability = .availableUntested("\(query.path) passed access(X_OK); listing needs a working local shell launch.")
        } else if let denied = scan.packageDatabaseProbes.first(where: \.showsDenial) {
            inventoryAvailability = .permissionDenied("Reading \(denied.path) was refused (\(PathProbe.errnoName(denied.errorCode ?? EPERM))), and dpkg cannot be run.")
        } else if !scan.packageDatabaseProbes.isEmpty, scan.packageDatabaseProbes.allSatisfy(\.showsAbsence), !visibleRoots.isEmpty {
            inventoryAvailability = .toolMissing("No dpkg status database at \(scan.packageDatabaseProbes.map(\.path).joined(separator: ", ")) and no runnable dpkg.")
        } else {
            inventoryAvailability = notFound("dpkg", candidates: packageTools)
        }
        results.append(CapabilityResult(
            kind: .packageManager, availability: inventoryAvailability,
            summary: "List installed packages (read-only).",
            evidence: scan.packageDatabaseProbes.map(record) + packageTools.filter { $0.state != .missing }.map(candidateEvidence),
            scope: scan.packageDatabase.map { [$0] } ?? []
        ))

        let apt = packageTools.first { ($0.name == "apt" || $0.name == "apt-get") && $0.state.exists }
        let changesAvailability: CapabilityAvailability
        if !shellAvailability.isUsable {
            changesAvailability = .permissionDenied("Package changes run apt in a visible local shell, and the local shell is not available: \(shellAvailability.label.lowercased()).")
        } else if let apt, apt.state == .executable {
            changesAvailability = .availableUntested("\(apt.path) passed access(X_OK). Each change needs your approval and runs visibly.")
        } else {
            changesAvailability = notFound("apt", candidates: packageTools.filter { $0.name == "apt" || $0.name == "apt-get" })
        }
        results.append(CapabilityResult(kind: .packageChanges, availability: changesAvailability, summary: "Install, remove or refresh packages after your approval, in a visible shell.", evidence: apt.map { [candidateEvidence($0)] } ?? [], requiresAuthorization: true))

        // Processes -------------------------------------------------------------------
        let processAvailability: CapabilityAvailability = switch scan.visibleProcessCount {
        case .some(let count) where count > 1: .verified("The process table returned \(count) processes.")
        case .some: .permissionDenied("The system shows this app only its own process.")
        case nil: .permissionDenied("sysctl(KERN_PROC_ALL) was refused.")
        }
        results.append(CapabilityResult(kind: .processInspection, availability: processAvailability, summary: "List running processes (read-only).", evidence: scan.evidence.filter { $0.probe.hasPrefix("sysctl") }))

        // Privileged operations ---------------------------------------------------------
        let elevation = scan.toolCandidates.filter { UnleashedEnvironmentScanner.elevationToolNames.contains($0.name) }
        let privilegedAvailability: CapabilityAvailability
        if scan.effectiveUserID == 0 {
            privilegedAvailability = .availableUntested("This app process runs as root (euid 0).")
        } else if !shellAvailability.isUsable {
            privilegedAvailability = .permissionDenied("Privileged commands run in a local shell, and the local shell is not available: \(shellAvailability.label.lowercased()). This app runs as uid \(scan.effectiveUserID).")
        } else if let tool = elevation.first(where: { $0.state == .executable }) {
            privilegedAvailability = .availableUntested("\(tool.path) passed access(X_OK). It asks for its own password, which HCG Terminal never supplies or stores.")
        } else {
            privilegedAvailability = notFound("sudo or su", candidates: elevation)
        }
        results.append(CapabilityResult(
            kind: .privilegedOperations, availability: privilegedAvailability,
            summary: "Run privileged commands only after you approve each one; HCG Terminal never elevates by itself.",
            evidence: scan.evidence.filter { $0.probe == "geteuid()" } + elevation.filter { $0.state != .missing }.map(candidateEvidence),
            requiresAuthorization: true
        ))

        results.append(SharedCapabilities.remoteSSH())
        results.append(SharedCapabilities.buildOrchestration())

        let sessionPossible = shellAvailability.isUsable || loopbackAvailability.isUsable
        var notes = ["Unleashed build: backend linked. \(scan.operatingSystem)", "Checked \(time.formatted(date: .omitted, time: .standard)); results from tests keep their own times."]
        if !deniedRoots.isEmpty || !scan.deniedPaths.isEmpty {
            notes.append("The system refused this app access to \(Set(scan.deniedPaths).sorted().prefix(8).joined(separator: ", ")).")
        }
        let report = CapabilityReport(
            mode: .unleashed,
            generatedAt: time,
            results: results,
            localFeaturesAvailable: sessionPossible,
            headline: sessionPossible
                ? "Unleashed: local terminal \(shellAvailability.isUsable ? shellAvailability.label.lowercased() : "through the localhost SSH service"). Nothing is installed or elevated automatically."
                : CapabilityReport.unleashedUnavailableMessage,
            buildNotes: notes
        )
        return report
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
