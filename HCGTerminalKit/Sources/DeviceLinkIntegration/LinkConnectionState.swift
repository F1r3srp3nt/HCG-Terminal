import Foundation
import HCGDeviceLink

/// What the person compares before the server's owner approves this installation.
public struct PairingProgress: Equatable, Sendable {
    /// Waiting for the owner's decision.
    public var pending: Bool
    public var requestId: String
    public var serverName: String
    /// The pinned key of HCG Server (from the invitation code).
    public var serverFingerprint: String
    /// This installation's key, which the owner sees on the approval screen.
    public var deviceFingerprint: String

    public init(pending: Bool, requestId: String, serverName: String, serverFingerprint: String, deviceFingerprint: String) {
        self.pending = pending
        self.requestId = requestId
        self.serverName = serverName
        self.serverFingerprint = serverFingerprint
        self.deviceFingerprint = deviceFingerprint
    }
}

/// The Device Link connection as the Connected Devices screen shows it.
public enum LinkConnectionState: Equatable, Sendable {
    /// HCG Connect sign-in cannot be used (no client issued, bad file, platform). Nothing is contacted.
    case notConfigured(reason: String)
    case signedOut
    /// No pairing (or the last attempt was rejected or expired; `note` says which).
    case notPaired(note: String?)
    case pairing(PairingProgress)
    case connected(lastSync: Date?)
    /// The last request failed; the next attempt is in `retryIn` seconds.
    case offline(retryIn: TimeInterval, reason: String)
    /// The server no longer accepts this installation. Never retried automatically.
    case removed(reason: String)
    /// The HCG Connect session ended; sign in again.
    case signInEnded(reason: String)

    public var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .signedOut: "Signed out"
        case .notPaired: "Not paired"
        case .pairing(let p): p.pending ? "Waiting for approval" : "Pairing"
        case .connected: "Connected"
        case .offline: "Offline"
        case .removed: "Removed from the server"
        case .signInEnded: "Sign-in ended"
        }
    }

    public var detail: String {
        switch self {
        case .notConfigured(let reason): reason
        case .signedOut: "Sign in with HCG Connect to pair this device with an HCG Server."
        case .notPaired(let note): note ?? "Paste an invitation code from HCG Server to pair this device."
        case .pairing(let p):
            "Ask the owner of \(p.serverName) to approve this device. Compare the key fingerprint shown there with the one shown here."
        case .connected: "Presence and shared reports are synced while this screen is open."
        case .offline(let retry, let reason): "\(reason) Retrying in \(Int(retry.rounded(.up))) s."
        case .removed(let reason), .signInEnded(let reason): reason
        }
    }

    /// Paired and syncing (or retrying).
    public var isLinked: Bool {
        switch self {
        case .connected, .offline: true
        default: false
        }
    }
}

/// How HCG Terminal's HCG Connect sign-in is set up (`hcg-connect.json`).
public enum HCGConnectSetup: Sendable, Equatable {
    case ready(HCGConnectConfiguration)
    case notConfigured(String)

    /// The contract this app's configuration file must declare.
    public static let contract = "hcg.terminal.connect/1"
    public static let fileName = "hcg-connect.json"
    public static let noClientMessage =
        "HCG has not issued an HCG Connect client for HCG Terminal yet, so sign-in is not configured. Nothing is contacted."

    public var configuration: HCGConnectConfiguration? {
        if case .ready(let c) = self { return c }
        return nil
    }

    public var problem: String? {
        if case .notConfigured(let why) = self { return why }
        return nil
    }

    /// Reads the first file that exists. No file, or a file without an issued client, is "not
    /// configured". A file with anything secret-looking or unknown keys is refused.
    public static func load(candidates: [URL]) -> HCGConnectSetup {
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            return evaluate(data)
        }
        return .notConfigured(noClientMessage)
    }

    public static func evaluate(_ data: Data) -> HCGConnectSetup {
        let configuration: HCGConnectConfiguration
        do { configuration = try HCGConnectConfiguration.load(data) } catch let error as HCGConnectError {
            return .notConfigured(error.description)
        } catch {
            return .notConfigured("The HCG Connect file could not be read (\(error.localizedDescription)). Nothing is contacted.")
        }
        guard configuration.contractVersion == contract else {
            return .notConfigured("The HCG Connect file is for \(configuration.contractVersion), not \(contract). Nothing is contacted.")
        }
        guard let id = configuration.clientId, UUID(uuidString: id) != nil, id != "00000000-0000-0000-0000-000000000000" else {
            return .notConfigured(noClientMessage)
        }
        if let problem = configuration.problem(expectedContract: contract) { return .notConfigured(problem) }
        return .ready(configuration)
    }
}

/// The result of one failed request: what to show and when to try again.
public struct LinkFailureOutcome: Equatable, Sendable {
    public var state: LinkConnectionState
    /// `nil`: stop syncing (the link ended, or the person must act).
    public var retryIn: TimeInterval?
}

/// Pure reducer from Device Link results to connection states, with back-off.
public struct LinkConnectionMachine: Sendable {
    public var policy: ReconnectPolicy
    public private(set) var failures = 0

    public init(policy: ReconnectPolicy = ReconnectPolicy()) {
        self.policy = policy
    }

    /// A request succeeded: back-off resets.
    public mutating func succeeded(at date: Date) -> LinkConnectionState {
        failures = 0
        return .connected(lastSync: date)
    }

    /// A request failed.
    /// - `endsLink` → `removed` (or `signInEnded` for an ended HCG session); never retried.
    /// - not signed in → `signedOut`; never retried.
    /// - retryable → `offline`, retried with exponential back-off (honouring `retryAfterSeconds`).
    /// - anything else (for example a missing ERP permission) → `offline` at the longest interval,
    ///   because it changes only when someone changes the configuration.
    public mutating func failed(_ error: DeviceLinkError, random: Double = Double.random(in: -1...1)) -> LinkFailureOutcome {
        if error.endsLink {
            failures = 0
            if error.code == "hcg_session_ended" {
                return LinkFailureOutcome(state: .signInEnded(reason: Self.sentence(error.description) + " Sign in with HCG Connect again."), retryIn: nil)
            }
            return LinkFailureOutcome(state: .removed(reason: Self.removedReason(error)), retryIn: nil)
        }
        if case .notSignedIn = error {
            failures = 0
            return LinkFailureOutcome(state: .signedOut, retryIn: nil)
        }
        failures += 1
        let delay: TimeInterval
        if error.isRetryable {
            delay = policy.delay(afterFailures: failures, retryAfter: error.retryAfter, random: random)
        } else {
            delay = max(policy.maximum, error.retryAfter ?? 0)
        }
        return LinkFailureOutcome(state: .offline(retryIn: delay, reason: Self.sentence(error.description)), retryIn: delay)
    }

    static func removedReason(_ error: DeviceLinkError) -> String {
        let base = sentence(error.description)
        switch error.code {
        case "device_revoked", "unknown_installation":
            return base + " Pair again with a new invitation if you want to reconnect."
        case "wrong_account":
            return base + " This installation was paired with another HCG account; pair again after signing in with the account you want."
        case "pin_mismatch":
            return base
        default:
            return base
        }
    }

    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?)".contains(last) ? t : t + "."
    }

    /// The state with nothing in flight, from what is stored locally.
    public static func resting(
        connect: HCGConnectSetup, signedIn: Bool, pairing: PairingRecord?, deviceFingerprint: String?
    ) -> LinkConnectionState {
        if let problem = connect.problem { return .notConfigured(reason: problem) }
        if pairing?.status == .removed { return .removed(reason: "This device was removed from \(pairing?.serverName ?? "the server").") }
        guard signedIn else { return .signedOut }
        guard let pairing else { return .notPaired(note: nil) }
        switch pairing.status {
        case .pending:
            return .pairing(PairingProgress(pending: true, requestId: pairing.requestId, serverName: pairing.serverName,
                                            serverFingerprint: pairing.serverFingerprint, deviceFingerprint: deviceFingerprint ?? ""))
        case .approved:
            return .connected(lastSync: nil)
        case .rejected:
            return .notPaired(note: "The owner of \(pairing.serverName) rejected the last pairing request. Ask for a new invitation to try again.")
        case .expired:
            return .notPaired(note: "The last pairing request to \(pairing.serverName) expired before it was approved. Ask for a new invitation.")
        case .removed:
            return .removed(reason: "This device was removed from \(pairing.serverName).")
        }
    }
}
