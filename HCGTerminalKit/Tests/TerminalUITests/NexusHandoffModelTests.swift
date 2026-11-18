import DeveloperWorkspace
import FileWorkspace
import Foundation
import TerminalCore
import TerminalSecurity
@testable import TerminalUI
import XCTest

/// How the app model routes HCG Nexus handoff links (docs/NEXUS-HANDOFF.md). Nothing here may
/// connect, run a command or start a session.
@MainActor
final class NexusHandoffModelTests: XCTestCase {
    var root: URL!
    var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-handoff-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "hcg-handoff-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func makeModel(_ distribution: DistributionBuild = .standard) throws -> TerminalAppModel {
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        var deps = AppDependencies.standard(
            workspace: workspace, supportDirectory: root.appendingPathComponent("support"),
            credentials: InMemoryCredentialStore(), preferences: ModePreferenceStore(defaults: defaults),
            access: .inMemory(), appearance: AppearanceStore(defaults: defaults)
        )
        deps.distribution = distribution
        return TerminalAppModel(dependencies: deps)
    }

    private func savedHost(in model: TerminalAppModel) async -> HostProfile {
        let host = HostProfile(name: "Build Mac", hostname: "mac.local", username: "qq-user", auth: .password)
        await model.saveHost(host, password: nil)
        return host
    }

    private func assertNothingStarted(_ model: TerminalAppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.sessions.isEmpty, "a handoff link started a session", file: file, line: line)
        XCTAssertNil(model.selectedSessionID, file: file, line: line)
        XCTAssertNil(model.errorMessage, file: file, line: line)
        for host in model.hosts { XCTAssertFalse(model.isConnected(host), "a handoff link connected", file: file, line: line) }
    }

    func testVariantFollowsTheBuild() async throws {
        XCTAssertEqual(try makeModel(.standard).handoffVariant, .standard)
        XCTAssertEqual(try makeModel(.unleashed).handoffVariant, .unleashed)
    }

    func testOpenDoesNothingElse() async throws {
        let model = try makeModel()
        _ = await savedHost(in: model)
        await model.handleOpenURL(URL(string: "hcgterminal://open")!)
        XCTAssertNil(model.handoffConnection)
        XCTAssertNil(model.handoffNotice)
        assertNothingStarted(model)
    }

    func testConnectionShowsTheSavedHostWithoutConnecting() async throws {
        let model = try makeModel()
        let host = await savedHost(in: model)
        await model.handleOpenURL(URL(string: model.nexusLink(for: host))!)
        XCTAssertEqual(model.handoffConnection?.id, host.id)
        XCTAssertNil(model.handoffNotice)
        assertNothingStarted(model)
    }

    func testConnectionFindsHostsBeforeBootstrapLoadsThem() async throws {
        let model = try makeModel()
        let host = HostProfile(name: "Saved earlier", hostname: "mac.local", username: "ana", auth: .password)
        try await model.dependencies.hostStore.save(host)
        XCTAssertTrue(model.hosts.isEmpty)
        await model.handleOpenURL(URL(string: "hcgterminal://connection?id=\(host.id.uuidString)")!)
        XCTAssertEqual(model.handoffConnection?.id, host.id)
        assertNothingStarted(model)
    }

    func testUnknownConnectionShowsNonBlockingNotice() async throws {
        let model = try makeModel()
        _ = await savedHost(in: model)
        await model.handleOpenURL(URL(string: "hcgterminal://connection?id=\(UUID().uuidString)")!)
        XCTAssertNil(model.handoffConnection)
        XCTAssertEqual(model.handoffNotice?.message, "This saved connection isn't on this device.")
        assertNothingStarted(model)
    }

    func testRefusedLinksChangeNothingButTheNotice() async throws {
        let model = try makeModel()
        let host = await savedHost(in: model)
        for link in [
            "hcgterminal://connection?id=\(host.id.uuidString)&command=ls",
            "hcgterminal://connection?id=\(host.id.uuidString)&cmd=rm",
            "hcgterminal://open?run=whoami",
            "hcgterminal-unleashed://connection?id=\(host.id.uuidString)",
            "hcgterminal://connection?id=\(host.id.uuidString)#x",
            "hcgterminal://session?id=\(host.id.uuidString)",
            "hcgterminal://connection?id=nope",
        ] {
            model.handoffNotice = nil
            await model.handleOpenURL(URL(string: link)!)
            XCTAssertNil(model.handoffConnection, link)
            let message = try XCTUnwrap(model.handoffNotice?.message, link)
            XCTAssertTrue(message.hasPrefix("Link ignored."), message)
            XCTAssertTrue(message.hasSuffix("Nothing was run."), message)
            assertNothingStarted(model)
        }
    }

    func testUnleashedBuildAcceptsOnlyItsOwnScheme() async throws {
        let model = try makeModel(.unleashed)
        let host = await savedHost(in: model)
        let link = model.nexusLink(for: host)
        XCTAssertEqual(link, "hcgterminal-unleashed://connection?id=\(host.id.uuidString)")
        await model.handleOpenURL(URL(string: "hcgterminal://connection?id=\(host.id.uuidString)")!)
        XCTAssertNil(model.handoffConnection)
        XCTAssertNotNil(model.handoffNotice)
        model.handoffNotice = nil
        await model.handleOpenURL(URL(string: link)!)
        XCTAssertEqual(model.handoffConnection?.id, host.id)
        assertNothingStarted(model)
    }

    func testCopiedLinkHasNoHostDetails() async throws {
        let model = try makeModel()
        let host = await savedHost(in: model)
        let link = model.nexusLink(for: host)
        XCTAssertEqual(link, "hcgterminal://connection?id=\(host.id.uuidString)")
        for detail in [host.name, host.hostname, host.username] { XCTAssertFalse(link.contains(detail), detail) }
    }
}
