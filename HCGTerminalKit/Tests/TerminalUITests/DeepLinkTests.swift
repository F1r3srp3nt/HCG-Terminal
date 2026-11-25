import Foundation
@testable import TerminalUI
import XCTest

final class DeepLinkTests: XCTestCase {
    func testOnlyNavigationLinksAreAccepted() {
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal://open/dashboard")!), .open(.dashboard))
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "hcgterminal-unleashed://open/Tools")!), .open(.tools))
        XCTAssertEqual(TerminalDeepLink(url: URL(string: "HCGTERMINAL-UNLEASHED://OPEN/console")!), .open(.console))
        for rejected in [
            "hcgterminal://run/ls",
            "hcgterminal://open/session?command=rm%20-rf",
            "hcgterminal://open/dashboard?x=1",
            "hcgterminal://open/tools/extra",
            "hcgterminal://open/",
            "https://open/dashboard",
            "hcgsentinel://open/dashboard",
            "hcgterminal://open/nonexistent",
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
        // Device Link pairing and the host view exist; remote actions and a remote shell do not.
        XCTAssertEqual(byName["HCG Server"]?.state, .partial)
        XCTAssertTrue(byName["HCG Server"]?.detail.contains("Remote actions stay disabled") == true)
        XCTAssertEqual(byName["HCG Repo"]?.state, .available)
        XCTAssertEqual(HCGEcosystem.integrations(isUnleashed: false).first { $0.product == "HCG Repo" }?.state, .notYetAvailable)
    }
}
