#if os(macOS) || os(Linux)
import Foundation
import TerminalCore

/// Runs "remote" commands with the local `/bin/sh`, so host scripts (Doctor, detached jobs) can
/// be exercised for real without SSH. `HOME` can be pointed at a scratch folder.
public struct LocalShellExecutor: RemoteCommandExecuting {
    public let endpoint: RemoteEndpoint
    public let home: String

    public init(home: String, hostID: UUID = UUID()) {
        self.home = home
        self.endpoint = RemoteEndpoint(hostID: hostID, displayName: "Local test host", hostname: "localhost", port: 22, username: NSUserName())
    }

    public func stream(_ command: String) -> AsyncThrowingStream<RemoteExecEvent, Error> {
        let home = self.home
        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home
            environment["SHELL"] = "/bin/sh"
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let group = DispatchGroup()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                    } else {
                        continuation.yield(isOut ? .stdout(data) : .stderr(data))
                    }
                }
            }
            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    continuation.yield(.exit(status: process.terminationStatus))
                    continuation.finish()
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
            }
            do { try process.run() } catch { continuation.finish(throwing: error) }
        }
    }
}
#endif
