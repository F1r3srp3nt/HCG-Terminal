import Crypto
import Foundation
@testable import RemoteSSH
import TerminalCore
import TerminalSecurity
import XCTest

/// SFTP against a real OpenSSH server (`Scripts/start-test-sshd.sh`, `HCG_SSH_TEST=1`).
final class SFTPIntegrationTests: XCTestCase {
    let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest")
    var local: URL!
    var remoteFolder: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1 with Scripts/start-test-sshd.sh running")
        local = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        remoteFolder = "/home/hcgtest/sftp test \(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        if let local { try? FileManager.default.removeItem(at: local) }
    }

    func connect(access: AccessPolicy = AccessPolicy.inMemory()) async throws -> SSHConnection {
        let policy = HostKeyPolicy(knownHosts: KnownHostsStore(fileURL: nil)) { _, _, _ in true }
        return try await SSHConnection.connect(endpoint: endpoint, authentication: .password("hcg-test-pass"), hostKeyPolicy: policy, access: access)
    }

    func randomFile(_ name: String, bytes: Int) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let url = local.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func sha256(_ url: URL) throws -> String {
        Data(SHA256.hash(data: try Data(contentsOf: url))).base64EncodedString()
    }

    func testRoundTripListRenameAndRemove() async throws {
        let connection = try await connect()
        let sftp = try await SFTPClient.open(on: connection)
        let home = try await sftp.realpath(".")
        XCTAssertEqual(home, "/home/hcgtest")
        try await sftp.makeDirectory(remoteFolder)

        // 1 MiB + odd bytes: many pipelined chunks and a short last one.
        let source = try randomFile("payload.bin", bytes: 1_048_576 + 12_345)
        let remote = SFTPClient.join(remoteFolder, "payload copy.bin")
        let progress = ProgressLog()
        let sent = try await sftp.upload(source, to: remote, replace: false) { done, total in progress.add(done, total) }
        XCTAssertEqual(sent, 1_048_576 + 12_345)
        XCTAssertEqual(progress.last?.0, sent)

        let listing = try await sftp.list(remoteFolder)
        XCTAssertEqual(listing.map(\.name), ["payload copy.bin"], "no temporary upload file is left behind")
        XCTAssertEqual(listing.first?.size, sent)

        let downloaded = local.appendingPathComponent("back.bin")
        let received = try await sftp.download(remote, to: downloaded)
        XCTAssertEqual(received, sent)
        XCTAssertEqual(try sha256(downloaded), try sha256(source), "byte-identical round trip")

        // Existing files are not replaced unless asked.
        do {
            try await sftp.upload(try randomFile("other.bin", bytes: 10), to: remote, replace: false)
            XCTFail("must refuse to replace")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .alreadyExists(remote))
        }
        try await sftp.upload(local.appendingPathComponent("other.bin"), to: remote, replace: true)
        let replacedSize = try await sftp.stat(remote).size
        XCTAssertEqual(replacedSize, 10)

        let renamed = SFTPClient.join(remoteFolder, "renamed.bin")
        try await sftp.rename(remote, to: renamed, replace: false)
        try await sftp.remove(renamed, isDirectory: false)
        let afterRemove = try await sftp.list(remoteFolder)
        XCTAssertTrue(afterRemove.isEmpty)
        try await sftp.remove(remoteFolder, isDirectory: true)
        await sftp.close()
        await connection.close()
    }

    func testEmptyFileAndErrors() async throws {
        let connection = try await connect()
        let sftp = try await SFTPClient.open(on: connection)
        try await sftp.makeDirectory(remoteFolder)
        let empty = try randomFile("empty", bytes: 0)
        let remote = SFTPClient.join(remoteFolder, "empty")
        let uploaded = try await sftp.upload(empty, to: remote, replace: false)
        let downloaded = try await sftp.download(remote, to: local.appendingPathComponent("empty-back"))
        XCTAssertEqual(uploaded, 0)
        XCTAssertEqual(downloaded, 0)

        do { _ = try await sftp.list("/root"); XCTFail("root's home is not readable") } catch let error as SFTPError {
            XCTAssertEqual(error, .permissionDenied("/root"))
        }
        do { _ = try await sftp.stat("/no/such/path"); XCTFail("missing") } catch let error as SFTPError {
            XCTAssertEqual(error, .noSuchFile("/no/such/path"))
        }
        let target = local.appendingPathComponent("never")
        do { try await sftp.download("/no/such/file", to: target); XCTFail("missing") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try await sftp.remove(remote, isDirectory: false)
        try await sftp.remove(remoteFolder, isDirectory: true)
        await sftp.close()
        await connection.close()
    }

    func testCancelledDownloadLeavesNothing() async throws {
        let connection = try await connect()
        let sftp = try await SFTPClient.open(on: connection)
        try await sftp.makeDirectory(remoteFolder)
        let remote = SFTPClient.join(remoteFolder, "big.bin")
        try await sftp.upload(try randomFile("big.bin", bytes: 24 * 1_048_576), to: remote, replace: false)

        let destinationFolder = local.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let started = ProgressLog()
        let task = Task { try await sftp.download(remote, to: destinationFolder.appendingPathComponent("big.bin")) { done, total in started.add(done, total) } }
        while started.last == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("should be cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationFolder.path), [], "no partial file is left")

        try await sftp.remove(remote, isDirectory: false)
        try await sftp.remove(remoteFolder, isDirectory: true)
        await sftp.close()
        await connection.close()
    }

    func testTurningSSHOffStopsTransfers() async throws {
        let access = AccessPolicy.inMemory()
        let connection = try await connect(access: access)
        let sftp = try await SFTPClient.open(on: connection)
        access.set(.remoteSSH, enabled: false)
        do { _ = try await sftp.list("."); XCTFail("must be refused") } catch let denied as AccessDenied {
            XCTAssertEqual(denied.control, .remoteSSH)
        }
        await sftp.close()
        await connection.close()
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(UInt64, UInt64?)] = []
    func add(_ done: UInt64, _ total: UInt64?) { lock.lock(); values.append((done, total)); lock.unlock() }
    var last: (UInt64, UInt64?)? { lock.lock(); defer { lock.unlock() }; return values.last }
}
