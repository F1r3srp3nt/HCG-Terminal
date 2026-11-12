import Foundation
import TerminalCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors from spawning local processes. Messages include the real `errno` so capability
/// reports can state exactly why execution failed.
public enum ProcessSpawnError: Error, LocalizedError, Equatable {
    case pseudoTerminal(String)
    case spawn(executable: String, errno: Int32, message: String)
    case pipe(String)
    case workingDirectoryUnsupported(executable: String)

    public var errorDescription: String? {
        switch self {
        case .workingDirectoryUnsupported(let executable):
            "Cannot start \(executable) in a chosen directory on this platform: only POSIX shells can change directory before starting."
        case .pseudoTerminal(let message): "Could not open a pseudo-terminal: \(message)"
        case .spawn(let executable, let code, let message): "Could not start \(executable): \(message) (errno \(code))"
        case .pipe(let message): "Could not create a pipe: \(message)"
        }
    }
}

enum POSIX {
    static func errorString(_ code: Int32) -> String { String(cString: strerror(code)) }

    #if canImport(Darwin)
    static let spawnSetSID: Int32 = 0x0400          // POSIX_SPAWN_SETSID
    static let spawnCloexecDefault: Int32 = 0x4000  // POSIX_SPAWN_CLOEXEC_DEFAULT
    typealias FileActions = posix_spawn_file_actions_t?
    typealias Attributes = posix_spawnattr_t?
    #else
    static let spawnSetSID: Int32 = 0x80            // POSIX_SPAWN_SETSID (glibc)
    static let spawnCloexecDefault: Int32 = 0
    typealias FileActions = posix_spawn_file_actions_t
    typealias Attributes = posix_spawnattr_t
    #endif

    /// Decodes a `waitpid` status: exit code, or 128 + signal number.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    static func withCStrings<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    /// How the child is started in a working directory.
    enum WorkingDirectoryStrategy: Sendable {
        /// `posix_spawn_file_actions_addchdir_np` (macOS, Linux).
        case fileAction
        /// The iOS SDK marks `posix_spawn_file_actions_addchdir_np` unavailable, so a POSIX shell
        /// changes directory itself and then `exec`s the real program (no extra process remains).
        case shellTrampoline

        static var platformDefault: WorkingDirectoryStrategy {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            .shellTrampoline
            #else
            .fileAction
            #endif
        }
    }

    static let posixShellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "yash"]

    struct LaunchPlan: Equatable {
        var argv: [String]
        /// Directory to apply with a spawn file action, if any.
        var chdirFileAction: String?
    }

    /// Builds argv for `executable` so that it starts in `workingDirectory`.
    static func launchPlan(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        strategy: WorkingDirectoryStrategy
    ) throws -> LaunchPlan {
        guard let workingDirectory else { return LaunchPlan(argv: [executable] + arguments, chdirFileAction: nil) }
        switch strategy {
        case .fileAction:
            return LaunchPlan(argv: [executable] + arguments, chdirFileAction: workingDirectory)
        case .shellTrampoline:
            guard posixShellNames.contains((executable as NSString).lastPathComponent) else {
                throw ProcessSpawnError.workingDirectoryUnsupported(executable: executable)
            }
            // $0 = "hcg-chdir", $1 = directory, then the real argv. If the directory cannot be
            // entered, the program still starts (in the inherited directory), as a login shell would.
            let script = #"cd -- "$1" 2>/dev/null; shift; exec "$@""#
            return LaunchPlan(argv: [executable, "-c", script, "hcg-chdir", workingDirectory, executable] + arguments, chdirFileAction: nil)
        }
    }

    /// Spawns `executable` with the given stdio setup. The child gets a default signal
    /// disposition, an empty signal mask and (optionally) its own session.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String?,
        newSession: Bool,
        workingDirectoryStrategy: WorkingDirectoryStrategy = .platformDefault,
        configure: (inout FileActions) -> Void
    ) throws -> pid_t {
        let plan = try launchPlan(executable: executable, arguments: arguments, workingDirectory: workingDirectory, strategy: workingDirectoryStrategy)
        #if canImport(Darwin)
        var actions: FileActions = nil
        var attributes: Attributes = nil
        #else
        var actions = FileActions()
        var attributes = Attributes()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        configure(&actions)
        if let directory = plan.chdirFileAction {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            // Unreachable: `.platformDefault` is `.shellTrampoline` here, which never sets a file action.
            throw ProcessSpawnError.workingDirectoryUnsupported(executable: executable + " (" + directory + ")")
            #else
            posix_spawn_file_actions_addchdir_np(&actions, directory)
            #endif
        }

        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var flags = Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK) | spawnCloexecDefault
        if newSession { flags |= spawnSetSID }
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))

        var pid: pid_t = 0
        let result = withCStrings(plan.argv) { argvPointer in
            withCStrings(environment) { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard result == 0 else {
            throw ProcessSpawnError.spawn(executable: executable, errno: result, message: errorString(result))
        }
        return pid
    }
}

/// A process attached to a pseudo-terminal.
public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    public let executable: String
    private let masterFD: Int32
    private let lock = NSLock()
    private var closed = false
    /// Once the reader thread runs, only it may close `masterFD`: closing a descriptor another
    /// thread is reading lets the number be reused (for example by a pipe of another process),
    /// and the stale reader would then consume that pipe's data.
    private var readerStarted = false

    private init(pid: pid_t, masterFD: Int32, executable: String) {
        self.pid = pid
        self.masterFD = masterFD
        self.executable = executable
    }

    /// Opens a PTY pair and spawns `executable` on its secondary side in a new session.
    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        size: TerminalSize
    ) throws -> PTYProcess {
        try spawn(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, size: size, workingDirectoryStrategy: .platformDefault
        )
    }

    /// Same as the public `spawn`, with the working-directory strategy selectable (tests use this
    /// to exercise the iOS trampoline on other platforms).
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        size: TerminalSize,
        workingDirectoryStrategy: POSIX.WorkingDirectoryStrategy
    ) throws -> PTYProcess {
        let (master, secondaryName) = try openPseudoTerminal()
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Darwin initialises a terminal's state (including its window size) when the secondary
        // side is first opened, discarding a size set earlier on the primary side; the child then
        // sees 0x0 until the first resize. Holding the secondary side open here while setting the
        // size and spawning keeps the size on every platform. O_CLOEXEC: the child gets the
        // terminal only through its own stdio.
        let secondary = open(secondaryName, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard secondary >= 0 else {
            let message = POSIX.errorString(errno)
            close(master)
            throw ProcessSpawnError.pseudoTerminal(message)
        }
        defer { close(secondary) }
        setWindowSize(secondary, size)

        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        do {
            let pid = try POSIX.spawn(
                executable: executable, arguments: arguments, environment: env,
                workingDirectory: workingDirectory, newSession: true, workingDirectoryStrategy: workingDirectoryStrategy
            ) { actions in
                // Opening the terminal after setsid() makes it the controlling terminal on Linux.
                // On Darwin it becomes stdio but not the controlling terminal (documented limitation).
                posix_spawn_file_actions_addopen(&actions, 0, secondaryName, O_RDWR, 0)
                posix_spawn_file_actions_adddup2(&actions, 0, 1)
                posix_spawn_file_actions_adddup2(&actions, 0, 2)
            }
            return PTYProcess(pid: pid, masterFD: master, executable: executable)
        } catch {
            close(master)
            throw error
        }
    }

    /// Opens the primary side of a new pseudo-terminal and returns it with the path of the
    /// secondary side.
    static func openPseudoTerminal() throws -> (Int32, String) {
        #if canImport(Darwin)
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw ProcessSpawnError.pseudoTerminal(POSIX.errorString(errno)) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let namePointer = ptsname(master) else {
            let message = POSIX.errorString(errno)
            close(master)
            throw ProcessSpawnError.pseudoTerminal(message)
        }
        return (master, String(cString: namePointer))
        #else
        // Glibc hides posix_openpt & co. behind feature macros; use the devpts interface directly.
        let master = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw ProcessSpawnError.pseudoTerminal(POSIX.errorString(errno)) }
        var unlock: Int32 = 0
        var number: UInt32 = 0
        let TIOCSPTLCK: UInt = 0x4004_5431
        let TIOCGPTN: UInt = 0x8004_5430
        guard ioctl(master, TIOCSPTLCK, &unlock) == 0, ioctl(master, TIOCGPTN, &number) == 0 else {
            let message = POSIX.errorString(errno)
            close(master)
            throw ProcessSpawnError.pseudoTerminal(message)
        }
        return (master, "/dev/pts/\(number)")
        #endif
    }

    static func setWindowSize(_ fd: Int32, _ size: TerminalSize) {
        var windowSize = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
        #if canImport(Darwin)
        _ = ioctl(fd, TIOCSWINSZ, &windowSize)
        #else
        _ = ioctl(fd, UInt(TIOCSWINSZ), &windowSize)
        #endif
    }

    public func resize(_ size: TerminalSize) {
        Self.setWindowSize(masterFD, size)
    }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                #if canImport(Darwin)
                Darwin.write(masterFD, buffer.baseAddress, buffer.count)
                #else
                Glibc.write(masterFD, buffer.baseAddress, buffer.count)
                #endif
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ExecutionError.sessionClosed
            }
            offset += written
        }
    }

    /// Sends `signal` to the process group of the session leader.
    public func signal(_ signal: Int32) {
        _ = kill(-pid, signal)
    }

    /// Reads output on a dedicated thread until the secondary side closes, then reaps the
    /// child and reports its exit code.
    public func startReading(onData: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        let fd = masterFD
        let pid = self.pid
        lock.lock(); readerStarted = true; lock.unlock()
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    onData(Array(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            if let self { self.closeMaster() } else { close(fd) }
            onExit(POSIX.exitCode(fromWaitStatus: status))
        }
        thread.name = "hcg.pty.\(pid)"
        thread.start()
    }

    /// Hangs up the terminal (SIGHUP to the group) and releases the primary side. While the
    /// reader thread runs, the descriptor is replaced by /dev/null (so the reader sees end of
    /// file and closes it itself) instead of being closed under it.
    public func terminate() {
        signal(SIGHUP)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if readerStarted {
            let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
            if null >= 0 {
                _ = dup2(null, masterFD)
                close(null)
                return
            }
        }
        closed = true
        close(masterFD)
    }

    private func closeMaster() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(masterFD)
    }
}

/// Runs a command to completion with pipes (no PTY) and collects its output.
public enum ProcessRunner {
    public struct Result: Sendable, Equatable {
        public var stdout: Data
        public var stderr: Data
        public var status: Int32
        public var pid: Int32 = 0
        /// The process was killed because it exceeded the time limit.
        public var timedOut = false
        /// The process ended because of a signal (e.g. SIGKILL from code-signing enforcement).
        public var terminatingSignal: Int32?
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        outputLimit: Int = 8 * 1024 * 1024,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw ProcessSpawnError.pipe(POSIX.errorString(errno)) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ProcessSpawnError.pipe(POSIX.errorString(errno))
        }
        for fd in [outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let pid: pid_t
        do {
            pid = try POSIX.spawn(
                executable: executable, arguments: arguments, environment: env,
                workingDirectory: workingDirectory, newSession: true
            ) { actions in
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
                posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
                posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
            }
        } catch {
            [outPipe[0], outPipe[1], errPipe[0], errPipe[1]].forEach { close($0) }
            throw error
        }
        close(outPipe[1])
        close(errPipe[1])

        let readOut = outPipe[0], readErr = errPipe[0]
        let finished = LockedFlag()
        let timedOut = LockedFlag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // Bounded: a verification or listing never hangs the app.
                if !finished.value {
                    timedOut.set()
                    _ = kill(-pid, SIGKILL)
                    _ = kill(pid, SIGKILL)
                }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                let thread = Thread {
                    let group = DispatchGroup()
                    let outBox = DataBox(), errBox = DataBox()
                    for (fd, box) in [(readOut, outBox), (readErr, errBox)] {
                        group.enter()
                        Thread {
                            box.data = drain(fd, limit: outputLimit)
                            close(fd)
                            group.leave()
                        }.start()
                    }
                    group.wait()
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    finished.set()
                    let signal: Int32? = (status & 0x7F) != 0 && (status & 0x7F) != 0x7F ? status & 0x7F : nil
                    continuation.resume(returning: Result(
                        stdout: outBox.data, stderr: errBox.data, status: POSIX.exitCode(fromWaitStatus: status),
                        pid: pid, timedOut: timedOut.value, terminatingSignal: signal
                    ))
                }
                thread.start()
            }
        } onCancel: {
            _ = kill(-pid, SIGINT)
        }
    }

    private static func drain(_ fd: Int32, limit: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                if data.count < limit { data.append(contentsOf: buffer[0..<count]) }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
