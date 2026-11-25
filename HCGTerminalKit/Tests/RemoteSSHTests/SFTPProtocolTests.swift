import Foundation
@testable import RemoteSSH
import XCTest

/// SFTP v3 encoding and decoding, without a server.
final class SFTPProtocolTests: XCTestCase {
    func testRequestsAreFramedAsTheDraftSays() {
        // INIT: length 5, type 1, version 3.
        XCTAssertEqual(SFTP.initialize(), [0, 0, 0, 5, 1, 0, 0, 0, 3])
        // OPEN id 7 "a" flags READ, empty attributes.
        XCTAssertEqual(SFTP.open(id: 7, path: "a", flags: .read), [0, 0, 0, 18, 3, 0, 0, 0, 7, 0, 0, 0, 1, 0x61, 0, 0, 0, 1, 0, 0, 0, 0])
        // READ id 2, handle [9], offset 2^32 + 1, length 32768.
        XCTAssertEqual(SFTP.read(id: 2, handle: [9], offset: (1 << 32) + 1, length: 32768),
                       [0, 0, 0, 22, 5, 0, 0, 0, 2, 0, 0, 0, 1, 9, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0x80, 0])
        XCTAssertEqual(Array(SFTP.posixRename(id: 1, from: "a", to: "b").prefix(9)), [0, 0, 0, 43, 200, 0, 0, 0, 1])
    }

    func testDecodesNameReplyWithAttributes() throws {
        var payload: [UInt8] = [104] + SFTPBytes.uint32(5) + SFTPBytes.uint32(2)
        // "dir": size 4096, permissions drwxr-xr-x, times.
        payload += SFTPBytes.string("dir") + SFTPBytes.string("drwxr-xr-x 2 u g 4096 Jan 1 dir")
        payload += SFTPBytes.uint32(0x1 | 0x4 | 0x8) + SFTPBytes.uint64(4096) + SFTPBytes.uint32(0o040755) + SFTPBytes.uint32(1) + SFTPBytes.uint32(1_700_000_000)
        // "file.txt": size and uid/gid only, plus one extended pair.
        payload += SFTPBytes.string("file.txt") + SFTPBytes.string("-rw-r--r-- file.txt")
        payload += SFTPBytes.uint32(0x1 | 0x2 | 0x8000_0000) + SFTPBytes.uint64(12) + SFTPBytes.uint32(501) + SFTPBytes.uint32(20)
        payload += SFTPBytes.uint32(1) + SFTPBytes.string("k") + SFTPBytes.string("v")
        guard case .name(let id, let names) = try SFTP.Response.decode(payload) else { return XCTFail("not a name reply") }
        XCTAssertEqual(id, 5)
        XCTAssertEqual(names.map(\.filename), ["dir", "file.txt"])
        XCTAssertTrue(names[0].attributes.isDirectory)
        XCTAssertEqual(names[0].attributes.modified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(names[1].attributes.size, 12)
        XCTAssertEqual(names[1].attributes.uid, 501)
        XCTAssertNil(names[1].attributes.permissions)
    }

    func testStatusWithoutMessageAndVersionExtensions() throws {
        XCTAssertEqual(try SFTP.Response.decode([101] + SFTPBytes.uint32(3) + SFTPBytes.uint32(1)), .status(id: 3, code: 1, message: ""))
        let version = [2] + SFTPBytes.uint32(3) + SFTPBytes.string("posix-rename@openssh.com") + SFTPBytes.string("1")
        XCTAssertEqual(try SFTP.Response.decode(version), .version(3, extensions: ["posix-rename@openssh.com": "1"]))
        XCTAssertThrowsError(try SFTP.Response.decode([104, 0, 0]))
    }

    func testFramerHandlesSplitAndJoinedPackets() throws {
        var framer = SFTPFramer()
        let first = SFTP.packet(.status, SFTPBytes.uint32(1) + SFTPBytes.uint32(0))
        let second = SFTP.packet(.data, SFTPBytes.uint32(2) + SFTPBytes.string([1, 2, 3]))
        let stream = first + second
        framer.append(stream.prefix(3))
        XCTAssertNil(try framer.next())
        framer.append(stream.dropFirst(3).prefix(10))
        XCTAssertEqual(try framer.next(), Array(first.dropFirst(4)))
        XCTAssertNil(try framer.next())
        framer.append(stream.dropFirst(13))
        XCTAssertEqual(try framer.next(), Array(second.dropFirst(4)))
        var bad = SFTPFramer()
        bad.append([0xFF, 0xFF, 0xFF, 0xFF, 1])
        XCTAssertThrowsError(try bad.next(), "absurd lengths are refused")
    }

    func testStatusCodesBecomeReadableErrors() {
        XCTAssertEqual(SFTPError.from(code: 2, message: "No such file", path: "/x"), .noSuchFile("/x"))
        XCTAssertEqual(SFTPError.from(code: 3, message: "Permission denied", path: "/root"), .permissionDenied("/root"))
        XCTAssertEqual(SFTPError.from(code: 4, message: "Failure", path: "/x"), .failure("Failure"))
        XCTAssertTrue(SFTPError.sizeMismatch(expected: 10, actual: 3).errorDescription!.contains("Nothing was kept"))
    }

    func testEntryHelpers() {
        let entry = SFTPEntry(name: "a", path: "/tmp/a", size: 1, modified: nil, permissions: 0o100644, isDirectory: false, isSymbolicLink: false)
        XCTAssertEqual(entry.modeText, "-rw-r--r--")
        XCTAssertEqual(SFTPClient.join("/", "a"), "/a")
        XCTAssertEqual(SFTPClient.join("/home/u", "a b"), "/home/u/a b")
        XCTAssertEqual(SFTPClient.parent(of: "/home/u/f"), "/home/u")
        XCTAssertEqual(SFTPClient.parent(of: "/f"), "/")
    }
}
