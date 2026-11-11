import Foundation
import TerminalCore

/// What a session produced before the stream ended, the condition was met, or time ran out.
public struct CollectedOutput: Sendable {
    public var text: String
    public var finalState: SessionState?
    public var timedOut: Bool
}

private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var state: SessionState?

    func append(_ bytes: [UInt8]) -> String {
        lock.lock(); defer { lock.unlock() }
        text += String(decoding: bytes, as: UTF8.self)
        return text
    }

    func finish(_ state: SessionState) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    var snapshot: (String, SessionState?) {
        lock.lock(); defer { lock.unlock() }
        return (text, state)
    }
}

/// Reads terminal events until `done(text)` is true, the session reaches a terminal state, the
/// stream ends, or `seconds` elapse. Never hangs a test run: on timeout the partial output is
/// returned with `timedOut == true` so the failing assertion can show it.
public func collectOutput(
    _ events: AsyncStream<TerminalEvent>,
    seconds: Double = 20,
    until done: @escaping @Sendable (String) -> Bool = { _ in false }
) async -> CollectedOutput {
    let accumulator = Accumulator()
    let finished = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in events {
                switch event {
                case .output(let bytes):
                    if done(accumulator.append(bytes)) { return true }
                case .stateChanged(let state) where state.isTerminal:
                    accumulator.finish(state)
                    return true
                default:
                    break
                }
            }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    let (text, state) = accumulator.snapshot
    return CollectedOutput(text: text, finalState: state, timedOut: !finished)
}
