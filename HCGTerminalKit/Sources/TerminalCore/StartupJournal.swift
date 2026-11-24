import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A small on-disk record of each launch: which startup phase the app reached, and whether it
/// died on the way (crash signal, uncaught exception, or killed without a trace).
///
/// It exists so a launch failure on a real device leaves evidence the next launch can show:
/// - `begin` runs before any app subsystem is created;
/// - `phase` is written to disk synchronously before each startup step;
/// - `markReady` runs once the interface is up.
///
/// A launch that never reached `ready` is reported to the next launch as `previous`.
///
/// Contents are limited to versions, phase names, paths and signal numbers. Nothing typed by the
/// user, no host names, passwords, keys or tokens is ever written here.
public final class StartupJournal: @unchecked Sendable {
    public struct PreviousLaunch: Sendable, Equatable {
        /// The last phase the earlier launch wrote before it stopped.
        public var lastPhase: String
        /// The crash signal, when one was caught (nil: killed without a signal we could catch, or quit).
        public var signal: Int32?
        /// An uncaught Objective-C exception, when there was one.
        public var exception: String?
        /// The log of that launch, as written.
        public var log: String

        public init(lastPhase: String, signal: Int32? = nil, exception: String? = nil, log: String = "") {
            self.lastPhase = lastPhase
            self.signal = signal
            self.exception = exception
            self.log = log
        }

        public var signalName: String? { signal.map(StartupJournal.signalName) }

        /// One sentence for the recovery screen.
        public var summary: String {
            if let exception { return "It stopped during “\(lastPhase)” with an exception: \(exception)" }
            if let name = signalName { return "It crashed during “\(lastPhase)” (\(name))." }
            return "It stopped during “\(lastPhase)” without reporting a crash. iOS may have ended it (for example a code-signing or memory kill), or it was closed before it finished starting."
        }
    }

    /// The journal of this process, once `begin` has run.
    public private(set) nonisolated(unsafe) static var shared: StartupJournal?

    public let directory: URL
    public var logURL: URL { directory.appendingPathComponent("startup.log") }
    public var previousLogURL: URL { directory.appendingPathComponent("startup.previous.log") }
    var stateURL: URL { directory.appendingPathComponent("startup.state") }
    var signalURL: URL { directory.appendingPathComponent("startup.signal") }
    var exceptionURL: URL { directory.appendingPathComponent("startup.exception") }

    /// The earlier launch, if it did not reach `ready`. Nil after a clean earlier launch or on first launch.
    public private(set) var previous: PreviousLaunch?
    public private(set) var currentPhase = "process start"
    public private(set) var isReady = false
    private let lock = NSLock()
    private let maxLogBytes = 128 * 1024

    /// Opens the journal in `directory` (created if needed) and records the start of this launch.
    /// Never throws: if the directory cannot be written, the journal keeps working in memory only.
    @discardableResult
    public static func begin(directory: URL, header: [(String, String)] = [], installCrashHandlers: Bool = true) -> StartupJournal {
        let journal = StartupJournal(directory: directory)
        journal.start(header: header)
        if installCrashHandlers { journal.installCrashHandlers() }
        shared = journal
        return journal
    }

    init(directory: URL) {
        self.directory = directory
    }

    private func start(header: [(String, String)]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // What did the earlier launch leave behind?
        let state = (try? String(contentsOf: stateURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let earlierLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if let state, state.hasPrefix("running ") {
            let signalText = (try? String(contentsOf: signalURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let exception = (try? String(contentsOf: exceptionURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            previous = PreviousLaunch(
                lastPhase: String(state.dropFirst("running ".count)),
                signal: signalText.flatMap { Int32($0) },
                exception: exception?.isEmpty == false ? exception : nil,
                log: earlierLog
            )
        }
        // Keep the earlier launch's log for the report, then start a fresh one.
        if !earlierLog.isEmpty {
            try? fm.removeItem(at: previousLogURL)
            try? fm.moveItem(at: logURL, to: previousLogURL)
        }
        try? fm.removeItem(at: signalURL)
        try? fm.removeItem(at: exceptionURL)
        var lines = ["== launch \(Self.timestamp())"]
        lines += header.map { "\($0.0): \($0.1)" }
        if let previous {
            lines.append("previous launch did not finish starting: \(previous.summary)")
        }
        append(lines.joined(separator: "\n"))
        writeState("running \(currentPhase)")
        Self.setSignalPhase(currentPhase)
    }

    /// Records that a startup step is about to run. Written to disk before the step, so a crash
    /// inside it is attributed to it.
    public func phase(_ name: String) {
        lock.lock()
        currentPhase = name
        let ready = isReady
        lock.unlock()
        append("\(Self.timestamp()) phase \(name)")
        if !ready { writeState("running \(name)") }
        Self.setSignalPhase(name)
    }

    /// A free-form line (no secrets: callers pass versions, paths, counts, error codes).
    public func note(_ message: String) {
        append("\(Self.timestamp()) \(message)")
    }

    /// The interface is up: later failures are no longer startup failures.
    public func markReady() {
        lock.lock()
        let already = isReady
        isReady = true
        currentPhase = "ready"
        lock.unlock()
        guard !already else { return }
        append("\(Self.timestamp()) ready")
        writeState("ready")
        Self.setSignalPhase("after startup")
    }

    /// The earlier failure has been shown; a later launch should not show it again.
    public func acknowledgePrevious() {
        previous = nil
    }

    /// The text of this launch's log (and the earlier one, if it failed), for sharing.
    public func reportText() -> String {
        var parts: [String] = []
        if let previous {
            parts.append("Earlier launch: \(previous.summary)")
        }
        parts.append((try? String(contentsOf: logURL, encoding: .utf8)) ?? "(startup log unavailable)")
        if let earlier = try? String(contentsOf: previousLogURL, encoding: .utf8), !earlier.isEmpty {
            parts.append("-- earlier launch --\n" + earlier)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Files

    private func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            guard size < UInt64(maxLogBytes) else { return }
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        } else {
            try? data.write(to: logURL)
        }
    }

    private func writeState(_ state: String) {
        try? Data((state + "\n").utf8).write(to: stateURL, options: .atomic)
    }

    // MARK: Crash capture

    /// Signal handlers write "<signal>" to `startup.signal` and a line to the log, then restore the
    /// default action and re-raise, so iOS still writes its own crash report. They use only
    /// async-signal-safe calls (open, write, close, signal, raise) on buffers prepared in advance.
    public func installCrashHandlers() {
        Self.prepareSignalPaths(log: logURL.path, signalFile: signalURL.path)
        for signal in Self.crashSignals {
            Darwinish.installHandler(signal)
        }
        #if canImport(ObjectiveC)
        Self.exceptionFile = exceptionURL
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "no reason")"
            try? Data(text.utf8).write(to: StartupJournal.exceptionFile ?? URL(fileURLWithPath: "/dev/null"))
            StartupJournal.shared?.note("uncaught exception \(text)")
        }
        #endif
    }

    #if canImport(ObjectiveC)
    nonisolated(unsafe) static var exceptionFile: URL?
    #endif

    static let crashSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS]

    public static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: "SIGSEGV, invalid memory access"
        case SIGBUS: "SIGBUS, invalid memory access"
        case SIGILL: "SIGILL, illegal instruction"
        case SIGTRAP: "SIGTRAP, a Swift runtime check failed"
        case SIGABRT: "SIGABRT, abort"
        case SIGFPE: "SIGFPE, arithmetic error"
        case SIGSYS: "SIGSYS, bad system call"
        case SIGKILL: "SIGKILL"
        default: "signal \(signal)"
        }
    }

    // Buffers the signal handler reads. Prepared outside the handler.
    nonisolated(unsafe) static var signalLogPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var signalFilePath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static let phaseBuffer: UnsafeMutablePointer<CChar> = {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 96)
        buffer.initialize(repeating: 0, count: 96)
        return buffer
    }()

    static func prepareSignalPaths(log: String, signalFile: String) {
        signalLogPath = strdup(log)
        signalFilePath = strdup(signalFile)
    }

    static func setSignalPhase(_ phase: String) {
        var bytes = Array(phase.utf8.prefix(94))
        bytes.append(0)
        bytes.withUnsafeBufferPointer { source in
            source.withMemoryRebound(to: CChar.self) { chars in
                phaseBuffer.update(from: chars.baseAddress!, count: chars.count)
            }
        }
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

#if canImport(Darwin)
private let setSignalHandler = Darwin.signal
#elseif canImport(Glibc)
private let setSignalHandler = Glibc.signal
#endif

/// Installs the C-level signal handler. Kept outside the class so it captures nothing.
enum Darwinish {
    static func installHandler(_ number: Int32) {
        _ = setSignalHandler(number, crashSignalHandler)
    }
}

private func writeStatic(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func writeCString(_ fd: Int32, _ string: UnsafePointer<CChar>) {
    _ = write(fd, string, strlen(string))
}

/// Async-signal-safe: no allocation, no locks.
private func writeNumber(_ fd: Int32, _ value: Int32) {
    var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &digits) { raw in
        var n = value < 0 ? -Int(value) : Int(value)
        var index = 11
        repeat {
            index -= 1
            raw[index] = UInt8(48 + n % 10)
            n /= 10
        } while n > 0 && index > 0
        _ = write(fd, raw.baseAddress! + index, 11 - index)
    }
}

private let crashSignalHandler: @convention(c) (Int32) -> Void = { number in
    if let path = StartupJournal.signalFilePath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            writeNumber(fd, number)
            close(fd)
        }
    }
    if let path = StartupJournal.signalLogPath {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 {
            writeStatic(fd, "!! crashed with signal ")
            writeNumber(fd, number)
            writeStatic(fd, " during phase ")
            writeCString(fd, StartupJournal.phaseBuffer)
            writeStatic(fd, "\n")
            close(fd)
        }
    }
    // Let the system handle it as before (its crash report is still written).
    _ = setSignalHandler(number, SIG_DFL)
    raise(number)
}
