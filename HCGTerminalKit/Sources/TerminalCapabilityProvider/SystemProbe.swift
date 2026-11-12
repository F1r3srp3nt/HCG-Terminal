import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Result of probing one path, keeping the reason a probe failed.
public enum PathProbe: Hashable, Sendable {
    case present
    case missing
    /// The system refused this app (EPERM / EACCES), typically the sandbox.
    case denied(Int32)
    case failed(Int32)

    public var description: String {
        switch self {
        case .present: "present"
        case .missing: "not found (ENOENT)"
        case .denied(let code): "access denied (\(PathProbe.errnoName(code)))"
        case .failed(let code): "failed (\(PathProbe.errnoName(code)))"
        }
    }

    public var isDenied: Bool { if case .denied = self { true } else { false } }

    public static func errnoName(_ code: Int32) -> String {
        let names: [Int32: String] = [EPERM: "EPERM", EACCES: "EACCES", ENOENT: "ENOENT", ENOTDIR: "ENOTDIR", ELOOP: "ELOOP"]
        return "\(names[code] ?? "errno \(code)"): \(String(cString: strerror(code)))"
    }

    static func from(errno code: Int32) -> PathProbe {
        switch code {
        case ENOENT, ENOTDIR: .missing
        case EPERM, EACCES: .denied(code)
        default: .failed(code)
        }
    }
}

/// One system call made by a read-only probe, exactly as it happened.
public struct ProbeRecord: Hashable, Sendable, Codable {
    /// `lstat`, `stat`, `readlink`, `realpath`, `access(X_OK)`, `opendir`, `open(O_RDONLY)`, `connect`, …
    public var operation: String
    public var path: String
    /// The call's return value (0 or a descriptor/byte count on success, -1 on failure).
    public var returnValue: Int32
    /// `errno` when the call failed.
    public var errorCode: Int32?
    /// Extra facts, e.g. the symlink target or the file type.
    public var detail: String
    public var timestamp: Date

    public init(operation: String, path: String, returnValue: Int32, errorCode: Int32? = nil, detail: String = "", timestamp: Date = Date()) {
        self.operation = operation
        self.path = path
        self.returnValue = returnValue
        self.errorCode = errorCode
        self.detail = detail
        self.timestamp = timestamp
    }

    public var succeeded: Bool { errorCode == nil && returnValue >= 0 }

    /// `ENOENT`/`ENOTDIR`: established absence. Everything else that failed is not absence.
    public var showsAbsence: Bool { errorCode == ENOENT || errorCode == ENOTDIR }
    /// `EPERM`/`EACCES`: the system refused this app.
    public var showsDenial: Bool { errorCode == EPERM || errorCode == EACCES }

    public var summary: String {
        if let errorCode { return "returned \(returnValue), \(PathProbe.errnoName(errorCode))" + (detail.isEmpty ? "" : " · \(detail)") }
        return "returned \(returnValue)" + (detail.isEmpty ? "" : " · \(detail)")
    }
}

/// Read-only system observations used by capability providers. Abstracted so detection logic
/// can be tested with a scripted environment.
public protocol SystemProbing: Sendable {
    /// `lstat`, keeping why it failed.
    func probe(_ path: String) -> PathProbe
    /// Directory listing, or the probe failure.
    func listing(_ path: String) -> Result<[String], PathProbeFailure>
    /// `lstat` succeeded.
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    /// `access(path, R_OK)`
    func isReadable(_ path: String) -> Bool
    /// `access(path, W_OK)` — asks the kernel; writes nothing.
    func isWritable(_ path: String) -> Bool
    /// `access(path, X_OK)` on a regular file (or a symlink to one).
    func isExecutableFile(_ path: String) -> Bool
    /// Directory listing, or `nil` if it could not be listed.
    func listDirectory(_ path: String) -> [String]?
    /// Effective user id of this process.
    func effectiveUserID() -> UInt32
    /// Whether a TCP connection to 127.0.0.1:`port` is accepted. No data is sent.
    func loopbackPortAccepts(_ port: Int, timeout: TimeInterval) -> Bool
    /// Number of processes visible through the process table, or `nil` if not permitted.
    func visibleProcessCount() -> Int?
    /// Operating-system description for reports.
    func osDescription() -> String
    /// The path with symlinks resolved (`realpath`), or `nil` if it cannot be resolved.
    func resolvedPath(_ path: String) -> String?

    // Detailed probes: each returns the exact call result, including errno.
    func lstatRecord(_ path: String) -> ProbeRecord
    func statRecord(_ path: String) -> ProbeRecord
    func readlinkRecord(_ path: String) -> ProbeRecord
    func realpathRecord(_ path: String) -> ProbeRecord
    func accessRecord(_ path: String, mode: Int32) -> ProbeRecord
    func listRecord(_ path: String) -> (ProbeRecord, [String]?)
    /// Opens a file read-only and reads at most one byte. Writes nothing.
    func readRecord(_ path: String) -> ProbeRecord
    /// TCP connect to 127.0.0.1 without sending data; errno distinguishes refused from filtered.
    func loopbackRecord(_ port: Int, timeout: TimeInterval) -> ProbeRecord
}

/// File types reported in `ProbeRecord.detail` by `lstat`/`stat`.
public enum ProbedFileType {
    public static let regular = "regular file"
    public static let directory = "directory"
    public static let symlink = "symbolic link"
    public static let other = "other"
}

public struct PathProbeFailure: Error, Hashable, Sendable {
    public var probe: PathProbe
    public init(_ probe: PathProbe) { self.probe = probe }
}

public extension SystemProbing {
    func resolvedPath(_ path: String) -> String? { exists(path) ? path : nil }

    // Defaults built from the boolean checks, for scripted environments.
    private func failure(_ op: String, _ path: String, _ probe: PathProbe) -> ProbeRecord {
        switch probe {
        case .denied(let code), .failed(let code): ProbeRecord(operation: op, path: path, returnValue: -1, errorCode: code)
        case .missing: ProbeRecord(operation: op, path: path, returnValue: -1, errorCode: ENOENT)
        case .present: ProbeRecord(operation: op, path: path, returnValue: 0)
        }
    }

    func lstatRecord(_ path: String) -> ProbeRecord {
        let result = probe(path)
        guard result == .present else { return failure("lstat", path, result) }
        let type = isDirectory(path) ? ProbedFileType.directory : (isExecutableFile(path) || isReadable(path) ? ProbedFileType.regular : ProbedFileType.other)
        return ProbeRecord(operation: "lstat", path: path, returnValue: 0, detail: type)
    }
    func statRecord(_ path: String) -> ProbeRecord {
        var record = lstatRecord(path)
        record.operation = "stat"
        return record
    }
    func readlinkRecord(_ path: String) -> ProbeRecord { ProbeRecord(operation: "readlink", path: path, returnValue: -1, errorCode: EINVAL) }
    func realpathRecord(_ path: String) -> ProbeRecord {
        if let resolved = resolvedPath(path) { return ProbeRecord(operation: "realpath", path: path, returnValue: 0, detail: resolved) }
        return failure("realpath", path, probe(path) == .present ? .failed(ENOENT) : probe(path))
    }
    func accessRecord(_ path: String, mode: Int32) -> ProbeRecord {
        let op = mode == X_OK ? "access(X_OK)" : mode == W_OK ? "access(W_OK)" : "access(R_OK)"
        let ok = mode == X_OK ? isExecutableFile(path) : mode == W_OK ? isWritable(path) : isReadable(path)
        if ok { return ProbeRecord(operation: op, path: path, returnValue: 0) }
        let base = probe(path)
        return failure(op, path, base == .present ? .denied(EACCES) : base)
    }
    func listRecord(_ path: String) -> (ProbeRecord, [String]?) {
        switch listing(path) {
        case .success(let names): return (ProbeRecord(operation: "opendir", path: path, returnValue: 0, detail: "\(names.count) entries"), names)
        case .failure(let failure): return (self.failure("opendir", path, failure.probe), nil)
        }
    }
    func readRecord(_ path: String) -> ProbeRecord {
        isReadable(path) ? ProbeRecord(operation: "open(O_RDONLY)+read", path: path, returnValue: 1) : failure("open(O_RDONLY)", path, probe(path) == .present ? .denied(EACCES) : probe(path))
    }
    func loopbackRecord(_ port: Int, timeout: TimeInterval) -> ProbeRecord {
        loopbackPortAccepts(port, timeout: timeout)
            ? ProbeRecord(operation: "connect", path: "127.0.0.1:\(port)", returnValue: 0, detail: "accepted (no data sent)")
            : ProbeRecord(operation: "connect", path: "127.0.0.1:\(port)", returnValue: -1, errorCode: ECONNREFUSED)
    }

    /// Defaults for probes that only implement the boolean checks (tests).
    func probe(_ path: String) -> PathProbe { exists(path) ? .present : .missing }
    func listing(_ path: String) -> Result<[String], PathProbeFailure> {
        if let entries = listDirectory(path) { return .success(entries) }
        return .failure(PathProbeFailure(probe(path) == .present ? .denied(EPERM) : .missing))
    }
}

/// The real, read-only implementation.
public struct LiveSystemProbe: SystemProbing {
    public init() {}

    public func probe(_ path: String) -> PathProbe {
        var st = stat()
        return lstat(path, &st) == 0 ? .present : PathProbe.from(errno: errno)
    }

    public func listing(_ path: String) -> Result<[String], PathProbeFailure> {
        guard let directory = opendir(path) else { return .failure(PathProbeFailure(PathProbe.from(errno: errno))) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return .success(names)
    }

    public func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    public func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func fileType(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFREG: ProbedFileType.regular
        case S_IFDIR: ProbedFileType.directory
        case S_IFLNK: ProbedFileType.symlink
        default: ProbedFileType.other
        }
    }

    public func lstatRecord(_ path: String) -> ProbeRecord {
        var st = stat()
        let rv = lstat(path, &st)
        if rv != 0 { return ProbeRecord(operation: "lstat", path: path, returnValue: rv, errorCode: errno) }
        return ProbeRecord(operation: "lstat", path: path, returnValue: rv, detail: Self.fileType(st.st_mode) + String(format: ", mode %o", Int(st.st_mode & 0o7777)))
    }

    public func statRecord(_ path: String) -> ProbeRecord {
        var st = stat()
        let rv = stat(path, &st)
        if rv != 0 { return ProbeRecord(operation: "stat", path: path, returnValue: rv, errorCode: errno) }
        return ProbeRecord(operation: "stat", path: path, returnValue: rv, detail: Self.fileType(st.st_mode) + String(format: ", mode %o", Int(st.st_mode & 0o7777)))
    }

    public func readlinkRecord(_ path: String) -> ProbeRecord {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink(path, &buffer, buffer.count - 1)
        if count < 0 { return ProbeRecord(operation: "readlink", path: path, returnValue: -1, errorCode: errno) }
        let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return ProbeRecord(operation: "readlink", path: path, returnValue: Int32(count), detail: target)
    }

    public func realpathRecord(_ path: String) -> ProbeRecord {
        guard let resolved = realpath(path, nil) else { return ProbeRecord(operation: "realpath", path: path, returnValue: -1, errorCode: errno) }
        defer { free(resolved) }
        return ProbeRecord(operation: "realpath", path: path, returnValue: 0, detail: String(cString: resolved))
    }

    public func accessRecord(_ path: String, mode: Int32) -> ProbeRecord {
        let op = mode == X_OK ? "access(X_OK)" : mode == W_OK ? "access(W_OK)" : "access(R_OK)"
        let rv = access(path, mode)
        return ProbeRecord(operation: op, path: path, returnValue: rv, errorCode: rv == 0 ? nil : errno)
    }

    public func listRecord(_ path: String) -> (ProbeRecord, [String]?) {
        switch listing(path) {
        case .success(let names): return (ProbeRecord(operation: "opendir", path: path, returnValue: 0, detail: "\(names.count) entries"), names)
        case .failure(let failure):
            let code: Int32 = switch failure.probe {
            case .denied(let c), .failed(let c): c
            case .missing: ENOENT
            case .present: EIO
            }
            return (ProbeRecord(operation: "opendir", path: path, returnValue: -1, errorCode: code), nil)
        }
    }

    public func readRecord(_ path: String) -> ProbeRecord {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 { return ProbeRecord(operation: "open(O_RDONLY)", path: path, returnValue: fd, errorCode: errno) }
        defer { close(fd) }
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        if count < 0 { return ProbeRecord(operation: "read(1 byte)", path: path, returnValue: Int32(count), errorCode: errno) }
        return ProbeRecord(operation: "open(O_RDONLY)+read", path: path, returnValue: Int32(count), detail: count == 0 ? "empty file" : "first byte readable")
    }

    public func loopbackRecord(_ port: Int, timeout: TimeInterval) -> ProbeRecord {
        let (accepted, code) = LoopbackProbe.connect(port: port, timeout: timeout)
        return accepted
            ? ProbeRecord(operation: "connect", path: "127.0.0.1:\(port)", returnValue: 0, detail: "accepted (no data sent)")
            : ProbeRecord(operation: "connect", path: "127.0.0.1:\(port)", returnValue: -1, errorCode: code, detail: code == ETIMEDOUT ? "no answer within \(timeout) s (filtered or busy)" : "")
    }

    public func isReadable(_ path: String) -> Bool { access(path, R_OK) == 0 }

    public func isWritable(_ path: String) -> Bool { access(path, W_OK) == 0 }

    public func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    public func listDirectory(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func effectiveUserID() -> UInt32 { UInt32(geteuid()) }

    public func loopbackPortAccepts(_ port: Int, timeout: TimeInterval) -> Bool {
        LoopbackProbe.accepts(port: port, timeout: timeout)
    }

    public func visibleProcessCount() -> Int? {
        ProcessTableProbe.visibleProcessCount()
    }

    public func osDescription() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return ProcessInfo.processInfo.operatingSystemVersionString }
        func field<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        return "\(field(name.sysname)) \(field(name.release)) \(field(name.machine)) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// Non-blocking TCP connect to the loopback interface with a timeout. Sends no data.
enum LoopbackProbe {
    static func accepts(port: Int, timeout: TimeInterval) -> Bool { connect(port: port, timeout: timeout).0 }

    /// Returns whether the connection was accepted and, if not, the errno (ETIMEDOUT for no answer).
    static func connect(port: Int, timeout: TimeInterval) -> (Bool, Int32) {
        guard (1...65535).contains(port) else { return (false, EINVAL) }
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return (false, errno) }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = in_addr_t(UInt32(0x7F00_0001).bigEndian)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc_or_Darwin_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return (true, 0) }
        guard errno == EINPROGRESS else { return (false, errno) }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        guard ready == 1 else { return (false, ready == 0 ? ETIMEDOUT : errno) }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return (false, errno) }
        return (error == 0, error)
    }
}

/// `connect(2)`, named so it is not shadowed by `LoopbackProbe.connect`.
@inline(__always)
private func Glibc_or_Darwin_connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

/// Counts processes visible to this process. Read-only.
enum ProcessTableProbe {
    static func visibleProcessCount() -> Int? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // The size estimate includes slack; fetch the table to count what is really visible.
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return size / MemoryLayout<kinfo_proc>.stride
        #elseif os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        return entries.filter { $0.allSatisfy(\.isNumber) }.count
        #else
        return nil
        #endif
    }
}
