import Foundation
@testable import TerminalUI
import XCTest

final class DeepLinkTests: XCTestCase {
    func testOnlyNavigationLinksAreAccepted() {
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal://open/dashboard")!), .open(.dashboard))
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal-unleashed://open/Tools")!), .open(.tools))
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "HCGTERMINAL-UNLEASHED://OPEN/console")!), .open(.console))
        // HCG Interchange routes HCG Nexus opens directly (declared in Info-Unleashed.plist).
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal-unleashed://open/jailbreak-diagnostics")!), .open(.jailbreakDiagnostics))
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal-unleashed://open/packages")!), .open(.packages))
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal-unleashed://open/processes")!), .open(.processes))
        for rejected in [
            "hcgterminal://run/ls",
            "hcgterminal://open/session?command=rm%20-rf",
            "hcgterminal://open/dashboard?x=1",
            "hcgterminal://open/tools/extra",
            "hcgterminal://open/",
            "https://open/dashboard",
            "hcgsentinel://open/dashboard",
            "hcgterminal://open/nonexistent",
            "hcgterminal-unleashed://open/jailbreakDiagnostics",
            "hcgterminal-unleashed://open/processes?kill=1",
            "hcgterminal-unleashed://open/packages/install",
        ] {
            XCTAssertNil(TerminalDeepLink(url: URL(string: rejected)!), rejected)
        }
    }

    func testEcosystemNeverClaimsUnbuiltIntegrations() {
        let items = HCGEcosystem.integrations(isUnleashed: true)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.product, $0) })
        XCTAssertEqual(byName["HCG Connect"]?.state, .notYetAvailable)
        XCTAssertEqual(byName["HCG Store licensing"]?.state, .notYetAvailable)
        XCTAssertEqual(byName["HCG Agent Runtime"]?.state, .notYetAvailable)
        XCTAssertEqual(byName["HCG Server"]?.state, .notYetAvailable)
        XCTAssertEqual(byName["HCG Repo"]?.state, .available)
        XCTAssertEqual(HCGEcosystem.integrations(isUnleashed: false).first { $0.product == "HCG Repo" }?.state, .notYetAvailable)
    }

    func testNexusOpenRequestsAreFixedNamesOnly() {
        XCTAssertEqual(HCGNexusLink.openProduct("terminal-unleashed"), "com.hakmicapitalgroup.hcgnexus/open/product/terminal-unleashed")
        XCTAssertFalse(HCGNexusLink.post("com.example.other"), "only Nexus open requests are posted")
        XCTAssertTrue(HCGNexusLink.supportsOpenRequests(nexusVersion: "0.4.0"))
        XCTAssertTrue(HCGNexusLink.supportsOpenRequests(nexusVersion: "0.10.0"))
        XCTAssertFalse(HCGNexusLink.supportsOpenRequests(nexusVersion: "0.3.3"))
        XCTAssertFalse(HCGNexusLink.supportsOpenRequests(nexusVersion: nil))

        func nexus(_ version: String?, unleashed: Bool = true) -> HCGEcosystem.Integration? {
            HCGEcosystem.integrations(isUnleashed: unleashed, nexusVersion: version).first { $0.product == "HCG Nexus" }
        }
        XCTAssertEqual(nexus("0.4.0")?.nexusRequest, "com.hakmicapitalgroup.hcgnexus/open/product/terminal-unleashed")
        XCTAssertNil(nexus("0.3.3")?.nexusRequest, "older Nexus does not listen")
        XCTAssertTrue(nexus("0.3.3")?.detail.contains("0.4.0~beta1") ?? false)
        XCTAssertNil(nexus(nil)?.nexusRequest, "not installed")
        XCTAssertNil(nexus("0.4.0", unleashed: false)?.nexusRequest, "standard edition is sandboxed and does not offer it")
        XCTAssertTrue(nexus("0.4.0")?.detail.contains("jailbreak-diagnostics") ?? false)
        XCTAssertNil(HCGNexusLink.installedNexusVersion(jailbreakRoot: "/nonexistent-root"))
    }
}
