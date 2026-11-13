import Foundation
import TerminalCore
import TerminalSecurity
@testable import UnleashedExecutionProvider
import XCTest

final class HostFileSystemTests: XCTestCase {
    var root: URL!
    var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-hostfs-\(UUID().uuidString)")
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-hostfs-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    func testWriteCreateRenameDeleteInsidePermittedRoot() async throws {
        let files = HostFileSystem(roots: [root.path], gate: nil, access: .allEnabled())
        let base = HostFileSystem.resolve(root.path)
        XCTAssertTrue(files.isWritable(base))
        let folder = try await files.createDirectory(named: "My Notes", in: base)
        try await files.writeText("line 1\n", to: folder + "/a b.txt")
        XCTAssertEqual(try files.readText(folder + "/a b.txt"), "line 1\n")
        XCTAssertEqual(try files.list(folder).map(\.name), ["a b.txt"])
        XCTAssertTrue(try files.list(folder)[0].writable)
        let renamed = try await files.rename(folder + "/a b.txt", to: "notes.txt")
        XCTAssertTrue(renamed.hasSuffix("/My Notes/notes.txt"))
        do { _ = try await files.createDirectory(named: "My Notes", in: base); XCTFail("exists") } catch {
            XCTAssertEqual(error as? LocationBrowserError, .alreadyExists("My Notes"))
        }
        try await files.delete(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testEscapesAreRefused() async throws {
        let files = HostFileSystem(roots: [root.path], gate: nil, access: .allEnabled())
        let base = HostFileSystem.resolve(root.path)
        XCTAssertThrowsError(try files.list(outside.path))
        XCTAssertThrowsError(try files.readText(base + "/../" + outside.lastPathComponent + "/secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: outside.path)
        XCTAssertThrowsError(try files.readText(base + "/link/secret.txt"), "symlink out of the root")
        do { try await files.writeText("x", to: base + "/link/new.txt"); XCTFail("must refuse") } catch {
            XCTAssertEqual(error as? LocationBrowserError, .notPermitted(base + "/link/new.txt"))
        }
        do { try await files.delete(base); XCTFail("must refuse deleting a root") } catch {}
        do { _ = try await files.rename(base + "/link", to: "renamed"); XCTFail("a link pointing outside is outside") } catch {
            XCTAssertEqual(error as? LocationBrowserError, .notPermitted(base + "/link"))
        }
        try await files.writeText("x", to: base + "/plain.txt")
        do { _ = try await files.rename(base + "/plain.txt", to: "../escaped"); XCTFail("invalid name") } catch {
            XCTAssertEqual(error as? LocationBrowserError, .invalidName("../escaped"))
        }
    }

    func testProtectedLocationsNeedApprovalEachTime() async throws {
        XCTAssertTrue(HostFileSystem.requiresApproval("/var/jb/etc/apt/sources.list"))
        XCTAssertTrue(HostFileSystem.requiresApproval("/usr/local/bin/tool"))
        XCTAssertFalse(HostFileSystem.requiresApproval("/var/mobile/Documents/notes.txt"))

        // A permitted root treated as protected, as /var/jb is on a device (no root needed).
        let protected = HostFileSystem.resolve(root.path)

        final class Answers: @unchecked Sendable { var asked: [String] = []; var answer = false }
        let answers = Answers()
        let gate = AuthorizationGate(presenter: { request in answers.asked.append(request.commandLine); return answers.answer }, access: .allEnabled())
        let files = HostFileSystem(roots: [protected], gate: gate, needsApproval: { $0.hasPrefix(protected) }, access: .allEnabled())
        do { try await files.writeText("x", to: protected + "/config"); XCTFail("declined must not write") } catch {
            XCTAssertEqual(error as? LocationBrowserError, .approvalDeclined(protected + "/config"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: protected + "/config"))
        answers.answer = true
        try await files.writeText("x", to: protected + "/config")
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected + "/config"))
        try await files.delete(protected + "/config")
        XCTAssertEqual(answers.asked.count, 3, "asked for every change, no standing permission")

        let ungated = HostFileSystem(roots: [protected], gate: nil, needsApproval: { $0.hasPrefix(protected) }, access: .allEnabled())
        do { try await ungated.writeText("x", to: protected + "/other"); XCTFail("no presenter means no approval") } catch {}
    }
    func testOversizedTextCannotBeOpenedForEditing() async throws {
        let files = HostFileSystem(roots: [root.path], gate: nil, access: .allEnabled())
        let path = root.appendingPathComponent("large.txt").path
        try Data(repeating: 65, count: 1025).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try files.readText(path, limit: 1024)) { error in
            guard case LocationBrowserError.tooLarge = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).count, 1025)
    }

    func testGuardedSaveRefusesExternalChangesAndDeletedFile() async throws {
        let files = HostFileSystem(roots: [root.path], gate: nil, access: .allEnabled())
        let path = root.appendingPathComponent("edit.txt").path
        try await files.writeText("original", to: path)
        try await files.writeText("external", to: path)
        do {
            try await files.writeText("my edit", to: path, expectedText: "original")
            XCTFail("Must preserve the external edit")
        } catch { XCTAssertEqual(error as? LocationBrowserError, .changedOnDisk(path)) }
        XCTAssertEqual(try files.readText(path), "external")
        try FileManager.default.removeItem(atPath: path)
        do {
            try await files.writeText("my edit", to: path, expectedText: "original")
            XCTFail("Must not recreate a deleted document")
        } catch { XCTAssertEqual(error as? LocationBrowserError, .changedOnDisk(path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testWriteSwitchRecheckedAfterApproval() async throws {
        let access = AccessPolicy.allEnabled()
        let gate = AuthorizationGate(presenter: { _ in
            access.set(.expandedFileWrite, enabled: false)
            return true
        }, access: access)
        let files = HostFileSystem(roots: [root.path], gate: gate, needsApproval: { _ in true }, access: access)
        let path = root.appendingPathComponent("revoked.txt").path
        do {
            try await files.writeText("must not write", to: path)
            XCTFail("Revocation must take effect after the approval wait")
        } catch { XCTAssertTrue(error is AccessDenied) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testLogRootsUnderDeviceRoot() {
        XCTAssertEqual(HostFileSystem(roots: ["/"], gate: nil, access: .allEnabled()).logRoots, HostFileSystem.logDirectories)
        XCTAssertEqual(HostFileSystem(roots: ["/var/jb"], gate: nil, access: .allEnabled()).logRoots, ["/var/jb/var/log"])
    }

    func testExplicitRootAllowsOSReadableDescendants() throws {
        let files = HostFileSystem(roots: ["/"], gate: nil, access: .allEnabled())
        XCTAssertEqual(try files.readText(outside.appendingPathComponent("secret.txt").path), "secret")
        let disabled = HostFileSystem(roots: ["/"], gate: nil, access: .inMemory(AccessSettings(values: [AccessControl.expandedFileRead.rawValue: false])))
        XCTAssertThrowsError(try disabled.list(root.path))
    }

}
