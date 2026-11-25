import DeveloperWorkspace
import Foundation
import TerminalCore

/// Signing choices HCG Executable Maker's mobile builds accept (`MobileSigningMode`).
public struct ExecutableMakerSigning: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// The project's own settings, unchanged.
        case project
        case unsigned
        case automatic
        case manual

        public var label: String {
            switch self {
            case .project: "Project's signing settings"
            case .unsigned: "Unsigned"
            case .automatic: "Automatic (team)"
            case .manual: "Manual (profile)"
            }
        }
    }

    /// Export methods for an IPA. App Store Connect export is deliberately not offered:
    /// HCG Terminal never prepares uploads.
    public enum Export: String, Codable, CaseIterable, Sendable {
        case debugging
        case releaseTesting = "release-testing"
        case enterprise

        public var label: String {
            switch self {
            case .debugging: "Development (debugging)"
            case .releaseTesting: "Release testing (Ad Hoc)"
            case .enterprise: "Enterprise"
            }
        }
    }

    public var mode: Mode
    public var team: String?
    public var profile: String?
    public var export: Export?

    public init(mode: Mode = .project, team: String? = nil, profile: String? = nil, export: Export? = nil) {
        self.mode = mode
        self.team = team
        self.profile = profile
        self.export = export
    }
}

/// One build through HCG Executable Maker.
public struct ExecutableMakerBuild: Codable, Hashable, Sendable {
    public var output: BuildOutput
    /// The Executable Maker source checkout on the host (from Doctor).
    public var toolPath: String
    /// Executable Maker chooses the scheme itself (first shared app scheme); shown for reference.
    public var scheme: String?
    public var signing: ExecutableMakerSigning
    public var timeoutMinutes: Int

    public init(output: BuildOutput, toolPath: String, scheme: String? = nil, signing: ExecutableMakerSigning = ExecutableMakerSigning(), timeoutMinutes: Int = 60) {
        self.output = output
        self.toolPath = toolPath
        self.scheme = scheme
        self.signing = signing
        self.timeoutMinutes = timeoutMinutes
    }
}

/// HCG Executable Maker's mobile-build command-line interface: the same engine its app uses
/// (import → inspection → toolchain build → verification → checksums → build history).
///
/// Terminal reuses it rather than rebuilding Xcode pipelines itself. It runs on the host from the
/// Executable Maker source checkout with `dotnet run`. Builds are recorded in Executable Maker's
/// own history (its normal data folder), so they also appear in the app.
public enum ExecutableMakerCLI {
    public static let relativeScript = "tools/mobile-build/mobile-build.cs"
    /// Executable Maker's default data folder on macOS (`AppPaths.CreateDefault`).
    public static let dataRoot = "$HOME/Library/Application Support/HCG/ExecutableMaker"

    static func kind(_ output: BuildOutput) throws -> String {
        switch output {
        case .iosSimulatorApp: "ios-simulator"
        case .iosArchive: "ios-archive"
        case .iosIPA: "ios-ipa"
        default: throw BuildPlanError.unsupported("HCG Executable Maker's command-line builds cover iOS Simulator apps, archives and IPAs. \(output.label) uses a direct build.")
        }
    }

    /// The command, run from the Executable Maker checkout. `$HCG_PROJECT_DIR` is the project
    /// folder and `$HCG_JOB_DIR` the job folder, both set by the job runner.
    public static func command(_ build: ExecutableMakerBuild, configuration: BuildConfiguration) throws -> String {
        var arguments = ["--output", try kind(build.output)]
        switch build.signing.mode {
        case .project: arguments += ["--signing", "project"]
        case .unsigned:
            guard build.output != .iosIPA else { throw BuildPlanError.unsupported("An IPA must be signed. Choose the project's signing, Automatic or Manual.") }
            arguments += ["--signing", "unsigned"]
        case .automatic:
            guard let team = build.signing.team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
                throw BuildPlanError.unsupported("Automatic signing needs a 10-character team ID.")
            }
            arguments += ["--signing", "automatic", "--team", team]
        case .manual:
            guard let profile = build.signing.profile, !profile.isEmpty else { throw BuildPlanError.unsupported("Manual signing needs a provisioning profile.") }
            arguments += ["--signing", "manual", "--profile", profile]
            if let team = build.signing.team, !team.isEmpty { arguments += ["--team", team] }
        }
        if build.output == .iosIPA { arguments += ["--export", (build.signing.export ?? .debugging).rawValue] }
        if configuration == .release, build.output == .iosSimulatorApp { arguments += ["--variant", "release"] }
        arguments += ["--timeout-minutes", String(max(5, min(240, build.timeoutMinutes)))]
        // --trust: the user chose to build this project; building runs its own build scripts.
        arguments.append("--trust")
        return "HCG_EXECUTABLE_MAKER_HOME=\"\(dataRoot)\" dotnet run --no-cache \(relativeScript) -- \"$HCG_PROJECT_DIR\" \"$HCG_JOB_DIR/output\" " + ShellQuote.join(arguments)
    }

    /// What Executable Maker reported, read from its output.
    public struct Report: Sendable, Equatable {
        public var stages: [String] = []
        /// "Succeeded", "Failed", "Cancelled", "TimedOut".
        public var result: String?
        public var failureReason: String?
        public var artifacts: [ReportedArtifact] = []
        /// Executable Maker's own build ID (its build history).
        public var buildID: String?
    }

    public struct ReportedArtifact: Sendable, Equatable {
        public var path: String
        public var size: Int64
        public var sha256: String
        /// Passed, PassedWithWarnings, Failed or NotVerifiable.
        public var verification: String
        public var checks: [String]
    }

    private static let stageRegex = try! NSRegularExpression(pattern: #"^   \[(\w+)\] (.*)$"#)
    private static let resultRegex = try! NSRegularExpression(pattern: #"^Result: (\w+) ?(.*?) in [0-9:.]+$"#)
    private static let artifactRegex = try! NSRegularExpression(pattern: #"^  (/.+?)  ([0-9][0-9,.\x{00A0}\x{202F} ']*) bytes  sha256=([0-9a-fA-F]*)  (\w+)$"#)
    private static let checkRegex = try! NSRegularExpression(pattern: #"^     - (.+)$"#)
    private static let historyRegex = try! NSRegularExpression(pattern: #"^History: build ([0-9a-fA-F-]{32,36}) persisted"#)

    public static func parse(_ lines: [String]) -> Report {
        var report = Report()
        func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
        }
        for line in lines {
            if let g = groups(stageRegex, line) {
                report.stages.append("\(g[0]): \(g[1])")
            } else if let g = groups(resultRegex, line) {
                report.result = g[0]
                report.failureReason = g[1].isEmpty ? nil : g[1]
            } else if let g = groups(artifactRegex, line) {
                let digits = g[1].filter(\.isNumber)
                report.artifacts.append(ReportedArtifact(path: g[0], size: Int64(digits) ?? 0, sha256: g[2].lowercased(), verification: g[3], checks: []))
            } else if let g = groups(checkRegex, line), !report.artifacts.isEmpty {
                report.artifacts[report.artifacts.count - 1].checks.append(g[0])
            } else if let g = groups(historyRegex, line) {
                report.buildID = g[0]
            }
        }
        return report
    }
}
