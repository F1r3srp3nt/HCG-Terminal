import Foundation
import TerminalCapabilityProvider
import TerminalCore
import TerminalSecurity
@testable import UnleashedExecutionProvider
import XCTest

/// Detailed probe records for the scripted environment: symlinks, files whose access(X_OK) the
/// sandbox refuses, and unreadable files.
struct DetailedProbe: SystemProbing {
    var base: ScriptedProbe
    /// Files that exist but whose access(X_OK) returns EPERM (sandboxed app on a jailbroken device).
    var execDenied: Set<String> = []
    /// Symlink → target that does not exist.
    var brokenLinks: [String: String] = [:]
    /// Symlink → existing target.
    var links: [String: String] = [:]
    /// Files that exist but cannot be opened (EPERM).
    var unreadable: Set<String> = []

    private func denied(_ path: String) -> Bool { base.isDenied(path) }
    private func fileExists(_ path: String) -> Bool { base.exists(path) || execDenied.contains(path) || unreadable.contains(path) || links[path] != nil }

    func probe(_ path: String) -> PathProbe {
        if denied(path) { return .denied(EPERM) }
        return fileExists(path) || brokenLinks[path] != nil ? .present : .missing
    }
    func listing(_ path: String) -> Result<[String], PathProbeFailure> { base.listing(path) }
    func exists(_ path: String) -> Bool { fileExists(path) }
    func isDirectory(_ path: String) -> Bool { base.isDirectory(path) }
    func isReadable(_ path: String) -> Bool { base.isReadable(path) && !unreadable.contains(path) }
    func isWritable(_ path: String) -> Bool { base.isWritable(path) }
    func isExecutableFile(_ path: String) -> Bool { base.isExecutableFile(path) }
    func listDirectory(_ path: String) -> [String]? { base.listDirectory(path) }
    func effectiveUserID() -> UInt32 { base.euid }
    func loopbackPortAccepts(_ port: Int, timeout: TimeInterval) -> Bool { base.ports.contains(port) }
    func visibleProcessCount() -> Int? { base.processCount }
    func osDescription() -> String { "Darwin 23.4.0 iPhone12,5 · Version 17.4 (Build 21E217)" }

    private func type(_ path: String) -> String {
        if base.isDirectory(path) { return ProbedFileType.directory + ", mode 755" }
        if base.executables.contains(path) || execDenied.contains(path) { return ProbedFileType.regular + ", mode 755" }
        return ProbedFileType.regular + ", mode 644"
    }

    func lstatRecord(_ path: String) -> ProbeRecord {
        if denied(path) { return ProbeRecord(operation: "lstat", path: path, returnValue: -1, errorCode: EPERM) }
        if brokenLinks[path] != nil || links[path] != nil { return ProbeRecord(operation: "lstat", path: path, returnValue: 0, detail: ProbedFileType.symlink) }
        guard fileExists(path) else { return ProbeRecord(operation: "lstat", path: path, returnValue: -1, errorCode: ENOENT) }
        return ProbeRecord(operation: "lstat", path: path, returnValue: 0, detail: type(path))
    }
    func statRecord(_ path: String) -> ProbeRecord {
        if denied(path) { return ProbeRecord(operation: "stat", path: path, returnValue: -1, errorCode: EPERM) }
        if brokenLinks[path] != nil { return ProbeRecord(operation: "stat", path: path, returnValue: -1, errorCode: ENOENT) }
        let target = links[path] ?? path
        guard fileExists(target) else { return ProbeRecord(operation: "stat", path: path, returnValue: -1, errorCode: ENOENT) }
        return ProbeRecord(operation: "stat", path: path, returnValue: 0, detail: type(target))
    }
    func readlinkRecord(_ path: String) -> ProbeRecord {
        if let target = brokenLinks[path] ?? links[path] { return ProbeRecord(operation: "readlink", path: path, returnValue: Int32(target.utf8.count), detail: target) }
        return ProbeRecord(operation: "readlink", path: path, returnValue: -1, errorCode: EINVAL)
    }
    func realpathRecord(_ path: String) -> ProbeRecord {
        if denied(path) { return ProbeRecord(operation: "realpath", path: path, returnValue: -1, errorCode: EPERM) }
        if brokenLinks[path] != nil { return ProbeRecord(operation: "realpath", path: path, returnValue: -1, errorCode: ENOENT) }
        if let target = links[path] { return ProbeRecord(operation: "realpath", path: path, returnValue: 0, detail: target) }
        if let resolved = base.resolved[path] { return ProbeRecord(operation: "realpath", path: path, returnValue: 0, detail: resolved) }
        return fileExists(path) ? ProbeRecord(operation: "realpath", path: path, returnValue: 0, detail: path) : ProbeRecord(operation: "realpath", path: path, returnValue: -1, errorCode: ENOENT)
    }
    func accessRecord(_ path: String, mode: Int32) -> ProbeRecord {
        let op = mode == X_OK ? "access(X_OK)" : mode == W_OK ? "access(W_OK)" : "access(R_OK)"
        if denied(path) || (mode == X_OK && execDenied.contains(path)) { return ProbeRecord(operation: op, path: path, returnValue: -1, errorCode: EPERM) }
        let target = links[path] ?? path
        let ok = mode == X_OK ? base.executables.contains(target) : mode == W_OK ? base.isWritable(target) : isReadable(target)
        if ok { return ProbeRecord(operation: op, path: path, returnValue: 0) }
        return ProbeRecord(operation: op, path: path, returnValue: -1, errorCode: fileExists(target) ? EACCES : ENOENT)
    }
    func readRecord(_ path: String) -> ProbeRecord {
        if denied(path) || unreadable.contains(path) { return ProbeRecord(operation: "open(O_RDONLY)", path: path, returnValue: -1, errorCode: EPERM) }
        return base.isReadable(path) ? ProbeRecord(operation: "open(O_RDONLY)+read", path: path, returnValue: 1) : ProbeRecord(operation: "open(O_RDONLY)", path: path, returnValue: -1, errorCode: ENOENT)
    }

    /// The sandboxed iPhone 11 Pro Max (iOS 17.4) from the device screenshots: Dopamine-style
    /// markers under /var/jb, /var/jb listable, system program folders refused, shells present
    /// but access(X_OK) refused, nothing on localhost, process table refused.
    static let sandboxedJailbrokenPhone: DetailedProbe = {
        let jb = "/var/jb"
        var base = ScriptedProbe(
            directories: [jb, "\(jb)/etc", "\(jb)/var/log", "\(jb)/bin", "\(jb)/usr/bin", "\(jb)/etc/apt/sources.list.d", "\(jb)/Applications/Sileo.app", "\(jb)/Applications/Zebra.app"],
            executables: [],
            readable: [jb, "\(jb)/.procursus_strapped", "\(jb)/.installed_dopamine", "\(jb)/var/lib/dpkg/status", "\(jb)/etc/hosts", "\(jb)/etc", "\(jb)/var/log"],
            writable: [],
            listings: [
                jb: [".procursus_strapped", ".installed_dopamine", "bin", "usr", "etc", "var", "Applications"],
                "\(jb)/etc": ["hosts", "apt"], "\(jb)/var/log": [],
                "\(jb)/bin": ["sh", "bash"], "\(jb)/usr/bin": ["zsh", "apt", "dpkg", "dpkg-query", "sudo"],
            ],
            euid: 501, ports: [], processCount: nil,
            denied: ["/bin", "/usr/bin", "/sbin", "/usr/sbin", "/var/mobile", "/var/log", "/private/var/tmp", "/tmp", "/etc", "/Applications", "/var/containers", "/private/preboot"]
        )
        base.resolved = [:]
        return DetailedProbe(base: base, execDenied: ["\(jb)/bin/sh", "\(jb)/bin/bash", "\(jb)/usr/bin/zsh", "\(jb)/usr/bin/apt", "\(jb)/usr/bin/dpkg", "\(jb)/usr/bin/dpkg-query", "\(jb)/usr/bin/sudo"])
    }()
}

final class UnleashedDiagnosticsTests: XCTestCase {
    private func report(_ probe: some SystemProbing, observations: RuntimeObservations = RuntimeObservations(), resolver: String? = nil) async -> (UnleashedEnvironmentScan, CapabilityReport) {
        let scan = UnleashedEnvironmentScanner(probe: probe, prefixResolver: { resolver }).scan()
        return (scan, await UnleashedCapabilityProvider.report(for: scan, observations: observations))
    }

    func testSandboxedJailbrokenPhoneIsPartialAndDeniedIsNeverMissing() async {
        let (scan, report) = await report(DetailedProbe.sandboxedJailbrokenPhone)

        // Shell: files exist, X_OK refused → permission denied with every path shown.
        guard case .permissionDenied(let shellReason) = report[.localShell].availability else { return XCTFail("\(report[.localShell].availability)") }
        XCTAssertTrue(shellReason.contains("/var/jb/bin/sh"), shellReason)
        XCTAssertTrue(shellReason.contains("does not mean a shell is missing"), shellReason)
        XCTAssertFalse(shellReason.lowercased().contains("reinstall the"), "no advice to reinstall tools for a denial")
        XCTAssertEqual(scan.shellCandidates.count, 16, "every attempted path is recorded: 2 roots × 2 folders × 4 shells")
        XCTAssertTrue(report[.localShell].evidence.contains { $0.probe.hasPrefix("/var/jb/bin/sh") && $0.errorCode == EPERM })
        XCTAssertEqual(scan.launchableShells.first, "/var/jb/bin/bash", "preferred interactive shell first (zsh, bash, sh, dash)")
        XCTAssertTrue(scan.launchableShells.contains("/var/jb/bin/sh"), "refused X_OK files are still offered for an explicit launch test")

        // Programs: listing /usr/bin refused → denied, not missing.
        guard case .permissionDenied(let programs) = report[.executableAccess].availability else { return XCTFail("\(report[.executableAccess].availability)") }
        XCTAssertTrue(programs.contains("/usr/bin"), programs)
        XCTAssertTrue(programs.contains("does not mean the programs are missing"))

        // Filesystem: listing verified but partial; reading separate; writing refused, not verified.
        guard case .verified = report[.filesystemPermissions].availability else { return XCTFail() }
        XCTAssertTrue(report[.filesystemPermissions].partial)
        XCTAssertEqual(report[.filesystemPermissions].statusLabel, "Verified working · partial")
        XCTAssertTrue(report[.filesystemPermissions].scope.contains("/var/jb"))
        XCTAssertTrue(report[.fileReading].availability.isUsable)
        guard case .permissionDenied = report[.fileWriting].availability else { return XCTFail("\(report[.fileWriting].availability)") }

        // Packages: inventory from the status database, changes blocked by the shell.
        guard case .availableUntested(let inventory) = report[.packageManager].availability else { return XCTFail("\(report[.packageManager].availability)") }
        XCTAssertTrue(inventory.contains("/var/jb/var/lib/dpkg/status"))
        guard case .permissionDenied = report[.packageChanges].availability else { return XCTFail() }

        // Localhost SSH: connection refused on both ports is evidence nothing listens there.
        guard case .toolMissing = report[.localhostSSH].availability else { return XCTFail("\(report[.localhostSSH].availability)") }
        guard case .permissionDenied = report[.processInspection].availability else { return XCTFail() }
        guard case .permissionDenied = report[.privilegedOperations].availability else { return XCTFail() }

        // Overall: partial, naming what works and what blocks the rest.
        XCTAssertFalse(report.localFeaturesAvailable)
        XCTAssertEqual(report.level, .partial)
        XCTAssertTrue(report.bannerText.hasPrefix("Unleashed partially available."), report.bannerText)
        XCTAssertTrue(report.bannerText.contains("Directory listing (partial)"))
        XCTAssertTrue(report.bannerText.contains("local shell: permission denied"))

        // Markers are indicators only.
        XCTAssertTrue(scan.indicators.contains { $0.path == "/var/jb/.installed_dopamine" && $0.probe == .present })
    }

    func testNoDoubleNegativesAnywhere() async {
        for probe in [DetailedProbe.sandboxedJailbrokenPhone, DetailedProbe(base: .stockDevice), DetailedProbe(base: .rootlessDevice)] {
            let (_, report) = await report(probe)
            for result in report.results {
                let text = result.availability.reason
                XCTAssertNil(text.range(of: #"\bNo [^.]* (was|were) not found"#, options: .regularExpression), "\(result.kind): \(text)")
                XCTAssertFalse(text.contains("No directory with executables"), text)
            }
        }
    }

    func testDeniedVersusMissingVersusBrokenSymlink() {
        let resolver = ToolResolver(probe: DetailedProbe(
            base: ScriptedProbe(executables: ["/opt/bin/ok"], denied: ["/secret"]),
            execDenied: ["/opt/bin/locked"], brokenLinks: ["/opt/bin/dangling": "/opt/gone/sh"], links: ["/opt/bin/link": "/opt/bin/ok"]
        ))
        XCTAssertEqual(resolver.resolve("/nope/sh", name: "sh").state, .missing)
        XCTAssertEqual(resolver.resolve("/secret/sh", name: "sh").state, .denied(operation: "lstat", errno: EPERM))
        XCTAssertFalse(resolver.resolve("/secret/sh", name: "sh").state.launchCandidate, "not known to exist")
        XCTAssertEqual(resolver.resolve("/opt/bin/locked", name: "locked").state, .denied(operation: "access(X_OK)", errno: EPERM))
        XCTAssertTrue(resolver.resolve("/opt/bin/locked", name: "locked").state.launchCandidate, "exists: worth an explicit launch")
        XCTAssertEqual(resolver.resolve("/opt/bin/dangling", name: "sh").state, .brokenSymlink(target: "/opt/gone/sh"))
        let link = resolver.resolve("/opt/bin/link", name: "link")
        XCTAssertEqual(link.state, .executable)
        XCTAssertEqual(link.resolvedPath, "/opt/bin/ok")
        XCTAssertEqual(link.probes.map(\.operation), ["lstat", "readlink", "realpath", "stat", "access(X_OK)"], "each step recorded")
        XCTAssertTrue(link.probes.allSatisfy { $0.timestamp.timeIntervalSinceNow < 1 })
    }

    func testBrokenShellSymlinkIsReportedAsSuch() async {
        let probe = DetailedProbe(base: ScriptedProbe(directories: ["/var/jb", "/var/jb/bin"], readable: ["/var/jb"]), brokenLinks: ["/var/jb/bin/sh": "/var/jb/bin/dash"])
        let (_, report) = await report(probe)
        guard case .toolMissing(let reason) = report[.localShell].availability else { return XCTFail("\(report[.localShell].availability)") }
        XCTAssertTrue(reason.contains("symlink to /var/jb/bin/dash"), reason)
    }

    func testFailedLaunchDespiteXOKIsNotVerified() async {
        let observations = RuntimeObservations()
        await observations.record(executable: "/var/jb/bin/sh", outcome: .failed(errno: EPERM, message: "Operation not permitted"))
        let (_, report) = await report(DetailedProbe(base: .rootlessDevice), observations: observations)
        guard case .permissionDenied(let reason) = report[.localShell].availability else { return XCTFail("\(report[.localShell].availability)") }
        XCTAssertTrue(reason.contains("Launching /var/jb/bin/sh was refused"), reason)
        XCTAssertFalse(report.localFeaturesAvailable)
        XCTAssertEqual(report.level, .partial, "listing and the inventory still work: one failure does not disable them")
    }

    func testSuccessfulShellLaunchIsTheOnlyWayToVerified() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        var scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice, prefixResolver: { nil }).scan()
        scan.pretendShell("/bin/sh")
        let observations = RuntimeObservations()
        let before = await UnleashedCapabilityProvider.report(for: scan, observations: observations)
        guard case .availableUntested = before[.localShell].availability else { return XCTFail("X_OK alone is not verified") }

        let operations = UnleashedOperations(scan: scan, observations: observations, gate: AuthorizationGate(access: .inMemory()), access: .inMemory())
        let test = await operations.verifyShell()
        XCTAssertTrue(test.succeeded, test.outcome)
        XCTAssertTrue(test.outcome.contains("exited with status 0"), test.outcome)
        let after = await UnleashedCapabilityProvider.report(for: scan, observations: observations)
        guard case .verified = after[.localShell].availability else { return XCTFail("\(after[.localShell].availability)") }
        XCTAssertTrue(after.localFeaturesAvailable)
    }

    func testShellTestTriesFilesWhoseXOKWasRefused() async {
        var scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice, prefixResolver: { nil }).scan()
        scan.shellCandidates = [ToolCandidate(name: "sh", path: "/nonexistent-for-test/sh", resolvedPath: nil, state: .denied(operation: "access(X_OK)", errno: EPERM), probes: [])]
        let observations = RuntimeObservations()
        let operations = UnleashedOperations(scan: scan, observations: observations, gate: AuthorizationGate(access: .inMemory()), access: .inMemory())
        let test = await operations.verifyShell()
        XCTAssertFalse(test.succeeded)
        let recorded = await observations.outcome(for: "/nonexistent-for-test/sh")
        XCTAssertNotNil(recorded, "a launch was attempted and its real result recorded")
    }

    func testStaleResultsDoNotCount() async {
        let observations = RuntimeObservations()
        await observations.record(executable: "/var/jb/bin/sh", outcome: .succeeded(pid: 42), at: Date(timeIntervalSinceNow: -3600))
        // The shell has since disappeared.
        let (_, report) = await report(DetailedProbe(base: ScriptedProbe(directories: ["/var/jb"], readable: ["/var/jb"])), observations: observations)
        XCTAssertFalse(report[.localShell].availability.isUsable)
        XCTAssertTrue(report[.localShell].evidence.contains { $0.observation.contains("no longer applies") })
        await observations.reset()
        let fresh = await observations.allObservations()
        XCTAssertTrue(fresh.isEmpty, "Recheck clears earlier results")
    }

    func testResolverPrefixAddsRelocatedRoot() {
        let root = "/private/preboot/UUID/jb-abc/procursus"
        let probe = DetailedProbe(base: ScriptedProbe(directories: [root, root + "/bin"], executables: [root + "/bin/sh"]))
        let scan = UnleashedEnvironmentScanner(probe: probe, prefixResolver: { root }).scan()
        XCTAssertEqual(scan.resolverPrefix, root)
        XCTAssertTrue(scan.roots.contains { $0.path == root && $0.layout == .relocated })
        XCTAssertEqual(scan.shells, [root + "/bin/sh"])
    }

    func testLocalhostSSHNeedsSignInNotJustAnOpenPort() async {
        let observations = RuntimeObservations()
        let (_, open) = await report(DetailedProbe(base: ScriptedProbe(ports: [2222])), observations: observations)
        guard case .availableUntested = open[.localhostSSH].availability else { return XCTFail() }
        await observations.recordLoopbackSignIn("mobile@127.0.0.1:2222")
        let (_, signedIn) = await report(DetailedProbe(base: ScriptedProbe(ports: [2222])), observations: observations)
        guard case .verified = signedIn[.localhostSSH].availability else { return XCTFail() }
    }

    func testDpkgStatusInventory() {
        let status = """
        Package: zsh
        Status: install ok installed
        Version: 5.9-1
        Description: shell
         continued line

        Package: removed-thing
        Status: deinstall ok config-files
        Version: 1.0

        Status: install ok installed
        Version: 2

        Package: apt
        Status: install ok installed
        Version: 2.7.14

        """
        let inventory = DpkgStatusParser.parse(status, source: "/var/jb/var/lib/dpkg/status")
        XCTAssertEqual(inventory.packages.map(\.name), ["apt", "zsh"])
        XCTAssertEqual(inventory.packages.first?.version, "2.7.14")
        XCTAssertEqual(inventory.skippedEntries, 1, "the stanza without a Package field is counted, not guessed")
        XCTAssertFalse(inventory.complete)
        XCTAssertTrue(DpkgStatusParser.parse("Package: a\nStatus: install ok installed\nVersion: 1\n", source: "x").complete)
        XCTAssertFalse(DpkgStatusParser.parse("Package: a\nStatus: install ok installed\nVersion: 1", source: "x").complete, "truncated")
    }

    func testMasterSwitchAndLocalhostSwitchAreEnforced() async throws {
        let access = AccessPolicy.inMemory()
        access.set(.localhostSSH, enabled: false)
        XCTAssertThrowsError(try access.require(.localhostSSH))
        XCTAssertNoThrow(try access.require(.localShell), "independent of the localhost switch")
        XCTAssertNoThrow(try access.require(.remoteSSH), "remote SSH is controlled separately")
        access.set(.localhostSSH, enabled: true)
        access.set(.unleashedFeatures, enabled: false)
        for control in [AccessControl.localShell, .localhostSSH, .expandedFileRead, .expandedFileWrite, .packageManagement] {
            XCTAssertFalse(access.isEnabled(control), control.rawValue)
        }
        XCTAssertTrue(access.isEnabled(.remoteSSH))
        XCTAssertTrue(access.isEnabled(.workspaceCommands))
    }
}
