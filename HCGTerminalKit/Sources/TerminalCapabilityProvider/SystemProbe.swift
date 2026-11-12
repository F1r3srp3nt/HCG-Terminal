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
}

public struct PathProbeFailure: Error, Hashable, Sendable {
    public var probe: PathProbe
    public init(_ probe: PathProbe) { self.probe = probe }
}

public extension SystemProbing {
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
    static func accepts(port: Int, timeout: TimeInterval) -> Bool {
        guard (1...65535).contains(port) else { return false }
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
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
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        guard ready == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
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
