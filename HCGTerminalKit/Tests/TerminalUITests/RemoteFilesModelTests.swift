import DeveloperWorkspace
import FileWorkspace
import Foundation
import RemoteSSH
import TerminalCore
import TerminalSecurity
@testable import TerminalUI
import XCTest

@MainActor
final class RemoteFilesModelTests: XCTestCase {
    func testUniqueNamesNeverOverwrite() async {
        XCTAssertEqual(RemoteFilesModel.uniqueName("a.txt", existing: []), "a.txt")
        XCTAssertEqual(RemoteFilesModel.uniqueName("a.txt", existing: ["a.txt"]), "a 2.txt")
        XCTAssertEqual(RemoteFilesModel.uniqueName("a.txt", existing: ["a.txt", "a 2.txt"]), "a 3.txt")
        XCTAssertEqual(RemoteFilesModel.uniqueName("Makefile", existing: ["Makefile"]), "Makefile 2")
        XCTAssertEqual(RemoteFilesModel.safeName("Build/Mac"), "Build-Mac")
        XCTAssertEqual(RemoteFilesModel.safeName(".."), "host")
        XCTAssertNil(RemoteFilesModel.validName("a/b"))
        XCTAssertNil(RemoteFilesModel.validName(" .. "))
        XCTAssertEqual(RemoteFilesModel.validName(" New Folder "), "New Folder")
    }

    /// The whole flow against a real OpenSSH server (`Scripts/start-test-sshd.sh`,
    /// `HCG_SSH_TEST=1`): connect with the host's saved password and trusted key, browse, make a
    /// folder, upload a workspace file, download it back into workspace/downloads/<host>.
    func testBrowseUploadAndDownloadThroughTheAppModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1 with Scripts/start-test-sshd.sh running")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-remote-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "hcg-rf-\(UUID().uuidString)"))
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        let credentials = InMemoryCredentialStore()
        let deps = AppDependencies.standard(
            workspace: workspace, supportDirectory: root.appendingPathComponent("support"),
            credentials: credentials, preferences: ModePreferenceStore(defaults: defaults),
            access: .inMemory(), appearance: AppearanceStore(defaults: defaults)
        )
        let app = TerminalAppModel(dependencies: deps)
        let host = HostProfile(name: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest", auth: .password)
        try credentials.save(Data("hcg-test-pass".utf8), for: .hostPassword(host.id))
        let line = try String(contentsOfFile: "/tmp/hcg-test-sshd/host_ed25519.pub", encoding: .utf8)
        try await deps.knownHosts.trust(host: "127.0.0.1", port: 2222, key: try XCTUnwrap(PresentedHostKey(openSSHLine: line)))

        let files = RemoteFilesModel(host: host, app: app)
        await files.start()
        XCTAssertNil(files.errorMessage)
        XCTAssertEqual(files.path, "/home/hcgtest")

        let folder = "hcg files \(UUID().uuidString.prefix(6))"
        await files.makeFolder(named: folder)
        XCTAssertTrue(files.exists(folder))
        await files.open(SFTPClient.join(files.path, folder))
        XCTAssertTrue(files.entries.isEmpty)

        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try workspace.write(payload, to: WorkspacePath.home.appending("notes.bin"))
        let upload = try XCTUnwrap(files.upload(WorkspacePath.home.appending("notes.bin"), replace: false))
        await upload.task?.value
        XCTAssertEqual(upload.state, .finished("Uploaded to \(files.path)/notes.bin"))
        XCTAssertEqual(upload.done, 200_000)
        XCTAssertEqual(files.entries.map(\.name), ["notes.bin"])

        // Two downloads of the same file: the second gets a new name, nothing is overwritten.
        for expected in ["notes.bin", "notes 2.bin"] {
            let download = try XCTUnwrap(files.download(files.entries[0]))
            await download.task?.value
            XCTAssertEqual(download.state, .finished("Saved to /downloads/Test sshd/\(expected)"))
            XCTAssertEqual(try workspace.readData(files.downloadFolder.appending(expected)), payload)
        }

        for entry in files.entries { await files.delete(entry) }
        await files.goUp()
        if let made = files.entries.first(where: { $0.name == folder }) { await files.delete(made) }
        XCTAssertFalse(files.exists(folder))
        await files.stop()
    }
}
