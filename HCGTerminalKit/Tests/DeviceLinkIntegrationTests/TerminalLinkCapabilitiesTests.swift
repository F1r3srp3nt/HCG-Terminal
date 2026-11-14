@testable import DeviceLinkIntegration
import Foundation
import HCGDeviceLink
import TerminalCapabilityProvider
import TerminalCore
import XCTest

/// Reports as the providers produce them, with chosen availabilities.
enum ReportFixtures {
    static let observed = Date(timeIntervalSince1970: 1_800_000_000)

    static func vanilla(shell: CapabilityAvailability = .verified("Runs inside the app; no external process is needed.")) -> CapabilityReport {
        CapabilityReport(mode: .vanilla, results: [CapabilityResult(kind: .localShell, availability: shell, summary: "Built-in commands")],
                         localFeaturesAvailable: true, headline: "Vanilla")
    }

    static func unleashed(_ availability: CapabilityAvailability, mode: ExecutionMode = .unleashed) -> CapabilityReport {
        let evidence = [CapabilityEvidence(probe: "posix_spawn(/var/jb/bin/sh)", observation: "exit 0", positive: true, timestamp: observed)]
        let kinds: [CapabilityKind] = [.localShell, .executableAccess, .filesystemPermissions, .fileReading, .fileWriting, .privilegedOperations]
        return CapabilityReport(
            mode: mode, generatedAt: observed.addingTimeInterval(60),
            results: kinds.map { CapabilityResult(kind: $0, availability: availability, summary: $0.title, evidence: evidence) },
            localFeaturesAvailable: availability.isUsable, headline: "Unleashed"
        )
    }

    static func allSwitchesOn() -> AccessPolicy { AccessPolicy.allEnabled() }
}

final class TerminalLinkCapabilitiesTests: XCTestCase {
    private func advertised(_ variant: TerminalLinkVariant, _ reports: [ExecutionMode: CapabilityReport], access: AccessPolicy = .allEnabled()) -> [String: LinkCapability] {
        Dictionary(uniqueKeysWithValues: TerminalLinkCapabilities.advertised(distribution: variant, reports: reports, access: access).map { ($0.id, $0) })
    }

    func testReportCapabilitiesAreAlwaysAvailable() {
        for variant in TerminalLinkVariant.allCases {
            let caps = advertised(variant, [:], access: .inMemory())
            XCTAssertEqual(caps[LinkCapabilityID.reportReceive]?.state, .available)
            XCTAssertEqual(caps[LinkCapabilityID.reportView]?.state, .available)
            XCTAssertNil(caps[LinkCapabilityID.reportSend], "Terminal does not send reports in this milestone")
        }
    }

    func testVanillaBuildAdvertisesWorkspaceAndSSHButNoUnleashedCapability() {
        let caps = advertised(.vanilla, [.vanilla: ReportFixtures.vanilla()], access: .inMemory())
        XCTAssertEqual(caps[LinkCapabilityID.terminalWorkspace]?.state, .available)
        XCTAssertEqual(caps[LinkCapabilityID.terminalRemoteSSH]?.state, .available)
        for id in [LinkCapabilityID.terminalLocalShell, LinkCapabilityID.terminalExpandedFiles, LinkCapabilityID.terminalPrivileged] {
            XCTAssertEqual(caps[id]?.state, .unavailable, id)
            XCTAssertEqual(caps[id]?.reason, "Vanilla build", id)
        }
    }

    func testVanillaNeverAdvertisesUnleashedCapabilitiesEvenIfReportsClaimVerified() {
        let claim = ReportFixtures.unleashed(.verified("claimed"))
        let caps = advertised(.vanilla, [.vanilla: ReportFixtures.vanilla(), .unleashed: claim], access: .allEnabled())
        for id in [LinkCapabilityID.terminalLocalShell, LinkCapabilityID.terminalExpandedFiles, LinkCapabilityID.terminalPrivileged] {
            XCTAssertEqual(caps[id]?.state, .unavailable, id)
            XCTAssertFalse(caps[id]!.state.isUsable, id)
            XCTAssertNil(caps[id]?.verifiedAt, id)
        }
    }

    func testUnleashedBuildWithHelperUnavailableAdvertisesPrivilegedAsUnavailable() {
        // No report at all (helper not reachable).
        var caps = advertised(.unleashed, [.vanilla: ReportFixtures.vanilla()])
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.state, .unavailable)
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.reason, "Unleashed helper not available")
        // The backend reports itself as not included.
        caps = advertised(.unleashed, [.unleashed: ReportFixtures.unleashed(.notIncluded("not linked"))])
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.state, .unavailable)
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.reason, "Unleashed helper not available")
        // Found but refused by the system: the reason says so.
        caps = advertised(.unleashed, [.unleashed: ReportFixtures.unleashed(.permissionDenied("listing /var/jb was refused (EPERM)"))])
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.state, .unavailable)
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.reason, "Permission denied: listing /var/jb was refused (EPERM)")
    }

    func testUnleashedCapabilityThatIsOnlyDetectedIsNotAdvertisedAsVerified() {
        let caps = advertised(.unleashed, [.unleashed: ReportFixtures.unleashed(.availableUntested("sh passed access(X_OK)"))])
        XCTAssertEqual(caps[LinkCapabilityID.terminalLocalShell]?.state, .unavailable)
        XCTAssertEqual(caps[LinkCapabilityID.terminalLocalShell]?.reason, "Not verified on this device yet")
    }

    func testUnleashedVerifiedResultsAreAdvertisedAsVerifiedWithTimeAndShortEvidence() {
        let caps = advertised(.unleashed, [.unleashed: ReportFixtures.unleashed(.verified("/var/jb/bin/sh was launched at 10:02 (pid 812) and completed."))])
        for id in [LinkCapabilityID.terminalLocalShell, LinkCapabilityID.terminalExpandedFiles, LinkCapabilityID.terminalPrivileged] {
            XCTAssertEqual(caps[id]?.state, .verified, id)
            XCTAssertEqual(caps[id]?.verifiedAt, ReportFixtures.observed, id)
            let evidence = caps[id]?.evidence ?? ""
            XCTAssertFalse(evidence.isEmpty, id)
            XCTAssertFalse(evidence.contains("/var/jb"), "evidence is a fixed description, not local paths")
            XCTAssertLessThanOrEqual(evidence.count, TerminalLinkCapabilities.maxTextLength)
        }
    }

    func testSwitchesOnlyRestrict() {
        // Privileged operations are off by default: a verified result is still advertised as disabled.
        let caps = advertised(.unleashed, [.unleashed: ReportFixtures.unleashed(.verified("ok"))], access: .inMemory())
        XCTAssertEqual(caps[LinkCapabilityID.terminalLocalShell]?.state, .verified)
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.state, .disabled)

        let access = AccessPolicy.allEnabled()
        access.set(.unleashedFeatures, enabled: false)
        access.set(.workspaceCommands, enabled: false)
        access.set(.remoteSSH, enabled: false)
        let off = advertised(.unleashed, [.vanilla: ReportFixtures.vanilla(), .unleashed: ReportFixtures.unleashed(.verified("ok"))], access: access)
        XCTAssertEqual(off[LinkCapabilityID.terminalLocalShell]?.state, .disabled)
        XCTAssertEqual(off[LinkCapabilityID.terminalExpandedFiles]?.state, .disabled)
        XCTAssertEqual(off[LinkCapabilityID.terminalWorkspace]?.state, .disabled)
        XCTAssertEqual(off[LinkCapabilityID.terminalRemoteSSH]?.state, .disabled)
    }

    func testWorkspaceUnavailableWhenTheVanillaReportSaysSo() {
        let caps = advertised(.vanilla, [.vanilla: ReportFixtures.vanilla(shell: .permissionDenied("The app workspace is not accessible."))])
        XCTAssertEqual(caps[LinkCapabilityID.terminalWorkspace]?.state, .unavailable)
        XCTAssertEqual(caps[LinkCapabilityID.terminalWorkspace]?.reason, "Permission denied: The app workspace is not accessible.")
    }

    func testAReportForAnotherModeIsNotUsedAsUnleashedEvidence() {
        let mislabelled = ReportFixtures.unleashed(.verified("ok"), mode: .vanilla)
        let caps = advertised(.unleashed, [.unleashed: mislabelled])
        XCTAssertEqual(caps[LinkCapabilityID.terminalLocalShell]?.state, .unavailable)
        XCTAssertEqual(caps[LinkCapabilityID.terminalLocalShell]?.reason, "Unleashed helper not available")
    }

    func testLongReasonsAreShortened() {
        let caps = advertised(.unleashed, [.unleashed: ReportFixtures.unleashed(.toolMissing(String(repeating: "x", count: 500)))])
        XCTAssertEqual(caps[LinkCapabilityID.terminalPrivileged]?.reason?.count, TerminalLinkCapabilities.maxTextLength)
    }

    func testServerDataCannotChangeAdvertisedCapabilities() {
        // The advertisement is a function of the build, local reports and local switches only:
        // there is no parameter through which server data could reach it.
        let function: (TerminalLinkVariant, [ExecutionMode: CapabilityReport], AccessPolicy) -> [LinkCapability] = TerminalLinkCapabilities.advertised
        let reports: [ExecutionMode: CapabilityReport] = [.vanilla: ReportFixtures.vanilla(), .unleashed: ReportFixtures.unleashed(.availableUntested("found"))]
        let access = AccessPolicy.allEnabled()
        let first = function(.unleashed, reports, access)
        XCTAssertEqual(first, function(.unleashed, reports, access))
        XCTAssertFalse(first.contains { $0.id == LinkCapabilityID.terminalPrivileged && $0.state.isUsable })
    }

    func testAppNames() {
        XCTAssertEqual(LinkAppNames.display("hcg.sentinel"), "HCG Sentinel")
        XCTAssertEqual(LinkAppNames.display("hcg.terminal"), "HCG Terminal")
        XCTAssertEqual(LinkAppNames.display("something.else"), "something.else")
        XCTAssertEqual(LinkAppNames.variant("unleashed"), "Unleashed")
        XCTAssertNil(LinkAppNames.variant(nil))
        XCTAssertEqual(LinkCapabilityNames.title(LinkCapabilityID.terminalPrivileged), "Privileged operations")
        XCTAssertEqual(LinkCapabilityNames.title("x.unknown"), "x.unknown")
        XCTAssertEqual(LinkCapabilityNames.state(.disabled), "Off")
        XCTAssertEqual(LinkPresenceText.label(.neverSeen), "Never seen")
    }
}
