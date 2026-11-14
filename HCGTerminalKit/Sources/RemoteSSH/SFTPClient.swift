import Foundation
import NIOCore
import NIOSSH
import TerminalCore

/// One entry in a remote folder.
public struct SFTPEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var size: UInt64?
    public var modified: Date?
    public var permissions: UInt32?
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var id: String { path }

    /// `drwxr-xr-x`-style text for the interface, when the server reported permissions.
    public var modeText: String? {
        guard let permissions else { return nil }
        let kind = isDirectory ? "d" : isSymbolicLink ? "l" : "-"
        let bits = (0..<9).map { index -> Character in
            let mask = UInt32(1) << UInt32(8 - index)
            guard permissions & mask != 0 else { return "-" }
            return ["r", "w", "x"][index % 3]
        }
        return kind + String(bits)
    }
}

/// An SFTP session on an existing SSH connection (the host's `sftp` subsystem, as OpenSSH
/// provides it). Uses the connection's access switches before every operation.
///
/// Transfers are pipelined (several requests in flight) and verified: a download is written to a
/// temporary file and moved into place only when the byte count matches the remote size; an
/// upload goes to a temporary name on the host and is renamed when complete. A cancelled or
/// failed transfer leaves nothing behind.
public actor SFTPClient {
    public nonisolated let endpoint: RemoteEndpoint
    /// Extensions the server announced (e.g. `posix-rename@openssh.com`).
    public let extensions: [String: String]
    private let channel: Channel
    private let handler: NIOLoopBound<SFTPChannelHandler>
    private let connection: SSHConnection
    private var nextID: UInt32 = 1

    /// Bytes per READ/WRITE request and how many may be outstanding.
    static let chunkSize = 32 * 1024
    static let window = 16

    private init(connection: SSHConnection, channel: Channel, handler: NIOLoopBound<SFTPChannelHandler>, extensions: [String: String]) {
        self.connection = connection
        self.endpoint = connection.endpoint
        self.channel = channel
        self.handler = handler
        self.extensions = extensions
    }

    /// Opens the `sftp` subsystem. Fails with `.unsupported` when the host has SFTP disabled.
    public static func open(on connection: SSHConnection, timeout: TimeAmount = .seconds(15)) async throws -> SFTPClient {
        try connection.access.requireAll(connection.requiredAccess)
        let eventLoop = connection.channel.eventLoop
        let ready = eventLoop.makePromise(of: [String: String].self)
        let child = try await connection.openChildChannel { child in
            try child.pipeline.syncOperations.addHandler(SFTPChannelHandler(ready: ready))
        }
        let handler = try await child.eventLoop.submit {
            NIOLoopBound(try child.pipeline.syncOperations.handler(type: SFTPChannelHandler.self), eventLoop: child.eventLoop)
        }.get()
        let timer = eventLoop.scheduleTask(in: timeout) { ready.fail(SSHConnectionError.timedOut) }
        defer { timer.cancel() }
        do {
            let extensions = try await ready.futureResult.get()
            return SFTPClient(connection: connection, channel: child, handler: handler, extensions: extensions)
        } catch {
            child.close(promise: nil)
            throw error
        }
    }

    public func close() async {
        try? await channel.close().get()
    }

    // MARK: Requests

    private func makeID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    /// Sends a request and returns its reply's future without waiting (for pipelining).
    private func submit(_ build: @Sendable (UInt32) -> [UInt8]) throws -> EventLoopFuture<SFTP.Response> {
        try connection.access.requireAll(connection.requiredAccess)
        let id = makeID()
        let packet = build(id)
        let promise = channel.eventLoop.makePromise(of: SFTP.Response.self)
        let handler = self.handler
        channel.eventLoop.execute { handler.value.send(packet, id: id, promise: promise) }
        return promise.futureResult
    }

    private func call(_ build: @Sendable (UInt32) -> [UInt8]) async throws -> SFTP.Response {
        try await submit(build).get()
    }

    /// Expects `SSH_FX_OK`; maps any other status to an error naming `path`.
    private func expectOK(_ response: SFTP.Response, path: String) throws {
        guard case .status(_, let code, let message) = response else { throw SFTPError.protocolError("unexpected reply") }
        guard code == SFTP.StatusCode.ok.rawValue else { throw SFTPError.from(code: code, message: message, path: path) }
    }

    private func expectHandle(_ response: SFTP.Response, path: String) throws -> [UInt8] {
        switch response {
        case .handle(_, let handle): return handle
        case .status(_, let code, let message): throw SFTPError.from(code: code, message: message, path: path)
        default: throw SFTPError.protocolError("unexpected reply")
        }
    }

    // MARK: Paths and folders

    /// The absolute form of `path` (`.` gives the login folder).
    public func realpath(_ path: String) async throws -> String {
        switch try await call({ SFTP.path(.realpath, id: $0, path) }) {
        case .name(_, let names) where !names.isEmpty: return names[0].filename
        case .status(_, let code, let message): throw SFTPError.from(code: code, message: message, path: path)
        default: throw SFTPError.protocolError("unexpected reply")
        }
    }

    public func stat(_ path: String) async throws -> SFTP.Attributes {
        switch try await call({ SFTP.path(.stat, id: $0, path) }) {
        case .attributes(_, let attributes): return attributes
        case .status(_, let code, let message): throw SFTPError.from(code: code, message: message, path: path)
        default: throw SFTPError.protocolError("unexpected reply")
        }
    }

    /// The folder's entries (without `.` and `..`), folders first, then by name.
    public func list(_ path: String) async throws -> [SFTPEntry] {
        let handle = try expectHandle(try await call { SFTP.path(.opendir, id: $0, path) }, path: path)
        var entries: [SFTPEntry] = []
        var failure: Error?
        reading: while true {
            do {
                switch try await call({ SFTP.request(.readdir, id: $0, SFTPBytes.string(handle)) }) {
                case .name(_, let names):
                    for name in names where name.filename != "." && name.filename != ".." {
                        entries.append(SFTPEntry(
                            name: name.filename, path: Self.join(path, name.filename),
                            size: name.attributes.size, modified: name.attributes.modified, permissions: name.attributes.permissions,
                            isDirectory: name.attributes.isDirectory, isSymbolicLink: name.attributes.isSymbolicLink
                        ))
                    }
                case .status(_, let code, _) where code == SFTP.StatusCode.eof.rawValue:
                    break reading
                case .status(_, let code, let message):
                    failure = SFTPError.from(code: code, message: message, path: path)
                    break reading
                default:
                    failure = SFTPError.protocolError("unexpected reply")
                    break reading
                }
            } catch {
                failure = error
                break reading
            }
        }
        _ = try? await call { SFTP.close(id: $0, handle: handle) }
        if let failure { throw failure }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func makeDirectory(_ path: String) async throws {
        try expectOK(try await call { SFTP.mkdir(id: $0, path: path) }, path: path)
    }

    /// Removes a file (`isDirectory == false`) or an empty folder.
    public func remove(_ path: String, isDirectory: Bool) async throws {
        try expectOK(try await call { SFTP.path(isDirectory ? .rmdir : .remove, id: $0, path) }, path: path)
    }

    /// Renames `from` to `to`. With `replace`, an existing `to` is replaced (atomically when the
    /// host supports `posix-rename@openssh.com`).
    public func rename(_ from: String, to: String, replace: Bool) async throws {
        if replace, extensions["posix-rename@openssh.com"] != nil {
            try expectOK(try await call { SFTP.posixRename(id: $0, from: from, to: to) }, path: to)
            return
        }
        if replace {
            _ = try? await call { SFTP.path(.remove, id: $0, to) }
        }
        try expectOK(try await call { SFTP.rename(id: $0, from: from, to: to) }, path: to)
    }

    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    // MARK: Download

    /// Downloads `remotePath` to `destination` (which must not exist yet). Calls `progress` with
    /// bytes received and the total when known. Returns the number of bytes written.
    @discardableResult
    public func download(_ remotePath: String, to destination: URL, progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }) async throws -> UInt64 {
        let attributes = try await stat(remotePath)
        if attributes.isDirectory { throw SFTPError.failure("“\(remotePath)” is a folder") }
        let expected = attributes.size
        let handle = try expectHandle(try await call { SFTP.open(id: $0, path: remotePath, flags: .read) }, path: remotePath)
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".hcg-partial-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: partial) } }
        let file = try FileHandle(forWritingTo: partial)
        var received: UInt64 = 0
        do {
            defer { try? file.close() }
            // Requests in flight, in order. A short reply re-requests its remainder at the end.
            var inFlight: [(offset: UInt64, length: UInt32, reply: EventLoopFuture<SFTP.Response>)] = []
            var nextOffset: UInt64 = 0
            var reachedEnd = false
            func fill() throws {
                while !reachedEnd, inFlight.count < Self.window {
                    if let expected, nextOffset >= expected, !inFlight.isEmpty { break }
                    let offset = nextOffset
                    let length = UInt32(Self.chunkSize)
                    inFlight.append((offset, length, try submit { SFTP.read(id: $0, handle: handle, offset: offset, length: length) }))
                    nextOffset += UInt64(length)
                }
            }
            try fill()
            while !inFlight.isEmpty {
                try Task.checkCancellation()
                let request = inFlight.removeFirst()
                switch try await request.reply.get() {
                case .data(_, let data):
                    try file.seek(toOffset: request.offset)
                    try file.write(contentsOf: data)
                    received += UInt64(data.count)
                    progress(received, expected)
                    if data.count < Int(request.length), !data.isEmpty {
                        let offset = request.offset + UInt64(data.count)
                        let length = request.length - UInt32(data.count)
                        inFlight.append((offset, length, try submit { SFTP.read(id: $0, handle: handle, offset: offset, length: length) }))
                    }
                case .status(_, let code, _) where code == SFTP.StatusCode.eof.rawValue:
                    reachedEnd = true
                case .status(_, let code, let message):
                    throw SFTPError.from(code: code, message: message, path: remotePath)
                default:
                    throw SFTPError.protocolError("unexpected reply")
                }
                try fill()
            }
        } catch {
            _ = try? await call { SFTP.close(id: $0, handle: handle) }
            throw error
        }
        _ = try? await call { SFTP.close(id: $0, handle: handle) }
        if let expected, received != expected { throw SFTPError.sizeMismatch(expected: expected, actual: received) }
        try FileManager.default.moveItem(at: partial, to: destination)
        keep = true
        return received
    }

    // MARK: Upload

    /// Uploads `source` to `remotePath`. Refuses to replace an existing file unless `replace`.
    /// Returns the number of bytes written.
    @discardableResult
    public func upload(_ source: URL, to remotePath: String, replace: Bool, progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }) async throws -> UInt64 {
        if !replace, (try? await stat(remotePath)) != nil { throw SFTPError.alreadyExists(remotePath) }
        let total = UInt64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let temporary = Self.join(Self.parent(of: remotePath), ".hcg-upload-\(UUID().uuidString).part")
        let handle = try expectHandle(try await call { SFTP.open(id: $0, path: temporary, flags: [.write, .create, .exclusive]) }, path: temporary)
        var sent: UInt64 = 0
        var completed = false
        defer {
            if !completed {
                let client = self
                Task { _ = try? await client.call { SFTP.path(.remove, id: $0, temporary) } }
            }
        }
        let file = try FileHandle(forReadingFrom: source)
        do {
            defer { try? file.close() }
            var inFlight: [(length: Int, reply: EventLoopFuture<SFTP.Response>)] = []
            var offset: UInt64 = 0
            var atEnd = false
            while !atEnd || !inFlight.isEmpty {
                try Task.checkCancellation()
                while !atEnd, inFlight.count < Self.window {
                    let chunk = try file.read(upToCount: Self.chunkSize) ?? Data()
                    if chunk.isEmpty { atEnd = true; break }
                    let at = offset
                    inFlight.append((chunk.count, try submit { SFTP.write(id: $0, handle: handle, offset: at, data: chunk) }))
                    offset += UInt64(chunk.count)
                }
                guard !inFlight.isEmpty else { break }
                let request = inFlight.removeFirst()
                try expectOK(try await request.reply.get(), path: remotePath)
                sent += UInt64(request.length)
                progress(sent, total)
            }
        } catch {
            _ = try? await call { SFTP.close(id: $0, handle: handle) }
            throw error
        }
        try expectOK(try await call { SFTP.close(id: $0, handle: handle) }, path: temporary)
        let written = try await stat(temporary).size ?? sent
        guard written == total else { throw SFTPError.sizeMismatch(expected: total, actual: written) }
        try await rename(temporary, to: remotePath, replace: replace)
        completed = true
        return written
    }
}

/// Frames SFTP packets on one SSH session channel and completes each request's promise with the
/// reply that carries its id. Lives on the channel's event loop.
final class SFTPChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let ready: EventLoopPromise<[String: String]>
    private var readyDone = false
    private var framer = SFTPFramer()
    private var pending: [UInt32: EventLoopPromise<SFTP.Response>] = [:]
    private var context: ChannelHandlerContext?
    private var closed = false

    init(ready: EventLoopPromise<[String: String]>) {
        self.ready = ready
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            write(SFTP.initialize(), context: context)
        case is ChannelFailureEvent:
            failReady(SFTPError.unsupported("SFTP (its sftp subsystem is turned off)"))
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let buffer) = message.data else { return }
        framer.append(buffer.readableBytesView)
        do {
            while let payload = try framer.next() {
                let response = try SFTP.Response.decode(payload)
                if case .version(_, let extensions) = response {
                    if !readyDone { readyDone = true; ready.succeed(extensions) }
                } else if let id = response.requestID, let promise = pending.removeValue(forKey: id) {
                    promise.succeed(response)
                }
            }
        } catch {
            failAll(error)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SFTPError.closed)
        context.fireChannelInactive()
    }

    /// Called on the event loop.
    func send(_ packet: [UInt8], id: UInt32, promise: EventLoopPromise<SFTP.Response>) {
        guard !closed, let context else {
            promise.fail(SFTPError.closed)
            return
        }
        pending[id] = promise
        write(packet, context: context)
    }

    private func write(_ bytes: [UInt8], context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(bytes: bytes)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }

    private func failReady(_ error: Error) {
        guard !readyDone else { return }
        readyDone = true
        ready.fail(error)
    }

    private func failAll(_ error: Error) {
        closed = true
        failReady(error)
        let waiting = pending
        pending.removeAll()
        for promise in waiting.values { promise.fail(error) }
    }
}
