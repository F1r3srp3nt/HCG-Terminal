import Foundation

/// SFTP version 3 (draft-ietf-secsh-filexfer-02), the version OpenSSH speaks. Pure encoding and
/// decoding, independent of any channel, so it is unit-tested on its own.
public enum SFTP {
    enum PacketType: UInt8 {
        case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6, lstat = 7
        case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105
        case extended = 200
    }

    /// `SSH_FXF_*` open flags.
    public struct OpenFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let read = OpenFlags(rawValue: 0x01)
        public static let write = OpenFlags(rawValue: 0x02)
        public static let append = OpenFlags(rawValue: 0x04)
        public static let create = OpenFlags(rawValue: 0x08)
        public static let truncate = OpenFlags(rawValue: 0x10)
        public static let exclusive = OpenFlags(rawValue: 0x20)
    }

    /// `SSH_FX_*` status codes.
    public enum StatusCode: UInt32, Sendable {
        case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4, badMessage = 5
        case noConnection = 6, connectionLost = 7, unsupported = 8
    }

    /// File attributes. Every field is optional because servers send only what the flags say.
    public struct Attributes: Equatable, Sendable {
        public var size: UInt64?
        public var uid: UInt32?
        public var gid: UInt32?
        public var permissions: UInt32?
        public var accessTime: UInt32?
        public var modificationTime: UInt32?

        public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil, accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
            self.size = size; self.uid = uid; self.gid = gid; self.permissions = permissions
            self.accessTime = accessTime; self.modificationTime = modificationTime
        }

        static let flagSize: UInt32 = 0x1, flagUIDGID: UInt32 = 0x2, flagPermissions: UInt32 = 0x4, flagTimes: UInt32 = 0x8, flagExtended: UInt32 = 0x8000_0000

        /// The POSIX file type bits (`S_IFMT`).
        var fileType: UInt32? { permissions.map { $0 & 0o170000 } }
        public var isDirectory: Bool { fileType == 0o040000 }
        public var isSymbolicLink: Bool { fileType == 0o120000 }
        public var isRegularFile: Bool { fileType == 0o100000 }
        public var modified: Date? { modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

        func encoded() -> [UInt8] {
            var flags: UInt32 = 0
            var body: [UInt8] = []
            if let size { flags |= Self.flagSize; body += SFTPBytes.uint64(size) }
            if let uid, let gid { flags |= Self.flagUIDGID; body += SFTPBytes.uint32(uid) + SFTPBytes.uint32(gid) }
            if let permissions { flags |= Self.flagPermissions; body += SFTPBytes.uint32(permissions) }
            if let accessTime, let modificationTime { flags |= Self.flagTimes; body += SFTPBytes.uint32(accessTime) + SFTPBytes.uint32(modificationTime) }
            return SFTPBytes.uint32(flags) + body
        }

        static func decode(_ reader: inout SFTPReader) throws -> Attributes {
            let flags = try reader.uint32()
            var attributes = Attributes()
            if flags & flagSize != 0 { attributes.size = try reader.uint64() }
            if flags & flagUIDGID != 0 { attributes.uid = try reader.uint32(); attributes.gid = try reader.uint32() }
            if flags & flagPermissions != 0 { attributes.permissions = try reader.uint32() }
            if flags & flagTimes != 0 { attributes.accessTime = try reader.uint32(); attributes.modificationTime = try reader.uint32() }
            if flags & flagExtended != 0 {
                let count = try reader.uint32()
                for _ in 0..<count { _ = try reader.string(); _ = try reader.string() }
            }
            return attributes
        }
    }

    /// One directory entry from `READDIR`.
    public struct Name: Equatable, Sendable {
        public var filename: String
        public var longname: String
        public var attributes: Attributes
    }

    /// A decoded server message.
    public enum Response: Equatable, Sendable {
        case version(UInt32, extensions: [String: String])
        case status(id: UInt32, code: UInt32, message: String)
        case handle(id: UInt32, handle: [UInt8])
        case data(id: UInt32, data: [UInt8])
        case name(id: UInt32, names: [Name])
        case attributes(id: UInt32, attributes: Attributes)
        case extendedReply(id: UInt32, data: [UInt8])

        public var requestID: UInt32? {
            switch self {
            case .version: nil
            case .status(let id, _, _), .handle(let id, _), .data(let id, _), .name(let id, _), .attributes(let id, _), .extendedReply(let id, _): id
            }
        }

        static func decode(_ payload: [UInt8]) throws -> Response {
            var reader = SFTPReader(payload)
            let rawType = try reader.byte()
            guard let type = PacketType(rawValue: rawType) else {
                if rawType == 201 { // SSH_FXP_EXTENDED_REPLY
                    let id = try reader.uint32()
                    return .extendedReply(id: id, data: reader.rest())
                }
                throw SFTPError.protocolError("unexpected packet type \(rawType)")
            }
            switch type {
            case .version:
                let version = try reader.uint32()
                var extensions: [String: String] = [:]
                while !reader.isAtEnd {
                    let name = String(decoding: try reader.string(), as: UTF8.self)
                    let value = String(decoding: try reader.string(), as: UTF8.self)
                    extensions[name] = value
                }
                return .version(version, extensions: extensions)
            case .status:
                let id = try reader.uint32()
                let code = try reader.uint32()
                // Message and language tag are optional in practice (some servers omit them).
                let message = reader.isAtEnd ? "" : String(decoding: try reader.string(), as: UTF8.self)
                return .status(id: id, code: code, message: message)
            case .handle:
                return .handle(id: try reader.uint32(), handle: try reader.string())
            case .data:
                return .data(id: try reader.uint32(), data: try reader.string())
            case .name:
                let id = try reader.uint32()
                let count = try reader.uint32()
                var names: [Name] = []
                names.reserveCapacity(Int(min(count, 4096)))
                for _ in 0..<count {
                    let filename = String(decoding: try reader.string(), as: UTF8.self)
                    let longname = String(decoding: try reader.string(), as: UTF8.self)
                    names.append(Name(filename: filename, longname: longname, attributes: try Attributes.decode(&reader)))
                }
                return .name(id: id, names: names)
            case .attrs:
                return .attributes(id: try reader.uint32(), attributes: try Attributes.decode(&reader))
            default:
                throw SFTPError.protocolError("unexpected packet type \(rawType) from the server")
            }
        }
    }

    // MARK: Requests

    /// A whole packet: length, type, payload.
    static func packet(_ type: PacketType, _ payload: [UInt8]) -> [UInt8] {
        let body = [type.rawValue] + payload
        return SFTPBytes.uint32(UInt32(body.count)) + body
    }

    static func initialize() -> [UInt8] { packet(.initialize, SFTPBytes.uint32(3)) }

    static func request(_ type: PacketType, id: UInt32, _ fields: [UInt8]) -> [UInt8] {
        packet(type, SFTPBytes.uint32(id) + fields)
    }

    static func open(id: UInt32, path: String, flags: OpenFlags, attributes: Attributes = Attributes()) -> [UInt8] {
        request(.open, id: id, SFTPBytes.string(path) + SFTPBytes.uint32(flags.rawValue) + attributes.encoded())
    }

    static func close(id: UInt32, handle: [UInt8]) -> [UInt8] { request(.close, id: id, SFTPBytes.string(handle)) }

    static func read(id: UInt32, handle: [UInt8], offset: UInt64, length: UInt32) -> [UInt8] {
        request(.read, id: id, SFTPBytes.string(handle) + SFTPBytes.uint64(offset) + SFTPBytes.uint32(length))
    }

    static func write(id: UInt32, handle: [UInt8], offset: UInt64, data: some Collection<UInt8>) -> [UInt8] {
        request(.write, id: id, SFTPBytes.string(handle) + SFTPBytes.uint64(offset) + SFTPBytes.string(Array(data)))
    }

    static func path(_ type: PacketType, id: UInt32, _ path: String) -> [UInt8] { request(type, id: id, SFTPBytes.string(path)) }

    static func mkdir(id: UInt32, path: String) -> [UInt8] { request(.mkdir, id: id, SFTPBytes.string(path) + Attributes().encoded()) }

    static func rename(id: UInt32, from: String, to: String) -> [UInt8] { request(.rename, id: id, SFTPBytes.string(from) + SFTPBytes.string(to)) }

    /// OpenSSH's `posix-rename@openssh.com`: replaces an existing target atomically.
    static func posixRename(id: UInt32, from: String, to: String) -> [UInt8] {
        request(.extended, id: id, SFTPBytes.string("posix-rename@openssh.com") + SFTPBytes.string(from) + SFTPBytes.string(to))
    }
}

/// Errors from SFTP operations, worded for the interface.
public enum SFTPError: Error, LocalizedError, Equatable {
    case noSuchFile(String)
    case permissionDenied(String)
    case failure(String)
    case unsupported(String)
    case protocolError(String)
    case alreadyExists(String)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case closed

    public var errorDescription: String? {
        switch self {
        case .noSuchFile(let path): "“\(path)” does not exist on the host."
        case .permissionDenied(let path): "The host refused access to “\(path)” (permission denied)."
        case .failure(let detail): "The host could not complete the request: \(detail)."
        case .unsupported(let what): "The host does not support \(what)."
        case .protocolError(let detail): "The file transfer failed: \(detail)."
        case .alreadyExists(let path): "“\(path)” already exists."
        case .sizeMismatch(let expected, let actual): "The transfer is incomplete: expected \(expected) bytes, got \(actual). Nothing was kept."
        case .closed: "The file transfer channel closed."
        }
    }

    static func from(code: UInt32, message: String, path: String) -> SFTPError {
        switch SFTP.StatusCode(rawValue: code) {
        case .noSuchFile: .noSuchFile(path)
        case .permissionDenied: .permissionDenied(path)
        case .unsupported: .unsupported(message.isEmpty ? "this operation" : message)
        case .noConnection, .connectionLost: .closed
        default: .failure(message.isEmpty ? "status \(code)" : message)
        }
    }
}

/// Splits a byte stream into SFTP packet payloads (without the length prefix).
struct SFTPFramer {
    /// Larger than any sensible server packet (OpenSSH uses at most 256 KiB).
    static let maximumPacket = 1 << 20
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: some Collection<UInt8>) { buffer.append(contentsOf: bytes) }

    /// The next complete payload, if any.
    mutating func next() throws -> [UInt8]? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3]))
        guard length > 0, length <= Self.maximumPacket else { throw SFTPError.protocolError("packet length \(length)") }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Array(buffer[4..<(4 + length)])
        buffer.removeFirst(4 + length)
        return payload
    }
}

enum SFTPBytes {
    static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func uint64(_ value: UInt64) -> [UInt8] { uint32(UInt32(value >> 32)) + uint32(UInt32(value & 0xFFFF_FFFF)) }
    static func string(_ bytes: [UInt8]) -> [UInt8] { uint32(UInt32(bytes.count)) + bytes }
    static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }
}

struct SFTPReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw SFTPError.protocolError("truncated packet") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw SFTPError.protocolError("truncated packet") }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func uint64() throws -> UInt64 { UInt64(try uint32()) << 32 | UInt64(try uint32()) }

    mutating func string() throws -> [UInt8] {
        let length = Int(try uint32())
        guard offset + length <= bytes.count else { throw SFTPError.protocolError("truncated string") }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    func rest() -> [UInt8] { Array(bytes[offset...]) }
}
