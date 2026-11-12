import Foundation
import TerminalCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A layered, read-only description of where HCG Terminal is running. Each layer is observed
/// separately and none is inferred from another:
///
/// 1. **Build** — which variant this binary is and whether the Unleashed backend is linked.
/// 2. **Device** — operating system, hardware model and CPU architecture.
/// 3. **Bootstrap** — evidence of a jailbreak userland (rootless, rootful or relocated roots)
///    and the tools resolved inside it. *Indicators found* is never the same as *usable*.
/// 4. **Process** — this app's identity and the restrictions observed on it (sandbox, install
///    route).
/// 5. **Operations** — what actually happened when something was used or explicitly tested.
public struct EnvironmentAssessment: Hashable, Sendable {
    public struct Build: Hashable, Sendable {
        public var variant: String
        public var backendLinked: Bool
        /// Components the linked backend reports (empty when not linked).
        public var backendComponents: [String]
        public init(variant: String, backendLinked: Bool, backendComponents: [String] = []) {
            self.variant = variant
            self.backendLinked = backendLinked
            self.backendComponents = backendComponents
        }
    }

    public struct Device: Hashable, Sendable {
        public var operatingSystem: String
        public var kernel: String
        /// Hardware model, e.g. `iPhone14,2` (simulator: the simulated model).
        public var model: String
        /// `arm64`, `arm64e`, `x86_64`, …
        public var architecture: String
        public var isSimulator: Bool
        public init(operatingSystem: String, kernel: String, model: String, architecture: String, isSimulator: Bool) {
            self.operatingSystem = operatingSystem
            self.kernel = kernel
            self.model = model
            self.architecture = architecture
            self.isSimulator = isSimulator
        }
    }

    public enum Layout: String, Hashable, Sendable {
        case rootless
        case rootful
        case relocated
        case custom

        public var label: String {
            switch self {
            case .rootless: "Rootless (/var/jb)"
            case .rootful: "Rootful (system root)"
            case .relocated: "Relocated bootstrap root"
            case .custom: "Custom root (set by you)"
            }
        }
    }

    /// One checked path that could indicate a jailbreak userland.
    public struct Indicator: Hashable, Sendable {
        public enum Strength: String, Hashable, Sendable {
            /// Created by a bootstrap itself (e.g. `.procursus_strapped`, the dpkg database).
            case strong
            /// Commonly present but easy to have for other reasons (an app bundle name).
            case weak
        }
        public var path: String
        public var layout: Layout
        public var strength: Strength
        public var probe: PathProbe
        public init(path: String, layout: Layout, strength: Strength, probe: PathProbe) {
            self.path = path
            self.layout = layout
            self.strength = strength
            self.probe = probe
        }
    }

    /// A candidate bootstrap root and what was observed there.
    public struct Root: Hashable, Sendable {
        public var path: String
        /// Where the path really points (symlinks resolved), if it could be resolved.
        public var resolvedPath: String?
        public var layout: Layout
        public var probe: PathProbe
        public init(path: String, resolvedPath: String?, layout: Layout, probe: PathProbe) {
            self.path = path
            self.resolvedPath = resolvedPath
            self.layout = layout
            self.probe = probe
        }
    }

    /// Verdict on jailbreak *indicators* only. Says nothing about whether this app can use them.
    public enum IndicatorVerdict: Hashable, Sendable {
        /// Not checked (the standard build does not look).
        case notChecked(String)
        case found(strong: Int, weak: Int)
        /// None visible, and the process is restricted enough that their absence proves
        /// nothing. The device may or may not be jailbroken.
        case notObservable(String)
        /// None found by a process that could see the filesystem. Still not proof.
        case noneFound

        public var label: String {
            switch self {
            case .notChecked: "Not checked"
            case .found(let strong, let weak): "Indicators found (\(strong) strong, \(weak) weak)"
            case .notObservable: "Unknown — not observable from this app"
            case .noneFound: "None found"
            }
        }
    }

    public struct Bootstrap: Hashable, Sendable {
        public var roots: [Root]
        public var indicators: [Indicator]
        /// Tool name → resolved executable path, e.g. `sh` → `/private/preboot/…/procursus/bin/sh`.
        public var resolvedTools: [String: String]
        public var verdict: IndicatorVerdict
        public init(roots: [Root], indicators: [Indicator], resolvedTools: [String: String], verdict: IndicatorVerdict) {
            self.roots = roots
            self.indicators = indicators
            self.resolvedTools = resolvedTools
            self.verdict = verdict
        }

        public static func notChecked(_ reason: String) -> Bootstrap {
            Bootstrap(roots: [], indicators: [], resolvedTools: [:], verdict: .notChecked(reason))
        }
    }

    public enum InstallRoute: String, Hashable, Sendable {
        case testFlight
        case appStore
        case developmentOrAdHoc
        case unknown

        public var label: String {
            switch self {
            case .testFlight: "TestFlight (sandboxed)"
            case .appStore: "App Store (sandboxed)"
            case .developmentOrAdHoc: "Xcode / ad hoc profile (sandboxed)"
            case .unknown: "Unknown (no provisioning profile or receipt found)"
            }
        }
    }

    public struct Process: Hashable, Sendable {
        public var userID: UInt32
        public var effectiveUserID: UInt32
        public var groupID: UInt32
        public var home: String
        public var bundlePath: String
        /// The home directory is an app data container (`…/Containers/Data/Application/…`).
        public var containerized: Bool
        public var installRoute: InstallRoute
        /// Paths the system refused to let this process inspect.
        public var deniedProbes: [String]
        public init(userID: UInt32, effectiveUserID: UInt32, groupID: UInt32, home: String, bundlePath: String, containerized: Bool, installRoute: InstallRoute, deniedProbes: [String]) {
            self.userID = userID
            self.effectiveUserID = effectiveUserID
            self.groupID = groupID
            self.home = home
            self.bundlePath = bundlePath
            self.containerized = containerized
            self.installRoute = installRoute
            self.deniedProbes = deniedProbes
        }

        /// Whether the observed restrictions make missing evidence meaningless.
        public var restricted: Bool { containerized || !deniedProbes.isEmpty }
    }

    /// Whether this app can run a shell, decided only from what actually happened or what the
    /// read-only checks saw — separate from the indicator verdict.
    public enum ShellVerdict: Hashable, Sendable {
        case notIncluded
        case disabledByUser
        case verified(String)
        case permissionDenied(String)
        case availableUntested(String)
        case toolMissing(String)
        case unknown(String)

        public var label: String {
            switch self {
            case .notIncluded: "Not included in this build"
            case .disabledByUser: "Disabled by you"
            case .verified: "Verified: a shell ran"
            case .permissionDenied: "Permission denied"
            case .availableUntested: "Shell found, not yet run"
            case .toolMissing: "No shell found"
            case .unknown: "Unknown — not observable"
            }
        }
    }

    public struct Operation: Hashable, Sendable {
        public var name: String
        public var outcome: String
        public var succeeded: Bool
        public var date: Date
        public init(name: String, outcome: String, succeeded: Bool, date: Date = Date()) {
            self.name = name
            self.outcome = outcome
            self.succeeded = succeeded
            self.date = date
        }
    }

    public var build: Build
    public var device: Device
    public var bootstrap: Bootstrap
    public var process: Process
    public var operations: [Operation]
    public var shell: ShellVerdict
    public var generatedAt: Date

    public init(build: Build, device: Device, bootstrap: Bootstrap, process: Process, operations: [Operation], shell: ShellVerdict, generatedAt: Date = Date()) {
        self.build = build
        self.device = device
        self.bootstrap = bootstrap
        self.process = process
        self.operations = operations
        self.shell = shell
        self.generatedAt = generatedAt
    }

    /// Decides the indicator verdict from the indicators and the process restrictions.
    public static func verdict(indicators: [Indicator], process: Process) -> IndicatorVerdict {
        let strong = indicators.filter { $0.probe == .present && $0.strength == .strong }.count
        let weak = indicators.filter { $0.probe == .present && $0.strength == .weak }.count
        if strong + weak > 0 { return .found(strong: strong, weak: weak) }
        if process.restricted {
            let denied = process.deniedProbes.count
            let detail = denied > 0 ? "The system refused \(denied) of the checks. " : ""
            return .notObservable("\(detail)This app runs in an iOS sandbox, which hides most of the filesystem. A jailbreak may or may not be present; it is not visible from here.")
        }
        return .noneFound
    }

    /// Text for exports and the `capabilities` command.
    public var summaryLines: [String] {
        var lines = [
            "Build:     \(build.variant) · Unleashed backend \(build.backendLinked ? "linked" : "not included")",
            "Device:    \(device.model) · \(device.architecture) · \(device.operatingSystem)\(device.isSimulator ? " (Simulator)" : "")",
            "Process:   uid \(process.userID) euid \(process.effectiveUserID) · \(process.containerized ? "app container (sandboxed)" : "not in an app container") · install: \(process.installRoute.label)",
            "Bootstrap: \(bootstrap.verdict.label)",
        ]
        for root in bootstrap.roots where root.probe != .missing {
            lines.append("           \(root.layout.label): \(root.path)\(root.resolvedPath.map { $0 == root.path ? "" : " → \($0)" } ?? "") [\(root.probe.description)]")
        }
        for (tool, path) in bootstrap.resolvedTools.sorted(by: { $0.key < $1.key }) {
            lines.append("           \(tool): \(path)")
        }
        lines.append("Shell:     \(shell.label)")
        for operation in operations {
            lines.append("Operation: \(operation.name): \(operation.outcome)")
        }
        return lines
    }
}

/// Read-only observations of the device and this process.
public enum HostIdentity {
    public static func device() -> EnvironmentAssessment.Device {
        var name = utsname()
        var kernel = ProcessInfo.processInfo.operatingSystemVersionString
        var machine = "unknown"
        if uname(&name) == 0 {
            kernel = "\(field(name.sysname)) \(field(name.release))"
            machine = field(name.machine)
        }
        let environment = ProcessInfo.processInfo.environment
        let simulatorModel = environment["SIMULATOR_MODEL_IDENTIFIER"]
        #if os(iOS)
        let system = "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #elseif os(macOS)
        let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return EnvironmentAssessment.Device(
            operatingSystem: system,
            kernel: kernel,
            model: simulatorModel ?? hardwareModel() ?? machine,
            architecture: architecture() ?? machine,
            isSimulator: simulatorModel != nil
        )
    }

    public static func process(deniedProbes: [String], bundle: Bundle = .main) -> EnvironmentAssessment.Process {
        let home = NSHomeDirectory()
        return EnvironmentAssessment.Process(
            userID: UInt32(getuid()),
            effectiveUserID: UInt32(geteuid()),
            groupID: UInt32(getgid()),
            home: home,
            bundlePath: bundle.bundlePath,
            containerized: home.contains("/Containers/Data/Application/"),
            installRoute: installRoute(bundle: bundle),
            deniedProbes: deniedProbes
        )
    }

    static func installRoute(bundle: Bundle) -> EnvironmentAssessment.InstallRoute {
        if let receipt = bundle.appStoreReceiptURL, FileManager.default.fileExists(atPath: receipt.path) {
            return receipt.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
        }
        if bundle.path(forResource: "embedded", ofType: "mobileprovision") != nil { return .developmentOrAdHoc }
        return .unknown
    }

    private static func field<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    private static func hardwareModel() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }

    private static func architecture() -> String? {
        #if canImport(Darwin)
        var type: cpu_type_t = 0
        var subtype: cpu_subtype_t = 0
        var size = MemoryLayout<cpu_type_t>.size
        guard sysctlbyname("hw.cputype", &type, &size, nil, 0) == 0 else { return nil }
        size = MemoryLayout<cpu_subtype_t>.size
        _ = sysctlbyname("hw.cpusubtype", &subtype, &size, nil, 0)
        if type == CPU_TYPE_ARM64 { return subtype & ~Int32(bitPattern: 0xFF00_0000) == CPU_SUBTYPE_ARM64E ? "arm64e" : "arm64" }
        if type == CPU_TYPE_X86_64 { return "x86_64" }
        return "cputype \(type)"
        #else
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return nil
        #endif
        #endif
    }
}

/// The standard build's assessment: build, device and process layers only. It does not look
/// for jailbreak evidence at all.
public enum StandardEnvironmentAssessment {
    public static func make(variant: String) -> EnvironmentAssessment {
        EnvironmentAssessment(
            build: .init(variant: variant, backendLinked: false),
            device: HostIdentity.device(),
            bootstrap: .notChecked("The standard build does not include the Unleashed backend and does not look for a jailbreak."),
            process: HostIdentity.process(deniedProbes: []),
            operations: [],
            shell: .notIncluded
        )
    }
}

/// Bootstrap roots entered by the user for relocated installs. Stored locally; only read-only
/// probes are ever run against them.
public enum BootstrapRootPreference {
    public static let key = "hcg.terminal.customBootstrapRoots"

    public static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public static func save(_ roots: [String], _ defaults: UserDefaults = .standard) {
        let cleaned = roots.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") && $0 != "/" }
        defaults.set(Array(cleaned.prefix(4)), forKey: key)
    }
}
