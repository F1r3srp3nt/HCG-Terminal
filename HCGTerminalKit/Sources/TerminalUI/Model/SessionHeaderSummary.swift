import Foundation
import TerminalCore

/// The compact session header's one-line summary and its mode note. Pure, so the wording can be
/// tested: it states the session's real state and where it runs, and never suggests that a mode
/// or capability is available when detection said it is not.
public enum SessionHeaderSummary {
    public enum Tone: Equatable, Sendable {
        case live, pending, ended

        /// Icon shown with the colour, so the state is never conveyed by colour alone.
        public var symbolName: String {
            switch self {
            case .live: "checkmark.circle.fill"
            case .pending: "clock"
            case .ended: "stop.circle"
            }
        }
    }

    public static func tone(_ state: SessionState) -> Tone {
        switch state {
        case .ready, .running: .live
        case .notStarted, .connecting: .pending
        case .exited, .failed, .closed: .ended
        }
    }

    /// "Ready · This device · app sandbox", "Connecting · ana@build-mac.local".
    public static func line(state: SessionState, target: ExecutionTarget) -> String {
        "\(state.label) · \(target.detail)"
    }

    /// A short note about the preferred local mode, when it matters for this header:
    /// unavailable, still being checked, or different from this local session's mode.
    public static func modeNote(preferred: ExecutionMode, available: Bool?, target: ExecutionTarget) -> String? {
        switch available {
        case nil:
            return "Checking capabilities…"
        case false?:
            return "\(preferred.displayName) not available here"
        case true?:
            if case .local(let mode) = target, mode != preferred {
                return "New local sessions: \(preferred.displayName)"
            }
            return nil
        }
    }

    /// Full VoiceOver text for the summary control.
    public static func accessibilityText(state: SessionState, target: ExecutionTarget, note: String?) -> String {
        ["Status: \(state.label)", target.label, target.detail, note].compactMap { $0 }.joined(separator: ". ")
    }
}
