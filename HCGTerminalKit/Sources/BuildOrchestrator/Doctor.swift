import DeveloperWorkspace
import Foundation
import TerminalCore

/// A product a build can produce. Doctor says which outputs each problem affects.
public enum BuildOutput: String, Codable, CaseIterable, Sendable, Hashable {
    case iosSimulatorApp = "ios-simulator"
    case iosArchive = "ios-archive"
    case iosIPA = "ios-ipa"
    case macApp = "macos-app"
    case swiftPackage = "swift-package"
    case dotnet = "dotnet"
    case theosPackage = "theos-deb"

    public var label: String {
        switch self {
        case .iosSimulatorApp: "iOS Simulator app"
        case .iosArchive: "iOS archive (.xcarchive)"
        case .iosIPA: "iOS app (.ipa)"
        case .macApp: "macOS app"
        case .swiftPackage: "Swift package build"
        case .dotnet: ".NET build"
        case .theosPackage: "Theos package (.deb)"
        }
    }

    /// Outputs built through HCG Executable Maker's engine.
    public var usesExecutableMaker: Bool { [.iosSimulatorApp, .iosArchive, .iosIPA].contains(self) }
}

/// One Doctor result.
public struct DoctorCheck: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Comparable, CaseIterable {
        case passed, unknown, warning, blocked

        public var label: String {
            switch self {
            case .passed: "Passed"
            case .warning: "Warning"
            case .blocked: "Blocked"
            case .unknown: "Unknown"
            }
        }

        private var rank: Int { [.passed: 0, .unknown: 1, .warning: 2, .blocked: 3][self]! }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// For tool checks: the three situations that need different fixes.
    public enum Presence: Codable, Sendable, Hashable {
        case found(path: String)
        case notInstalled
        /// Installed at `path`, but the login shell builds use does not find it.
        case notInEnvironment(path: String)
        case incompatible(reason: String)

        public var label: String {
            switch self {
            case .found: "Found"
            case .notInstalled: "Not installed"
            case .notInEnvironment: "Installed, but not found in this environment"
            case .incompatible: "Installed but incompatible"
            }
        }
    }

    public struct Evidence: Codable, Sendable, Hashable {
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var id: String
    public var title: String
    public var status: Status
    public var presence: Presence?
    public var summary: String
    public var evidence: [Evidence]
    public var affects: [BuildOutput]
    public var nextSteps: [String]

    public init(id: String, title: String, status: Status, presence: Presence? = nil, summary: String, evidence: [Evidence] = [], affects: [BuildOutput] = [], nextSteps: [String] = []) {
        self.id = id
        self.title = title
        self.status = status
        self.presence = presence
        self.summary = summary
        self.evidence = evidence
        self.affects = affects
        self.nextSteps = nextSteps
    }
}

/// Facts that builds reuse, so diagnostics and builds use the same resolved environment.
public struct DoctorEnvironment: Codable, Sendable, Hashable {
    public var shell: String?
    public var path: String?
    public var operatingSystem: String?
    public var architecture: String?
    public var isMac: Bool
    public var developerDirectory: String?
    public var theosDirectory: String?
    /// The GNU Make ≥ 4 to use for Theos (may differ from `make` on PATH).
    public var gnuMake: String?
    public var executableMakerPath: String?
    public var executableMakerRevision: String?
    /// Xcode build settings of the selected scheme's first app target.
    public var bundleIdentifier: String?
    public var developmentTeam: String?
    public var codeSignStyle: String?
    public var iosDeploymentTarget: String?
    public var simulatorRuntimes: [String]
    public var signingIdentities: [String]
    public var profiles: [ProvisioningProfileInfo]
}

public struct DoctorReport: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var hostID: UUID
    public var hostName: String
    public var hostAddress: String
    public var projectPath: String
    public var projectLabel: String
    public var scheme: String?
    public var schemes: [String]
    public var ranAt: Date
    public var outputs: [BuildOutput]
    public var checks: [DoctorCheck]
    public var environment: DoctorEnvironment
    /// False when the probe was cut short; missing checks are then reported as unknown.
    public var complete: Bool

    public func blockers(for output: BuildOutput) -> [DoctorCheck] {
        checks.filter { $0.status == .blocked && $0.affects.contains(output) }
    }

    public func warnings(for output: BuildOutput) -> [DoctorCheck] {
        checks.filter { ($0.status == .warning || $0.status == .unknown) && $0.affects.contains(output) }
    }

    public var overall: DoctorCheck.Status { checks.map(\.status).max() ?? .unknown }
}

/// Turns probe facts into checks. Pure, so every rule is unit-tested without a host.
public enum DoctorEvaluator {
    public static func evaluate(
        facts: DoctorFacts,
        host: HostProfile,
        projectPath: String,
        project: ProjectKind?,
        scheme: String?,
        reportID: UUID = UUID(),
        now: Date = Date()
    ) -> DoctorReport {
        var context = Context(facts: facts, project: project, now: now)
        context.run()
        return DoctorReport(
            id: reportID, hostID: host.id, hostName: host.name, hostAddress: host.endpoint.address,
            projectPath: facts.value("project.dir") ?? projectPath, projectLabel: project?.label ?? "Folder",
            scheme: scheme, schemes: context.schemes, ranAt: now, outputs: context.outputs,
            checks: context.checks, environment: context.environment, complete: facts.isComplete
        )
    }

    struct Context {
        let facts: DoctorFacts
        let project: ProjectKind?
        let now: Date
        var checks: [DoctorCheck] = []
        var outputs: [BuildOutput] = []
        var schemes: [String] = []
        var environment: DoctorEnvironment
        var settings: [String: String] = [:]

        init(facts: DoctorFacts, project: ProjectKind?, now: Date) {
            self.facts = facts
            self.project = project
            self.now = now
            let kernel = facts.value("os.kernel")
            environment = DoctorEnvironment(
                shell: facts.value("env.shell"), path: facts.value("env.path"),
                operatingSystem: facts.value("os.product") ?? kernel, architecture: facts.value("os.arch"),
                isMac: kernel == "Darwin", developerDirectory: nil, theosDirectory: nil, gnuMake: nil,
                executableMakerPath: facts.value("em.path"), executableMakerRevision: facts.value("em.revision"),
                bundleIdentifier: nil, developmentTeam: nil, codeSignStyle: nil, iosDeploymentTarget: nil,
                simulatorRuntimes: [], signingIdentities: [], profiles: facts.profiles
            )
        }

        var isXcode: Bool {
            switch project {
            case .xcodeProject?, .xcodeWorkspace?: true
            default: false
            }
        }
        var isDotnet: Bool {
            switch project {
            case .dotnetProject?, .dotnetSolution?: true
            default: false
            }
        }
        var isTheos: Bool {
            if case .theos? = project { return true }
            return facts.block("theos.makefile")?.contains("$(THEOS") == true
        }

        mutating func add(_ check: DoctorCheck) { checks.append(check) }

        mutating func run() {
            readXcodeProject()
            decideOutputs()
            checkHost()
            checkDisk()
            if isXcode { checkXcode(); checkSchemes(); checkDeploymentTarget(); checkExecutableMaker(); checkSigning() }
            if isDotnet || isXcode && outputs.contains(where: \.usesExecutableMaker) { checkDotnet() }
            if case .swiftPackage? = project { checkSwift() }
            if isTheos { checkTheos(); checkMake(); checkLdid(); checkDpkgDeb() }
            if !facts.isComplete {
                add(DoctorCheck(
                    id: "probe", title: "Probe", status: .unknown,
                    summary: "The diagnostic script did not finish, so some checks are missing.",
                    evidence: [.init("Last result", facts.values.keys.sorted().last ?? "none")],
                    affects: outputs, nextSteps: ["Run Doctor again. If it stops again, open a shell on the host and check that the login shell starts without prompting."]
                ))
            }
        }

        // MARK: Project

        mutating func readXcodeProject() {
            guard isXcode else { return }
            if let list = facts.block("xcode.list"), let json = Self.json(list, opening: "{") as? [String: Any] {
                let container = (json["project"] ?? json["workspace"]) as? [String: Any]
                schemes = (container?["schemes"] as? [String]) ?? []
            }
            if let text = facts.block("xcode.settings"), let array = Self.json(text, opening: "[") as? [[String: Any]] {
                let entries = array.compactMap { $0["buildSettings"] as? [String: Any] }
                let app = entries.first { ($0["PRODUCT_TYPE"] as? String) == "com.apple.product-type.application" } ?? entries.first
                for (key, value) in app ?? [:] { if let string = value as? String { settings[key] = string } }
            }
            environment.bundleIdentifier = settings["PRODUCT_BUNDLE_IDENTIFIER"]
            environment.developmentTeam = settings["DEVELOPMENT_TEAM"].flatMap { $0.isEmpty ? nil : $0 }
            environment.codeSignStyle = settings["CODE_SIGN_STYLE"]
            environment.iosDeploymentTarget = settings["IPHONEOS_DEPLOYMENT_TARGET"]
        }

        mutating func decideOutputs() {
            switch project {
            case .xcodeProject?, .xcodeWorkspace?:
                let platforms = settings["SUPPORTED_PLATFORMS"] ?? settings["SDKROOT"] ?? ""
                if platforms.contains("iphone") || platforms.isEmpty { outputs += [.iosSimulatorApp, .iosArchive, .iosIPA] }
                if platforms.contains("macosx") { outputs.append(.macApp) }
            case .swiftPackage?: outputs = [.swiftPackage]
            case .dotnetProject?, .dotnetSolution?: outputs = [.dotnet]
            case .theos?: outputs = [.theosPackage]
            case nil: break
            }
            if isTheos, !outputs.contains(.theosPackage) { outputs.append(.theosPackage) }
        }

        // MARK: Host

        mutating func checkHost() {
            let os = environment.operatingSystem ?? "unknown"
            var evidence: [DoctorCheck.Evidence] = [.init("System", os), .init("Architecture", environment.architecture ?? "unknown")]
            if let kernel = facts.value("os.release") { evidence.append(.init("Kernel", kernel)) }
            if let shell = environment.shell { evidence.append(.init("Login shell", shell)) }
            if let path = environment.path { evidence.append(.init("PATH (login shell)", path)) }
            let appleOutputs = outputs.filter { [.iosSimulatorApp, .iosArchive, .iosIPA, .macApp].contains($0) }
            if !appleOutputs.isEmpty, !environment.isMac {
                add(DoctorCheck(id: "host", title: "Operating system", status: .blocked, summary: "Xcode builds need a Mac; this host runs \(os).", evidence: evidence, affects: appleOutputs, nextSteps: ["Run this project's Apple builds on a Mac host."]))
            } else {
                add(DoctorCheck(id: "host", title: "Operating system", status: .passed, summary: "\(os) on \(environment.architecture ?? "unknown architecture").", evidence: evidence, affects: outputs))
            }
        }

        mutating func checkDisk() {
            guard let kb = facts.value("disk.project_kb").flatMap(Int64.init) else {
                add(DoctorCheck(id: "disk", title: "Disk space", status: .unknown, summary: "Free space could not be read.", evidence: [], affects: outputs, nextSteps: ["Check free space with `df -h` on the host."]))
                return
            }
            let bytes = kb * 1024
            let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let evidence: [DoctorCheck.Evidence] = [.init("Free on \(facts.value("disk.mount") ?? "project volume")", text)]
            let gb: Int64 = 1_000_000_000
            let (status, summary): (DoctorCheck.Status, String) = bytes < 2 * gb
                ? (.blocked, "Only \(text) free. Builds need room for intermediate files.")
                : bytes < 10 * gb ? (.warning, "\(text) free. Xcode builds can need several GB.") : (.passed, "\(text) free.")
            add(DoctorCheck(id: "disk", title: "Disk space", status: status, summary: summary, evidence: evidence, affects: outputs,
                            nextSteps: status == .passed ? [] : ["Free space on the host (for example remove old DerivedData or Simulator runtimes you no longer use)."]))
        }

        // MARK: Xcode

        var appleOutputs: [BuildOutput] { outputs.filter { [.iosSimulatorApp, .iosArchive, .iosIPA, .macApp].contains($0) } }

        mutating func checkXcode() {
            guard environment.isMac else { return }
            let selected = facts.value("xcode.select") ?? ""
            let apps = facts.all("xcode.app")
            let version = facts.block("xcode.version") ?? ""
            environment.developerDirectory = selected.hasPrefix("/") ? selected : nil
            var evidence: [DoctorCheck.Evidence] = [.init("xcode-select -p", selected.isEmpty ? "(no output)" : selected)]
            if !version.isEmpty { evidence.append(.init("xcodebuild -version", version)) }
            if !apps.isEmpty { evidence.append(.init("Xcode apps", apps.joined(separator: ", "))) }
            if let developerDir = facts.value("env.developer_dir") { evidence.append(.init("DEVELOPER_DIR", developerDir)) }
            let affects = appleOutputs

            if apps.isEmpty && !selected.contains("Xcode") {
                add(DoctorCheck(id: "xcode", title: "Xcode", status: .blocked, presence: .notInstalled,
                                summary: "Xcode is not installed. The Command Line Tools alone cannot build apps.",
                                evidence: evidence, affects: affects, nextSteps: ["Install Xcode from the App Store or developer.apple.com on the Mac, open it once, then run Doctor again."]))
                return
            }
            if selected.contains("CommandLineTools"), let app = apps.first {
                add(DoctorCheck(id: "xcode", title: "Xcode", status: .blocked, presence: .notInEnvironment(path: app),
                                summary: "Xcode is installed at \(app), but the active developer directory is the Command Line Tools.",
                                evidence: evidence, affects: affects,
                                nextSteps: ["On the Mac, run `sudo xcode-select -s \(app)/Contents/Developer` (HCG Terminal does not change this for you)."]))
                return
            }
            let lowered = version.lowercased()
            if lowered.contains("license") {
                add(DoctorCheck(id: "xcode", title: "Xcode", status: .blocked, presence: .incompatible(reason: "license not accepted"),
                                summary: "The Xcode license has not been accepted on this Mac.", evidence: evidence, affects: affects,
                                nextSteps: ["On the Mac, run `sudo xcodebuild -license` and accept, or open Xcode once."]))
                return
            }
            if facts.value("xcode.first_launch_status").flatMap(Int.init).map({ $0 != 0 }) == true {
                add(DoctorCheck(id: "xcode", title: "Xcode", status: .blocked, presence: .incompatible(reason: "first launch not completed"),
                                summary: "Xcode's first-launch setup has not been completed.", evidence: evidence, affects: affects,
                                nextSteps: ["On the Mac, run `sudo xcodebuild -runFirstLaunch` or open Xcode once."]))
                return
            }
            guard version.contains("Xcode") else {
                add(DoctorCheck(id: "xcode", title: "Xcode", status: .unknown, summary: "xcodebuild did not report a version.", evidence: evidence, affects: affects,
                                nextSteps: ["Run `xcodebuild -version` on the Mac and check its output."]))
                return
            }
            add(DoctorCheck(id: "xcode", title: "Xcode", status: .passed, presence: .found(path: selected),
                            summary: version.split(separator: "\n").joined(separator: " · "), evidence: evidence, affects: affects))

            // SDKs
            let iosSDK = facts.value("sdk.iphoneos"), simSDK = facts.value("sdk.iphonesimulator"), macSDK = facts.value("sdk.macosx")
            var sdkEvidence: [DoctorCheck.Evidence] = []
            if let iosSDK { sdkEvidence.append(.init("iOS SDK", iosSDK)) }
            if let simSDK { sdkEvidence.append(.init("iOS Simulator SDK", simSDK)) }
            if let macSDK { sdkEvidence.append(.init("macOS SDK", macSDK)) }
            environment.simulatorRuntimes = (facts.block("simulator.runtimes") ?? "").split(separator: "\n").map(String.init)
            sdkEvidence.append(.init("Simulator runtimes", environment.simulatorRuntimes.isEmpty ? "none installed" : environment.simulatorRuntimes.map(Self.runtimeShortName).joined(separator: ", ")))
            var missing: [BuildOutput] = []
            if iosSDK == nil { missing += affects.filter { $0 == .iosArchive || $0 == .iosIPA } }
            if simSDK == nil { missing += affects.filter { $0 == .iosSimulatorApp } }
            if macSDK == nil { missing += affects.filter { $0 == .macApp } }
            if !missing.isEmpty {
                add(DoctorCheck(id: "sdks", title: "SDKs", status: .blocked, presence: .notInstalled,
                                summary: "Missing SDK for: \(missing.map(\.label).joined(separator: ", ")).", evidence: sdkEvidence, affects: missing,
                                nextSteps: ["In Xcode → Settings → Components, install the iOS platform."]))
            } else if affects.contains(.iosSimulatorApp), environment.simulatorRuntimes.isEmpty {
                add(DoctorCheck(id: "sdks", title: "SDKs", status: .warning, summary: "SDKs are installed, but no iOS Simulator runtime is, so a Simulator app can be built but not launched.",
                                evidence: sdkEvidence, affects: [.iosSimulatorApp], nextSteps: ["In Xcode → Settings → Components, download an iOS Simulator runtime."]))
            } else {
                add(DoctorCheck(id: "sdks", title: "SDKs", status: .passed, summary: "Required SDKs are installed.", evidence: sdkEvidence, affects: affects))
            }
        }

        mutating func checkSchemes() {
            guard environment.isMac else { return }
            let listText = facts.block("xcode.list") ?? ""
            if schemes.isEmpty {
                let error = listText.split(separator: "\n").first { $0.contains("error") }.map(String.init)
                add(DoctorCheck(id: "schemes", title: "Schemes", status: listText.isEmpty ? .unknown : .blocked,
                                summary: listText.isEmpty ? "Schemes were not listed." : "No schemes were found." + (error.map { " \($0)" } ?? ""),
                                evidence: [.init("xcodebuild -list", String(listText.prefix(400)))], affects: appleOutputs,
                                nextSteps: ["Open the project in Xcode and mark the app's scheme as Shared (Product → Scheme → Manage Schemes)."]))
                return
            }
            add(DoctorCheck(id: "schemes", title: "Schemes", status: .passed, summary: "\(schemes.count) scheme(s): \(schemes.prefix(6).joined(separator: ", "))", evidence: [.init("Schemes", schemes.joined(separator: ", "))], affects: appleOutputs))
        }

        mutating func checkDeploymentTarget() {
            guard environment.isMac, isXcode else { return }
            guard !settings.isEmpty else {
                add(DoctorCheck(id: "deployment", title: "Deployment target", status: .unknown,
                                summary: "Build settings were not read" + ((facts.block("xcode.settings")?.contains("error") ?? false) ? ": xcodebuild reported an error." : ". Choose a scheme and run Doctor again."),
                                evidence: facts.block("xcode.settings").map { [.init("xcodebuild -showBuildSettings", String($0.prefix(400)))] } ?? [], affects: appleOutputs))
                return
            }
            var evidence: [DoctorCheck.Evidence] = []
            for key in ["IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET", "SDKROOT", "SUPPORTED_PLATFORMS", "PRODUCT_BUNDLE_IDENTIFIER", "TARGET_NAME"] {
                if let value = settings[key], !value.isEmpty { evidence.append(.init(key, value)) }
            }
            if let target = settings["IPHONEOS_DEPLOYMENT_TARGET"], let sdk = facts.value("sdk.iphoneos"), Version(target) > Version(sdk) {
                add(DoctorCheck(id: "deployment", title: "Deployment target", status: .blocked, presence: .incompatible(reason: "deployment target \(target) > SDK \(sdk)"),
                                summary: "The project targets iOS \(target), newer than this Xcode's iOS SDK \(sdk).", evidence: evidence, affects: [.iosSimulatorApp, .iosArchive, .iosIPA],
                                nextSteps: ["Install a newer Xcode on the Mac, or lower IPHONEOS_DEPLOYMENT_TARGET in the project."]))
                return
            }
            if let target = settings["IPHONEOS_DEPLOYMENT_TARGET"], outputs.contains(.iosSimulatorApp), !environment.simulatorRuntimes.isEmpty,
               !environment.simulatorRuntimes.contains(where: { Version(Self.runtimeVersion($0)) >= Version(target) }) {
                add(DoctorCheck(id: "deployment", title: "Deployment target", status: .warning,
                                summary: "No installed Simulator runtime is iOS \(target) or newer, so the Simulator app cannot be launched.",
                                evidence: evidence, affects: [.iosSimulatorApp], nextSteps: ["Install an iOS \(target)+ Simulator runtime in Xcode → Settings → Components."]))
                return
            }
            add(DoctorCheck(id: "deployment", title: "Deployment target", status: .passed,
                            summary: settings["IPHONEOS_DEPLOYMENT_TARGET"].map { "iOS \($0) (effective, from the selected scheme)." } ?? settings["MACOSX_DEPLOYMENT_TARGET"].map { "macOS \($0) (effective)." } ?? "Read from the selected scheme.",
                            evidence: evidence, affects: appleOutputs))
        }

        // MARK: Executable Maker

        mutating func checkExecutableMaker() {
            let emOutputs = outputs.filter(\.usesExecutableMaker)
            guard !emOutputs.isEmpty, environment.isMac else { return }
            var evidence: [DoctorCheck.Evidence] = []
            if let app = facts.value("em.app") { evidence.append(.init("App", app)) }
            guard let path = facts.value("em.path") else {
                add(DoctorCheck(id: "executable-maker", title: "HCG Executable Maker", status: .blocked, presence: .notInstalled,
                                summary: "No HCG Executable Maker source checkout with its build CLI (\(ExecutableMakerCLI.relativeScript)) was found." + (facts.value("em.app") != nil ? " The installed app has no command-line build interface." : ""),
                                evidence: evidence, affects: emOutputs,
                                nextSteps: ["On the Mac, clone HCG Executable Maker (for example to ~/HCG-Executable-Maker), or set its folder in this host's settings.", "Direct xcodebuild builds remain available without it."]))
                return
            }
            evidence.append(.init("Source checkout", path))
            if let revision = facts.value("em.revision") { evidence.append(.init("Revision", revision)) }
            add(DoctorCheck(id: "executable-maker", title: "HCG Executable Maker", status: .passed, presence: .found(path: path),
                            summary: "Build CLI found at \(path). It also needs the .NET SDK below.", evidence: evidence, affects: emOutputs))
        }

        // MARK: Signing

        mutating func checkSigning() {
            guard environment.isMac, outputs.contains(.iosArchive) || outputs.contains(.iosIPA) else { return }
            let identityLines = (facts.block("signing.identities") ?? "").split(separator: "\n").map(String.init)
            let identities = identityLines.compactMap { line -> String? in
                guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return nil }
                return String(line[line.index(after: open)..<close])
            }
            environment.signingIdentities = identities
            var evidence: [DoctorCheck.Evidence] = [.init("Signing identities", identities.isEmpty ? "none valid" : identities.joined(separator: "; "))]
            if let team = environment.developmentTeam { evidence.append(.init("DEVELOPMENT_TEAM", team)) }
            if let style = environment.codeSignStyle { evidence.append(.init("CODE_SIGN_STYLE", style)) }
            if let bundle = environment.bundleIdentifier { evidence.append(.init("Bundle ID", bundle)) }
            let matching = environment.bundleIdentifier.map { bundle in facts.profiles.filter { $0.covers(bundleID: bundle) && (environment.developmentTeam == nil || $0.teamID == environment.developmentTeam) } } ?? []
            let valid = matching.filter { !$0.isExpired(at: now) }
            if !matching.isEmpty {
                evidence.append(.init("Matching profiles", matching.map { "\($0.name) (\($0.kind.rawValue)\($0.isExpired(at: now) ? ", expired" : ""))" }.joined(separator: "; ")))
            }
            if identityLines.contains(where: { $0.contains("SecKeychain") || $0.contains("could not be found") }) {
                add(DoctorCheck(id: "signing", title: "Signing", status: .unknown, summary: "The keychain could not be read over SSH.", evidence: evidence, affects: [.iosIPA, .iosArchive],
                                nextSteps: ["Log in to the Mac's desktop once (unlocks the login keychain) and run Doctor again."]))
                return
            }
            if identities.isEmpty {
                add(DoctorCheck(id: "signing", title: "Signing", status: .blocked, presence: .notInstalled,
                                summary: "No valid code-signing identity on this Mac. Unsigned archives can still be made; installable IPAs cannot.",
                                evidence: evidence, affects: [.iosIPA],
                                nextSteps: ["In Xcode → Settings → Accounts, sign in and create an Apple Development certificate."]))
                return
            }
            if environment.codeSignStyle == "Manual", valid.isEmpty {
                add(DoctorCheck(id: "signing", title: "Signing", status: .blocked, presence: .incompatible(reason: "no valid profile for the bundle ID"),
                                summary: "Manual signing is set, but no unexpired provisioning profile on the Mac covers \(environment.bundleIdentifier ?? "the app").",
                                evidence: evidence, affects: [.iosIPA, .iosArchive],
                                nextSteps: ["Download the profile in Xcode → Settings → Accounts → Download Manual Profiles, or switch the target to Automatic signing."]))
                return
            }
            if !valid.isEmpty {
                add(DoctorCheck(id: "signing", title: "Signing", status: .passed, summary: "\(identities.count) identity(ies); \(valid.count) valid profile(s) cover the app.", evidence: evidence, affects: [.iosIPA, .iosArchive]))
            } else if !matching.isEmpty {
                add(DoctorCheck(id: "signing", title: "Signing", status: .warning, summary: "Every matching profile has expired. Automatic signing may renew it during the build.",
                                evidence: evidence, affects: [.iosIPA], nextSteps: ["Open the project in Xcode once to renew profiles, or download them in Settings → Accounts."]))
            } else {
                add(DoctorCheck(id: "signing", title: "Signing", status: .unknown,
                                summary: "Signing identities exist. With Automatic signing, Xcode creates a profile during the build if your account is signed in; that cannot be checked without building.",
                                evidence: evidence, affects: [.iosIPA]))
            }
        }

        // MARK: .NET

        mutating func checkDotnet() {
            let needsForEM = outputs.contains(where: \.usesExecutableMaker) && facts.value("em.path") != nil
            let affects = isDotnet ? [BuildOutput.dotnet] + (needsForEM ? outputs.filter(\.usesExecutableMaker) : []) : outputs.filter(\.usesExecutableMaker)
            guard isDotnet || needsForEM else { return }
            let path = facts.value("tool.dotnet")
            let version = facts.block("dotnet.version") ?? ""
            let sdks = (facts.block("dotnet.sdks") ?? "").split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0.first?.isNumber == true }
            var evidence: [DoctorCheck.Evidence] = []
            if let path { evidence.append(.init("dotnet", path)) }
            if !version.isEmpty { evidence.append(.init("dotnet --version (project folder)", version)) }
            if !sdks.isEmpty { evidence.append(.init("Installed SDKs", sdks.joined(separator: ", "))) }
            if let global = facts.block("dotnet.global_json") { evidence.append(.init("global.json", String(global.prefix(300)))) }
            let frameworks = Self.targetFrameworks(facts.block("dotnet.frameworks") ?? "")
            if !frameworks.isEmpty { evidence.append(.init("Target frameworks", frameworks.joined(separator: ", "))) }

            guard let path else {
                if let candidate = facts.value("candidate.dotnet") {
                    add(DoctorCheck(id: "dotnet", title: ".NET SDK", status: .blocked, presence: .notInEnvironment(path: candidate),
                                    summary: ".NET is installed at \(candidate), but the login shell builds use does not find `dotnet`.", evidence: evidence, affects: affects,
                                    nextSteps: ["Add \((candidate as NSString).deletingLastPathComponent) to PATH in your login profile (for example ~/.zprofile) on the host."]))
                } else {
                    add(DoctorCheck(id: "dotnet", title: ".NET SDK", status: .blocked, presence: .notInstalled, summary: "The .NET SDK is not installed on this host.", evidence: evidence, affects: affects,
                                    nextSteps: ["Install the .NET SDK from dot.net on the host."]))
                }
                return
            }
            if version.contains("compatible .NET SDK") || version.contains("was not found") || version.contains("could not be found") || version.lowercased().contains("error") {
                add(DoctorCheck(id: "dotnet", title: ".NET SDK", status: .blocked, presence: .incompatible(reason: "global.json"),
                                summary: "`dotnet` is installed, but none of its SDKs satisfies this project's global.json.", evidence: evidence, affects: affects,
                                nextSteps: ["Install the SDK version global.json asks for, or relax its `rollForward` policy."]))
                return
            }
            let active = version.split(separator: "\n").last.map(String.init) ?? version
            if let needed = frameworks.compactMap(Self.frameworkMajor).max(), let activeMajor = Version(active).components.first, activeMajor < needed {
                add(DoctorCheck(id: "dotnet", title: ".NET SDK", status: .blocked, presence: .incompatible(reason: "SDK \(active) < net\(needed)"),
                                summary: "The project targets .NET \(needed), but the active SDK is \(active).", evidence: evidence, affects: [.dotnet],
                                nextSteps: ["Install the .NET \(needed) SDK on the host."]))
                return
            }
            if needsForEM {
                let required = Self.emRequiredSDK(facts.value("em.global_json"))
                if !sdks.contains(where: { Version($0).components.first == required.components.first && Version($0) >= required }) {
                    add(DoctorCheck(id: "dotnet", title: ".NET SDK", status: .blocked, presence: .incompatible(reason: "Executable Maker needs SDK \(required.text)"),
                                    summary: "HCG Executable Maker needs .NET SDK \(required.text) or a later \(required.components.first ?? 10).0 feature band; installed: \(sdks.isEmpty ? "none" : sdks.joined(separator: ", ")).",
                                    evidence: evidence, affects: outputs.filter(\.usesExecutableMaker),
                                    nextSteps: ["Install the .NET \(required.components.first ?? 10) SDK on the Mac."]))
                    return
                }
            }
            add(DoctorCheck(id: "dotnet", title: ".NET SDK", status: .passed, presence: .found(path: path), summary: "SDK \(active) at \(path).", evidence: evidence, affects: affects))
        }

        // MARK: Swift

        mutating func checkSwift() {
            if let path = facts.value("tool.swift") {
                add(DoctorCheck(id: "swift", title: "Swift", status: .passed, presence: .found(path: path), summary: (facts.block("swift.version") ?? "").split(separator: "\n").first.map(String.init) ?? path,
                                evidence: [.init("swift", path)], affects: [.swiftPackage]))
            } else if let candidate = facts.value("candidate.swift") {
                add(DoctorCheck(id: "swift", title: "Swift", status: .blocked, presence: .notInEnvironment(path: candidate), summary: "Swift is at \(candidate) but not on the login shell's PATH.", affects: [.swiftPackage],
                                nextSteps: ["Add \((candidate as NSString).deletingLastPathComponent) to PATH in your login profile."]))
            } else {
                add(DoctorCheck(id: "swift", title: "Swift", status: .blocked, presence: .notInstalled, summary: "Swift is not installed.", affects: [.swiftPackage], nextSteps: ["Install Xcode (macOS) or a Swift toolchain from swift.org (Linux)."]))
            }
        }

        // MARK: Theos

        mutating func checkTheos() {
            let makefile = facts.block("theos.makefile") ?? ""
            let envTheos = facts.value("env.theos")
            let dirs = facts.all("theos.dir")
            var evidence: [DoctorCheck.Evidence] = [.init("THEOS (login shell)", envTheos ?? "not set")]
            if !makefile.isEmpty { evidence.append(.init("Makefile", makefile)) }
            if let control = facts.value("theos.control") { evidence.append(.init("control", control)) }
            guard let dir = dirs.first(where: { $0 == envTheos }) ?? dirs.first else {
                add(DoctorCheck(id: "theos", title: "Theos", status: .blocked, presence: .notInstalled, summary: "Theos is not installed (no $THEOS, ~/theos or /opt/theos).", evidence: evidence, affects: [.theosPackage],
                                nextSteps: ["Install Theos on the host following theos.dev/docs/installation."]))
                return
            }
            environment.theosDirectory = dir
            let sdkNames = (facts.block("theos.sdks.\(dir)") ?? "").split(separator: "\n").map(String.init).filter { $0.hasSuffix(".sdk") }
            evidence.append(.init("Theos folder", dir))
            evidence.append(.init("SDKs in \(dir)/sdks", sdkNames.isEmpty ? "none" : sdkNames.joined(separator: ", ")))
            if envTheos != dir {
                add(DoctorCheck(id: "theos", title: "Theos", status: .blocked, presence: .notInEnvironment(path: dir),
                                summary: "Theos is installed at \(dir), but THEOS is not set in the login shell builds use.", evidence: evidence, affects: [.theosPackage],
                                nextSteps: ["Add `export THEOS=\(dir)` to your login profile (for example ~/.zprofile) on the host."]))
                return
            }
            let required = Self.theosRequiredSDK(makefile)
            if let required, required != "latest", !sdkNames.contains(where: { $0.contains(required) }) {
                add(DoctorCheck(id: "theos", title: "Theos", status: .blocked, presence: .incompatible(reason: "SDK \(required) missing"),
                                summary: "The Makefile asks for the iOS \(required) SDK, which is not in \(dir)/sdks.", evidence: evidence, affects: [.theosPackage],
                                nextSteps: ["Add iPhoneOS\(required).sdk to \(dir)/sdks (for example from github.com/theos/sdks), or change TARGET in the Makefile."]))
                return
            }
            if sdkNames.isEmpty {
                add(DoctorCheck(id: "theos", title: "Theos", status: .blocked, presence: .incompatible(reason: "no SDKs"), summary: "Theos has no iOS SDKs in \(dir)/sdks.", evidence: evidence, affects: [.theosPackage],
                                nextSteps: ["Add an iOS SDK to \(dir)/sdks (for example from github.com/theos/sdks)."]))
                return
            }
            add(DoctorCheck(id: "theos", title: "Theos", status: .passed, presence: .found(path: dir), summary: "Theos at \(dir)" + (required.map { $0 == "latest" ? " (latest SDK)" : " with the iOS \($0) SDK" } ?? "") + ".",
                            evidence: evidence, affects: [.theosPackage]))
        }

        mutating func checkMake() {
            let versions = facts.keys(withPrefix: "make.version.").map { (String($0.dropFirst("make.version.".count)), facts.value($0) ?? "") }
            let onPath = facts.value("tool.make")
            var evidence = versions.map { DoctorCheck.Evidence($0.0, $0.1.isEmpty ? "no version" : $0.1) }
            if versions.isEmpty { evidence = [.init("make", "not found")] }
            func gnuVersion(_ text: String) -> Version? {
                guard text.hasPrefix("GNU Make ") else { return nil }
                return Version(String(text.dropFirst("GNU Make ".count)))
            }
            let good = versions.first { $0.0 == onPath && (gnuVersion($0.1) ?? Version("0")) >= Version("4.0") }
                ?? versions.first { (gnuVersion($0.1) ?? Version("0")) >= Version("4.0") }
            if let good {
                environment.gnuMake = good.0
                let note = good.0 == onPath ? "" : " Builds call it by path, because `make` on PATH is \(versions.first { $0.0 == onPath }?.1 ?? "missing")."
                add(DoctorCheck(id: "make", title: "GNU Make", status: .passed, presence: .found(path: good.0), summary: "\(good.1) at \(good.0).\(note)", evidence: evidence, affects: [.theosPackage]))
                return
            }
            if let onPath, let version = versions.first(where: { $0.0 == onPath }) {
                add(DoctorCheck(id: "make", title: "GNU Make", status: .blocked, presence: .incompatible(reason: version.1),
                                summary: "\(version.1.isEmpty ? "make" : version.1) at \(onPath) is too old; Theos needs GNU Make 4.0 or newer.", evidence: evidence, affects: [.theosPackage],
                                nextSteps: ["Install GNU Make 4 (on macOS: `brew install make`, then add $(brew --prefix)/opt/make/libexec/gnubin to PATH)."]))
                return
            }
            if let candidate = facts.value("candidate.make") ?? facts.value("candidate.gmake") {
                add(DoctorCheck(id: "make", title: "GNU Make", status: .blocked, presence: .notInEnvironment(path: candidate), summary: "GNU Make is at \(candidate), but not on the login shell's PATH.", evidence: evidence, affects: [.theosPackage],
                                nextSteps: ["Add \((candidate as NSString).deletingLastPathComponent) to PATH in your login profile."]))
                return
            }
            add(DoctorCheck(id: "make", title: "GNU Make", status: .blocked, presence: .notInstalled, summary: "make is not installed.", evidence: evidence, affects: [.theosPackage], nextSteps: ["Install GNU Make 4 or newer."]))
        }

        mutating func checkLdid() {
            if let path = facts.value("tool.ldid") {
                add(DoctorCheck(id: "ldid", title: "ldid", status: .passed, presence: .found(path: path), summary: "ldid at \(path).", evidence: [.init("ldid", path), .init("ldid -v", facts.value("ldid.version") ?? "no output")], affects: [.theosPackage]))
            } else if let candidate = facts.value("candidate.ldid") {
                add(DoctorCheck(id: "ldid", title: "ldid", status: .blocked, presence: .notInEnvironment(path: candidate), summary: "ldid is at \(candidate), but not on the login shell's PATH.", affects: [.theosPackage],
                                nextSteps: ["Add \((candidate as NSString).deletingLastPathComponent) to PATH in your login profile."]))
            } else {
                add(DoctorCheck(id: "ldid", title: "ldid", status: .blocked, presence: .notInstalled, summary: "ldid is not installed; Theos uses it to sign binaries.", affects: [.theosPackage],
                                nextSteps: ["Install ldid (on macOS: `brew install ldid`)."]))
            }
        }

        mutating func checkDpkgDeb() {
            if let path = facts.value("tool.dpkg-deb") {
                add(DoctorCheck(id: "dpkg-deb", title: "dpkg-deb", status: .passed, presence: .found(path: path), summary: facts.value("dpkg_deb.version") ?? path, evidence: [.init("dpkg-deb", path)], affects: [.theosPackage]))
            } else if let candidate = facts.value("candidate.dpkg-deb") {
                add(DoctorCheck(id: "dpkg-deb", title: "dpkg-deb", status: .blocked, presence: .notInEnvironment(path: candidate), summary: "dpkg-deb is at \(candidate), but not on the login shell's PATH.", affects: [.theosPackage],
                                nextSteps: ["Add \((candidate as NSString).deletingLastPathComponent) to PATH in your login profile."]))
            } else {
                add(DoctorCheck(id: "dpkg-deb", title: "dpkg-deb", status: .blocked, presence: .notInstalled, summary: "dpkg-deb is not installed; `make package` needs it to build the .deb.", affects: [.theosPackage],
                                nextSteps: ["Install dpkg (on macOS: `brew install dpkg`)."]))
            }
        }

        // MARK: Helpers

        static func json(_ text: String, opening: Character) -> Any? {
            guard let start = text.firstIndex(of: opening) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))
        }

        static func runtimeVersion(_ line: String) -> String {
            // "iOS 18.2 (18.2 - 22C150) - com.apple…"
            line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        }

        static func runtimeShortName(_ line: String) -> String {
            line.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
        }

        static func targetFrameworks(_ block: String) -> [String] {
            var result: [String] = []
            for line in block.split(separator: "\n") {
                guard let open = line.range(of: ">"), let close = line.range(of: "</", range: open.upperBound..<line.endIndex) else { continue }
                for framework in line[open.upperBound..<close.lowerBound].split(separator: ";") {
                    let value = framework.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty, !result.contains(value) { result.append(value) }
                }
            }
            return result
        }

        /// `net8.0`, `net8.0-ios` → 8. `netstandard2.0` / `net48` → nil.
        static func frameworkMajor(_ framework: String) -> Int? {
            guard framework.hasPrefix("net"), !framework.hasPrefix("netstandard"), !framework.hasPrefix("netcoreapp") else { return nil }
            let digits = framework.dropFirst(3).prefix { $0.isNumber || $0 == "." }
            guard digits.contains(".") else { return nil }
            return Int(digits.split(separator: ".").first ?? "")
        }

        static func emRequiredSDK(_ globalJSON: String?) -> Version {
            guard let globalJSON, let range = globalJSON.range(of: #""version":"([0-9.]+)""#, options: .regularExpression) else { return Version("10.0.100") }
            let match = globalJSON[range].replacingOccurrences(of: "\"version\":", with: "").replacingOccurrences(of: "\"", with: "")
            return Version(match)
        }

        /// `TARGET := iphone:clang:16.5:14.0` → "16.5"; `iphone:clang:latest:15.0` → "latest".
        static func theosRequiredSDK(_ makefile: String) -> String? {
            for line in makefile.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("TARGET") {
                guard let equals = line.firstIndex(of: "=") else { continue }
                let parts = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
                if parts.count >= 3 { return parts[2] }
            }
            return nil
        }
    }
}

/// Dotted numeric version for comparisons ("17.0" < "17.0.1" < "18").
public struct Version: Comparable, Sendable, Hashable {
    public let components: [Int]
    public let text: String

    public init(_ text: String) {
        self.text = text
        components = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) { hasher.combine(components.reversed().drop { $0 == 0 }.reversed() as [Int]) }
}
