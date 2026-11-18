import Foundation
import TerminalCore
import XCTest

/// The HCG Nexus handoff contract, version 1 (docs/NEXUS-HANDOFF.md).
final class NexusHandoffTests: XCTestCase {
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    let idString = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    private func parse(_ string: String, _ variant: NexusHandoff.Variant = .standard) -> Result<NexusHandoff.Route, NexusHandoff.Refusal> {
        NexusHandoff.parse(string, variant: variant)
    }

    private func assertRefused(_ string: String, _ variant: NexusHandoff.Variant = .standard, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let route) = parse(string, variant) {
            XCTFail("accepted \(string) as \(route)", file: file, line: line)
        }
    }

    private func assertRefused(_ string: String, _ variant: NexusHandoff.Variant = .standard, as expected: NexusHandoff.Refusal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parse(string, variant), .failure(expected), string, file: file, line: line)
    }

    // MARK: Contract constants

    func testContractConstants() {
        XCTAssertEqual(NexusHandoff.contractVersion, 1)
        XCTAssertEqual(NexusHandoff.infoPlistKey, "HCGNexusHandoff")
        XCTAssertEqual(NexusHandoff.urlTypeName, "com.hakmicapitalgroup.hcgterminal.nexus-handoff")
        XCTAssertEqual(NexusHandoff.maxURLLength, 256)
        XCTAssertEqual(NexusHandoff.Variant.standard.scheme, "hcgterminal")
        XCTAssertEqual(NexusHandoff.Variant.unleashed.scheme, "hcgterminal-unleashed")
        XCTAssertEqual(NexusHandoff.Variant(rawValue: "standard"), .standard)
        XCTAssertEqual(NexusHandoff.Variant(rawValue: "unleashed"), .unleashed)
    }

    // MARK: Accepted

    func testOpenRouteBothSchemes() {
        XCTAssertEqual(parse("hcgterminal://open", .standard), .success(.open))
        XCTAssertEqual(parse("hcgterminal-unleashed://open", .unleashed), .success(.open))
        XCTAssertEqual(parse(NexusHandoff.openLink(variant: .standard), .standard), .success(.open))
        XCTAssertEqual(parse(NexusHandoff.openLink(variant: .unleashed), .unleashed), .success(.open))
    }

    func testConnectionRouteBothSchemes() {
        XCTAssertEqual(parse("hcgterminal://connection?id=\(idString)", .standard), .success(.connection(id)))
        XCTAssertEqual(parse("hcgterminal-unleashed://connection?id=\(idString)", .unleashed), .success(.connection(id)))
        XCTAssertEqual(parse("hcgterminal://connection?id=\(idString.lowercased())", .standard), .success(.connection(id)))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(parse("HCGTerminal://Open", .standard), .success(.open))
        XCTAssertEqual(parse("HCGTERMINAL-UNLEASHED://CONNECTION?id=\(idString)", .unleashed), .success(.connection(id)))
    }

    func testURLOverloadMatchesString() {
        let url = URL(string: "hcgterminal://connection?id=\(idString)")!
        XCTAssertEqual(NexusHandoff.parse(url, variant: .standard), .success(.connection(id)))
        XCTAssertEqual(NexusHandoff.parse(URL(string: "hcgterminal://open")!, variant: .standard), .success(.open))
    }

    // MARK: Copy link

    func testCopyLinkRoundTripsThroughParserForBothVariants() {
        for variant in NexusHandoff.Variant.allCases {
            for _ in 0..<20 {
                let id = UUID()
                let link = NexusHandoff.connectionLink(id: id, variant: variant)
                XCTAssertEqual(NexusHandoff.parse(link, variant: variant), .success(.connection(id)), link)
                XCTAssertLessThanOrEqual(link.utf8.count, NexusHandoff.maxURLLength)
                // Never accepted by the other variant.
                let other: NexusHandoff.Variant = variant == .standard ? .unleashed : .standard
                XCTAssertEqual(NexusHandoff.parse(link, variant: other), .failure(.wrongScheme(variant.scheme)))
            }
        }
    }

    func testCopyLinkContainsOnlyTheID() {
        let link = NexusHandoff.connectionLink(id: id, variant: .standard)
        XCTAssertEqual(link, "hcgterminal://connection?id=\(idString)")
        XCTAssertEqual(NexusHandoff.connectionLink(id: id, variant: .unleashed), "hcgterminal-unleashed://connection?id=\(idString)")
    }

    // MARK: Variant mismatch and wrong scheme

    func testEachBuildAcceptsOnlyItsOwnScheme() {
        assertRefused("hcgterminal-unleashed://open", .standard, as: .wrongScheme("hcgterminal-unleashed"))
        assertRefused("hcgterminal://open", .unleashed, as: .wrongScheme("hcgterminal"))
        assertRefused("hcgterminal-unleashed://connection?id=\(idString)", .standard, as: .wrongScheme("hcgterminal-unleashed"))
        assertRefused("hcgterminal://connection?id=\(idString)", .unleashed, as: .wrongScheme("hcgterminal"))
    }

    func testOtherSchemesAreRefused() {
        assertRefused("https://open", as: .wrongScheme("https"))
        assertRefused("https://example.com/connection?id=\(idString)", as: .wrongScheme("https"))
        assertRefused("ssh://open", as: .wrongScheme("ssh"))
        assertRefused("hcgnexus://open", as: .wrongScheme("hcgnexus"))
        assertRefused("hcgterminalx://open", as: .wrongScheme("hcgterminalx"))
        assertRefused("open")
        assertRefused("//open")
    }

    // MARK: Routes and URL components

    func testOtherHostsAreRefused() {
        assertRefused("hcgterminal://")
        assertRefused("hcgterminal://session", as: .unknownRoute("session"))
        assertRefused("hcgterminal://connect?id=\(idString)", as: .unknownRoute("connect"))
        assertRefused("hcgterminal://run", as: .unknownRoute("run"))
        assertRefused("hcgterminal://shell?id=\(idString)", as: .unknownRoute("shell"))
        assertRefused("hcgterminal://example.com", as: .unknownRoute("example.com"))
        assertRefused("hcgterminal://op%65n")
    }

    func testNonAuthorityFormsAreRefused() {
        assertRefused("hcgterminal:open")
        assertRefused("hcgterminal:connection?id=\(idString)")
        assertRefused("hcgterminal:///open")
    }

    func testPathsAreRefused() {
        assertRefused("hcgterminal://open/", as: .unexpectedComponent("path"))
        assertRefused("hcgterminal://open/now", as: .unexpectedComponent("path"))
        assertRefused("hcgterminal://connection/\(idString)", as: .unexpectedComponent("path"))
        assertRefused("hcgterminal://connection/?id=\(idString)", as: .unexpectedComponent("path"))
    }

    func testFragmentsAreRefused() {
        assertRefused("hcgterminal://open#x", as: .unexpectedComponent("fragment"))
        assertRefused("hcgterminal://open#", as: .unexpectedComponent("fragment"))
        assertRefused("hcgterminal://connection?id=\(idString)#ls", as: .unexpectedComponent("fragment"))
    }

    func testUserInfoAndPortsAreRefused() {
        assertRefused("hcgterminal://user@open", as: .unexpectedComponent("user name or password"))
        assertRefused("hcgterminal://user:pw@open", as: .unexpectedComponent("user name or password"))
        assertRefused("hcgterminal://@open")
        assertRefused("hcgterminal://root@connection?id=\(idString)", as: .unexpectedComponent("user name or password"))
        assertRefused("hcgterminal://open:22", as: .unexpectedComponent("port"))
        assertRefused("hcgterminal://open:")
        assertRefused("hcgterminal://connection:8080?id=\(idString)", as: .unexpectedComponent("port"))
    }

    // MARK: Query items

    func testOpenTakesNoParameters() {
        assertRefused("hcgterminal://open?")
        assertRefused("hcgterminal://open?id=\(idString)", as: .unexpectedParameter("id"))
        assertRefused("hcgterminal://open?x=1", as: .unexpectedParameter("x"))
    }

    func testCommandLikeParametersAreRefusedOnEveryRoute() {
        for name in ["command", "cmd", "run", "exec", "script", "input", "COMMAND", "Cmd"] {
            assertRefused("hcgterminal://open?\(name)=ls", as: .commandParameter(name))
            assertRefused("hcgterminal://connection?id=\(idString)&\(name)=ls", as: .commandParameter(name))
            assertRefused("hcgterminal://connection?\(name)=ls&id=\(idString)", as: .commandParameter(name))
            assertRefused("hcgterminal://connection?\(name)", as: .commandParameter(name))
            assertRefused("hcgterminal-unleashed://connection?id=\(idString)&\(name)=whoami", .unleashed, as: .commandParameter(name))
            assertRefused("hcgterminal://session?\(name)=ls", as: .commandParameter(name))
        }
        // Percent-encoded names are recognised too.
        assertRefused("hcgterminal://connection?id=\(idString)&c%6Fmmand=ls", as: .commandParameter("command"))
    }

    func testExtraParametersAreRefused() {
        assertRefused("hcgterminal://connection?id=\(idString)&host=mac.local", as: .unexpectedParameter("host"))
        assertRefused("hcgterminal://connection?user=root&id=\(idString)", as: .unexpectedParameter("user"))
        assertRefused("hcgterminal://connection?id=\(idString)&connect=1", as: .unexpectedParameter("connect"))
        assertRefused("hcgterminal://connection?id=\(idString)&")
        assertRefused("hcgterminal://connection?ID=\(idString)", as: .unexpectedParameter("ID"))
        assertRefused("hcgterminal://connection?uuid=\(idString)", as: .unexpectedParameter("uuid"))
    }

    func testMissingAndDuplicateIDs() {
        assertRefused("hcgterminal://connection", as: .missingID)
        assertRefused("hcgterminal://connection?")
        assertRefused("hcgterminal://connection?id", as: .missingID)
        assertRefused("hcgterminal://connection?id=", as: .missingID)
        assertRefused("hcgterminal://connection?id=\(idString)&id=\(idString)", as: .duplicateID)
        assertRefused("hcgterminal://connection?id=\(idString)&id=\(UUID().uuidString)", as: .duplicateID)
    }

    func testInvalidIDsAreRefused() {
        for value in [
            "not-a-uuid",
            "1234",
            String(idString.dropLast()),
            idString + "0",
            idString.replacingOccurrences(of: "-", with: ""),
            "6F9619FF-8B86-D011-B42D-00C04FC964FG",
            "6F9619FF%2D8B86-D011-B42D-00C04FC964FF",
            "%36F9619FF-8B86-D011-B42D-00C04FC964FF",
            "6F9619FF-8B86-D011-B42D-00C04FC964FF;ls",
            "6F9619FF-8B86-D011-B42D-00C0-4FC964FF",
        ] {
            assertRefused("hcgterminal://connection?id=\(value)", as: .invalidID)
        }
        // Characters a strict URL parser rejects outright are refused either way.
        assertRefused("hcgterminal://connection?id={\(idString)}")
    }

    // MARK: Malformed and length

    func testMalformedInputIsRefused() {
        assertRefused("", as: .malformed)
        assertRefused("hcgterminal://open ", as: .malformed)
        assertRefused("hcgterminal://connection?id=\(idString) ls", as: .malformed)
        assertRefused("hcgterminal://open\n", as: .malformed)
        assertRefused("hcgterminal://öpen", as: .malformed)
    }

    func testLengthLimit() {
        // Exactly 256 bytes is allowed by length; it is then refused for its parameter.
        let base = "hcgterminal://connection?id=\(idString)&p="
        let at256 = base + String(repeating: "a", count: 256 - base.utf8.count)
        XCTAssertEqual(at256.utf8.count, 256)
        assertRefused(at256, as: .unexpectedParameter("p"))
        let at257 = at256 + "a"
        assertRefused(at257, as: .tooLong(257))
        assertRefused("hcgterminal://open?" + String(repeating: "x", count: 1000), as: .tooLong(1019))
        // Length is checked before anything else, including the scheme.
        assertRefused("https://" + String(repeating: "x", count: 300), as: .tooLong(308))
    }

    func testRefusalMessagesAreUserFacingAndBounded() {
        let refusals: [NexusHandoff.Refusal] = [
            .tooLong(300), .malformed, .wrongScheme("https"), .wrongScheme(nil), .unexpectedComponent("fragment"),
            .unknownRoute("x"), .unknownRoute(nil), .commandParameter("command"), .unexpectedParameter("x"),
            .missingID, .duplicateID, .invalidID,
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty)
            XCTAssertLessThan(refusal.message.count, 120)
        }
        XCTAssertTrue(NexusHandoff.Refusal.commandParameter("command").message.contains("never run commands"))
        XCTAssertLessThan(NexusHandoff.Refusal.unexpectedParameter(String(repeating: "y", count: 200)).message.count, 120)
    }
}
