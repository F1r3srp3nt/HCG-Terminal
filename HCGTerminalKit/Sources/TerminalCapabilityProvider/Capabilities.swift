import Foundation
import TerminalCore

/// The capability areas every provider must report on.
public enum CapabilityKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case localShell
    case executableAccess
    case filesystemPermissions
    case packageManager
    case processInspection
    case privilegedOperations
    case remoteSSH
    case buildOrchestration

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localShell: "Local shell"
        case .executableAccess: "Executable access"
        case .filesystemPermissions: "Filesystem permissions"
        case .packageManager: "Package manager"
        case .processInspection: "Process inspection"
        case .privilegedOperations: "Privileged operations"
        case .remoteSSH: "Remote SSH"
        case .buildOrchestration: "Build and test orchestration"
        }
    }

    public var symbolName: String {
        switch self {
        case .localShell: "terminal"
        case .executableAccess: "gearshape.2"
        case .filesystemPermissions: "folder.badge.gearshape"
        case .packageManager: "shippingbox"
        case .processInspection: "list.bullet.rectangle"
        case .privilegedOperations: "lock.shield"
        case .remoteSSH: "network"
        case .buildOrchestration: "hammer"
        }
    }
}

/// State of one capability. Never optimistic: a capability is "verified" only after it was
/// actually used successfully on this device; anything not observed is reported as such.
public enum CapabilityAvailability: Hashable, Codable, Sendable {
    /// The code for this capability is not part of this build (e.g. the standard build has no
    /// Unleashed backend).
    case notIncluded(String)
    /// The platform or device does not offer this at all (e.g. the iOS sandbox hides the system).
    case unsupportedEnvironment(String)
    /// The environment supports it, but a required program or service is not installed/running.
    case toolMissing(String)
    /// The thing exists, but the system refused this app access (EPERM/EACCES, sandbox).
    case permissionDenied(String)
    /// Everything needed was found by read-only checks, but it has not been used yet.
    case availableUntested(String)
    /// It was used successfully on this device.
    case verified(String)

    /// Whether the user can try to use it now.
    public var isUsable: Bool {
        switch self {
        case .availableUntested, .verified: true
        case .notIncluded, .unsupportedEnvironment, .toolMissing, .permissionDenied: false
        }
    }

    public var label: String {
        switch self {
        case .notIncluded: "Not included in this build"
        case .unsupportedEnvironment: "Unsupported environment"
        case .toolMissing: "Required tool missing"
        case .permissionDenied: "Permission denied"
        case .availableUntested: "Available, not tested"
        case .verified: "Verified working"
        }
    }

    public var symbolName: String {
        switch self {
        case .notIncluded: "shippingbox"
        case .unsupportedEnvironment: "nosign"
        case .toolMissing: "wrench.and.screwdriver"
        case .permissionDenied: "lock"
        case .availableUntested: "questionmark.circle"
        case .verified: "checkmark.seal"
        }
    }

    /// Why it is in this state.
    public var reason: String {
        switch self {
        case .notIncluded(let s), .unsupportedEnvironment(let s), .toolMissing(let s),
             .permissionDenied(let s), .availableUntested(let s), .verified(let s): s
        }
    }

    /// What would change the state, for states that are not usable.
    public var remedy: String? {
        switch self {
        case .notIncluded: "Install the build variant that contains this backend."
        case .unsupportedEnvironment: "Not possible on this device configuration."
        case .toolMissing: "Install or start the missing tool on the device, then re-check."
        case .permissionDenied: "The device must grant this app access; HCG Terminal never tries to bypass a denial."
        case .availableUntested, .verified: nil
        }
    }
}

/// One check that ran, and what it found.
public struct CapabilityEvidence: Hashable, Codable, Sendable {
    /// What was checked, e.g. `access("/var/jb/bin/sh", X_OK)`.
    public var probe: String
    /// What was observed, e.g. `executable` or `EPERM (Operation not permitted)`.
    public var observation: String
    /// Whether this observation supports the capability being present.
    public var positive: Bool

    public init(probe: String, observation: String, positive: Bool) {
        self.probe = probe
        self.observation = observation
        self.positive = positive
    }
}

public struct CapabilityResult: Hashable, Codable, Sendable, Identifiable {
    public var kind: CapabilityKind
    public var availability: CapabilityAvailability
    /// One line: what this capability does in this mode.
    public var summary: String
    /// Checks that ran and their results.
    public var evidence: [CapabilityEvidence]
    /// Each use needs explicit user approval (privileged commands, package changes).
    public var requiresAuthorization: Bool

    public var id: CapabilityKind { kind }

    public init(
        kind: CapabilityKind,
        availability: CapabilityAvailability,
        summary: String,
        evidence: [CapabilityEvidence] = [],
        requiresAuthorization: Bool = false
    ) {
        self.kind = kind
        self.availability = availability
        self.summary = summary
        self.evidence = evidence
        self.requiresAuthorization = requiresAuthorization
    }

    /// The state's reason, unless it only repeats the summary.
    public var detail: String? {
        let reason = availability.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = self.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason != summary, !summary.contains(reason) else { return nil }
        return reason
    }
}

/// A complete, timestamped capability report for one mode.
public struct CapabilityReport: Hashable, Codable, Sendable {
    public var mode: ExecutionMode
    public var generatedAt: Date
    public var results: [CapabilityResult]
    /// Overall verdict for the mode's *local* features. For Vanilla this is always true.
    public var localFeaturesAvailable: Bool
    /// Short explanation of the overall verdict.
    public var headline: String
    /// Build-level facts, e.g. "Standard distribution build".
    public var buildNotes: [String]

    public init(
        mode: ExecutionMode,
        generatedAt: Date = Date(),
        results: [CapabilityResult],
        localFeaturesAvailable: Bool,
        headline: String,
        buildNotes: [String] = []
    ) {
        self.mode = mode
        self.generatedAt = generatedAt
        // Always present all kinds, in canonical order.
        self.results = CapabilityKind.allCases.map { kind in
            results.first(where: { $0.kind == kind })
                ?? CapabilityResult(kind: kind, availability: .notIncluded("Not reported by this provider."), summary: kind.title)
        }
        self.localFeaturesAvailable = localFeaturesAvailable
        self.headline = headline
        self.buildNotes = buildNotes
    }

    public subscript(kind: CapabilityKind) -> CapabilityResult {
        results.first(where: { $0.kind == kind })!
    }

    /// Capabilities that cannot be used now, for "what is missing" explanations.
    public var blockers: [CapabilityResult] {
        results.filter { !$0.availability.isUsable }
    }

    /// Marks capabilities as verified after real use. Only `availableUntested` results change;
    /// a capability reported as unavailable is never upgraded by a claim.
    public func applying(verifications: [CapabilityKind: CapabilityEvidence]) -> CapabilityReport {
        var copy = self
        copy.results = results.map { result in
            guard let evidence = verifications[result.kind], case .availableUntested = result.availability else { return result }
            var updated = result
            updated.availability = .verified(evidence.observation)
            updated.evidence.append(evidence)
            return updated
        }
        return copy
    }

    /// The exact message the interface shows when Unleashed features are unavailable.
    public static let unleashedUnavailableMessage =
        "Unleashed features are not available in this environment. Vanilla terminal and remote development remain available."
}

/// The interface implemented separately by the Vanilla and Unleashed providers.
///
/// Contract:
/// - Detection is read-only. It may stat files, call `access(2)`, list directories, read
///   sysctl values and open a TCP connection to the loopback interface without authenticating.
///   It never writes, spawns processes, loads code, requests privileges or changes settings.
/// - No single indicator decides a result; results carry the evidence used.
/// - Capabilities are never simulated. Anything not observed is reported as unavailable or
///   unverified.
public protocol TerminalCapabilityProvider: Sendable {
    var mode: ExecutionMode { get }
    func detectCapabilities() async -> CapabilityReport
}

/// Shared results for capabilities that do not depend on the local mode. They become
/// "verified" through `CapabilityReport.applying(verifications:)` after real use.
public enum SharedCapabilities {
    public static func remoteSSH() -> CapabilityResult {
        CapabilityResult(
            kind: .remoteSSH,
            availability: .availableUntested("SSH client included; no connection has succeeded yet in this app session."),
            summary: "SSH connections with interactive terminals. Independent of the local mode.",
            evidence: [CapabilityEvidence(probe: "RemoteSSH module", observation: "linked (SwiftNIO SSH)", positive: true)]
        )
    }

    public static func buildOrchestration() -> CapabilityResult {
        CapabilityResult(
            kind: .buildOrchestration,
            availability: .availableUntested("Runs on a connected SSH host that has the toolchain; no build has completed yet in this app session."),
            summary: "Remote Swift, Xcode and .NET builds and tests over SSH. Independent of the local mode.",
            evidence: [CapabilityEvidence(probe: "BuildOrchestrator module", observation: "linked (remote execution only)", positive: true)]
        )
    }
}

/// Used by the standard build, which does not link the Unleashed backend at all.
/// Reports Unleashed as not included without probing anything.
public struct UnleashedNotIncludedCapabilityProvider: TerminalCapabilityProvider {
    public let mode: ExecutionMode = .unleashed

    public init() {}

    public static let reason = "This is the standard build. The Unleashed backend is not included in it."

    public func detectCapabilities() async -> CapabilityReport {
        let evidence = [CapabilityEvidence(probe: "Unleashed backend linked", observation: "no (standard build)", positive: false)]
        let local: [CapabilityResult] = [
            (CapabilityKind.localShell, "Start a shell on this device."),
            (.executableAccess, "Run installed command-line tools."),
            (.filesystemPermissions, "Access permitted locations outside the app sandbox."),
            (.packageManager, "List and change installed packages."),
            (.processInspection, "List running processes."),
            (.privilegedOperations, "Run privileged commands after your approval."),
        ].map { CapabilityResult(kind: $0.0, availability: .notIncluded(Self.reason), summary: $0.1, evidence: evidence) }
        return CapabilityReport(
            mode: .unleashed,
            results: local + [SharedCapabilities.remoteSSH(), SharedCapabilities.buildOrchestration()],
            localFeaturesAvailable: false,
            headline: CapabilityReport.unleashedUnavailableMessage,
            buildNotes: ["Standard build: the Unleashed backend is not linked into this app. It ships only in the separate HCG Terminal Unleashed build."]
        )
    }
}

/// Plain-text rendering of a capability report (for the `capabilities` built-in and exports).
public enum CapabilityReportFormatter {
    public static func text(_ report: CapabilityReport) -> String {
        var lines = ["\(report.mode.displayName) capabilities — \(report.headline)"]
        for result in report.results {
            let approval = result.requiresAuthorization ? " · needs your approval" : ""
            lines.append("  \(result.kind.title.padding(toLength: 30, withPad: " ", startingAt: 0))\(result.availability.label)\(approval)")
            lines.append("      \(result.summary)")
            if let detail = result.detail { lines.append("      \(detail)") }
            for check in result.evidence {
                lines.append("      \(check.positive ? "✓" : "·") \(check.probe): \(check.observation)")
            }
        }
        for note in report.buildNotes { lines.append("  Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}
