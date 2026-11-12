import Foundation
import TerminalCapabilityProvider
import TerminalCore
@testable import UnleashedExecutionProvider
import XCTest

/// Layered detection: rootless, relocated, custom and rootful roots; indicators kept separate
/// from whether a shell can run; sandbox restrictions reported as "not observable".
final class EnvironmentAssessmentTests: XCTestCase {
    let sandboxed = EnvironmentAssessment.Process(userID: 501, effectiveUserID: 501, groupID: 501, home: "/var/mobile/Containers/Data/Application/X", bundlePath: "/var/containers/Bundle/Application/Y/App.app", containerized: true, installRoute: .testFlight, deniedProbes: [])
    let unsandboxed = EnvironmentAssessment.Process(userID: 501, effectiveUserID: 501, groupID: 501, home: "/var/mobile", bundlePath: "/var/jb/Applications/App.app", containerized: false, installRoute: .unknown, deniedProbes: [])

    func testSandboxedStockLookingDeviceIsNotObservableNotNegative() {
        let scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice).scan()
        let verdict = EnvironmentAssessment.verdict(indicators: scan.indicators, process: sandboxed)
        guard case .notObservable(let reason) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertTrue(reason.contains("may or may not"))
        XCTAssertEqual(EnvironmentAssessment.verdict(indicators: scan.indicators, process: unsandboxed), .noneFound)
    }

    func testRootlessSymlinkToRelocatedRootIsResolvedOnce() {
        let real = "/private/preboot/ABC/dopamine-XYZ/procursus"
        var probe = ScriptedProbe(
            directories: ["/var/jb", real, "/private/preboot", "/private/preboot/ABC"],
            executables: [real + "/bin/sh", real + "/usr/bin/dpkg-query"],
            readable: [real + "/.procursus_strapped", real + "/var/lib/dpkg/status"],
            listings: ["/private/preboot": ["ABC"], "/private/preboot/ABC": ["dopamine-XYZ", "other"], real + "/usr/bin": ["dpkg-query"]]
        )
        probe.resolved = ["/var/jb": real, "/var/jb/bin/sh": real + "/bin/sh"]
        // /var/jb → the relocated root: the same files are visible through /var/jb.
        probe.executables.formUnion(["/var/jb/bin/sh", "/var/jb/usr/bin/dpkg-query"])
        probe.readable.formUnion(["/var/jb/.procursus_strapped", "/var/jb/var/lib/dpkg/status"])
        probe.listings["/var/jb/usr/bin"] = ["dpkg-query"]
        let scan = UnleashedEnvironmentScanner(probe: probe).scan()
        let rootless = scan.roots.first { $0.layout == .rootless }
        XCTAssertEqual(rootless?.resolvedPath, real)
        XCTAssertFalse(scan.roots.contains { $0.layout == .relocated }, "the same root is not counted twice")
        XCTAssertEqual(scan.shells.first, "/var/jb/bin/sh")
        XCTAssertEqual(scan.resolvedTools["sh"], real + "/bin/sh")
        guard case .found(let strong, _) = EnvironmentAssessment.verdict(indicators: scan.indicators, process: sandboxed) else { return XCTFail() }
        XCTAssertEqual(strong, 2)
    }

    func testRelocatedRootWithoutVarJbAndCustomRoot() {
        let real = "/private/preboot/ABC/jb-123/procursus"
        let probe = ScriptedProbe(
            directories: ["/private/preboot", "/private/preboot/ABC", real, "/opt/strap"],
            executables: [real + "/bin/bash", "/opt/strap/bin/sh"],
            readable: ["/opt/strap/.procursus_strapped"],
            listings: ["/private/preboot": ["ABC"], "/private/preboot/ABC": ["jb-123"]]
        )
        let scan = UnleashedEnvironmentScanner(probe: probe, customRoots: { ["/opt/strap/"] }).scan()
        XCTAssertTrue(scan.roots.contains { $0.layout == .relocated && $0.path == real })
        XCTAssertTrue(scan.roots.contains { $0.layout == .custom && $0.path == "/opt/strap" })
        XCTAssertTrue(scan.shells.contains(real + "/bin/bash"))
        XCTAssertTrue(scan.shells.contains("/opt/strap/bin/sh"))
        XCTAssertTrue(scan.indicators.contains { $0.layout == .custom && $0.probe == .present && $0.strength == .strong })
    }

    func testRootfulIndicatorsAndWeakAppBundleAlone() {
        let rootful = ScriptedProbe(executables: ["/bin/sh"], readable: ["/.bootstrapped", "/var/lib/dpkg/status"])
        let scan = UnleashedEnvironmentScanner(probe: rootful).scan()
        guard case .found(let strong, let weak) = EnvironmentAssessment.verdict(indicators: scan.indicators, process: unsandboxed) else { return XCTFail() }
        XCTAssertEqual(strong, 2)
        XCTAssertEqual(weak, 0)

        let appOnly = ScriptedProbe(directories: ["/Applications/Sileo.app"])
        let weakScan = UnleashedEnvironmentScanner(probe: appOnly).scan()
        XCTAssertEqual(EnvironmentAssessment.verdict(indicators: weakScan.indicators, process: unsandboxed), .found(strong: 0, weak: 1))
        XCTAssertTrue(weakScan.shells.isEmpty, "an app bundle does not make a shell available")
    }

    func testIndicatorsDoNotMakeTheShellUsable() async {
        let observations = RuntimeObservations()
        let scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.rootlessDevice).scan()
        await observations.record(executable: scan.shells[0], outcome: .failed(errno: EPERM, message: "Operation not permitted"))
        let report = await UnleashedCapabilityProvider.report(for: scan, observations: observations)
        guard case .permissionDenied = report[.localShell].availability else { return XCTFail("\(report[.localShell].availability)") }
        XCTAssertFalse(report.localFeaturesAvailable)
    }

    func testStockSandboxIsEnvironmentUnknown() async {
        let scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice).scan()
        let report = await UnleashedCapabilityProvider.report(for: scan, observations: RuntimeObservations())
        guard case .environmentUnknown(let reason) = report[.localShell].availability else { return XCTFail() }
        XCTAssertTrue(reason.contains("does not show whether the device is jailbroken"))
    }

    func testSwitchOverlayNeverUpgradesAndOnlyDisablesUsable() async {
        let scan = UnleashedEnvironmentScanner(probe: ScriptedProbe.rootlessDevice).scan()
        let report = await UnleashedCapabilityProvider.report(for: scan, observations: RuntimeObservations())
        let access = AccessPolicy.inMemory()
        access.set(.localShell, enabled: false)
        let applied = report.applying(access: access)
        guard case .disabledByUser = applied[.localShell].availability else { return XCTFail() }
        guard case .disabledByUser = applied[.packageManager].availability else { return XCTFail("prerequisite") }
        XCTAssertFalse(applied.localFeaturesAvailable)
        // Privileged operations are off by default but were available-untested: disabled, not green.
        guard case .disabledByUser = applied[.privilegedOperations].availability else { return XCTFail() }

        let stock = await UnleashedCapabilityProvider.report(for: UnleashedEnvironmentScanner(probe: ScriptedProbe.stockDevice).scan(), observations: RuntimeObservations())
        let allOn = stock.applying(access: .allEnabled())
        XCTAssertEqual(allOn[.localShell].availability, stock[.localShell].availability, "turning a switch on never makes anything available")
        XCTAssertFalse(allOn[.localShell].availability.isUsable)
    }
}
