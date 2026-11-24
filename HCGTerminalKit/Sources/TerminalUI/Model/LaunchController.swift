import Foundation
import Observation
import TerminalCore

/// Decides what the first screen is, before any app subsystem exists.
///
/// - A normal launch creates the app model at once and shows the app.
/// - If the earlier launch did not finish starting (crash, kill, or closed while starting), the
///   recovery screen comes first. The app model is created only when the user chooses
///   *Start in Safe Mode* or *Start Normally*. A failure in creating it can therefore never
///   stop the recovery screen from opening.
@MainActor
@Observable
public final class LaunchController {
    public enum Stage {
        case recovery(StartupJournal.PreviousLaunch)
        case running(TerminalAppModel)
    }

    public private(set) var stage: Stage
    public let journal: StartupJournal?
    @ObservationIgnored private let makeModel: @MainActor () -> TerminalAppModel

    public init(journal: StartupJournal?, makeModel: @escaping @MainActor () -> TerminalAppModel) {
        self.journal = journal
        self.makeModel = makeModel
        #if DEBUG
        // Simulator smoke runs end the app at any moment, so an earlier "unfinished" launch means
        // nothing there. Two scenarios show the recovery screen and Safe Mode on purpose.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-HCGSmokeScenario"), index + 1 < arguments.count {
            journal?.acknowledgePrevious()
            switch arguments[index + 1] {
            case "startup-recovery":
                stage = .recovery(StartupJournal.PreviousLaunch(
                    lastPhase: "environment detection", signal: SIGTRAP,
                    log: "== launch (sample)\nphase environment detection\n!! crashed with signal \(SIGTRAP) during phase environment detection"
                ))
                return
            case "safe-mode":
                let model = makeModel()
                model.safeMode = true
                stage = .running(model)
                return
            default:
                break
            }
        }
        #endif
        if let previous = journal?.previous {
            journal?.phase("recovery screen")
            stage = .recovery(previous)
        } else {
            journal?.phase("app model")
            stage = .running(makeModel())
        }
    }

    /// Leaves the recovery screen. Safe Mode skips environment detection, the environment
    /// assessment and resuming background jobs until the user runs them.
    public func start(safeMode: Bool) {
        journal?.acknowledgePrevious()
        journal?.phase(safeMode ? "app model (Safe Mode)" : "app model")
        let model = makeModel()
        model.safeMode = safeMode
        stage = .running(model)
    }

    /// The interface is on screen.
    public func interfaceAppeared() {
        journal?.phase("interface")
    }

    /// Startup finished (the model's bootstrap returned).
    public func startupFinished() {
        journal?.markReady()
    }

    public var reportText: String {
        journal?.reportText() ?? "Startup log unavailable."
    }
}
