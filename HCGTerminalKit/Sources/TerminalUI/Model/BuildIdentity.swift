import Foundation

/// What this installed app really is. Read from the bundle (`Info.plist`) and cross-checked
/// against what the composition root actually linked, so the interface never relies on a name.
public struct BuildIdentity: Hashable, Sendable {
    /// `HCGBuildVariant` from Info.plist (set per target: "standard" or "unleashed").
    public var declaredVariant: String
    /// The backend the composition root linked into this binary.
    public var linkedBackend: DistributionBuild
    public var version: String
    public var buildNumber: String
    /// `HCGSourceRevision`, stamped from git during the build ("unknown" if git was unavailable).
    public var sourceRevision: String
    public var bundleIdentifier: String
    public var displayName: String

    public init(
        declaredVariant: String, linkedBackend: DistributionBuild, version: String, buildNumber: String,
        sourceRevision: String, bundleIdentifier: String, displayName: String
    ) {
        self.declaredVariant = declaredVariant
        self.linkedBackend = linkedBackend
        self.version = version
        self.buildNumber = buildNumber
        self.sourceRevision = sourceRevision
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    /// Reads the identity from an Info.plist dictionary.
    public static func from(infoDictionary info: [String: Any], linkedBackend: DistributionBuild) -> BuildIdentity {
        func string(_ key: String) -> String {
            guard let value = info[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else { return "unknown" }
            return value
        }
        return BuildIdentity(
            declaredVariant: string("HCGBuildVariant"),
            linkedBackend: linkedBackend,
            version: string("CFBundleShortVersionString"),
            buildNumber: string("CFBundleVersion"),
            sourceRevision: string("HCGSourceRevision"),
            bundleIdentifier: string("CFBundleIdentifier"),
            displayName: (info["CFBundleDisplayName"] as? String) ?? string("CFBundleName")
        )
    }

    public static func current(linkedBackend: DistributionBuild, bundle: Bundle = .main) -> BuildIdentity {
        from(infoDictionary: bundle.infoDictionary ?? [:], linkedBackend: linkedBackend)
    }

    /// The variant the user should be told about: always what is linked, never what is named.
    public var variantLabel: String {
        switch linkedBackend {
        case .standard: "Standard (no Unleashed backend in this build)"
        case .unleashed: "Unleashed (backend included)"
        }
    }

    public var versionLabel: String { "\(version) (\(buildNumber))" }

    /// Inconsistencies between the bundle's declared identity and the linked code. Any entry here
    /// means the build was assembled from mismatched settings and should not be distributed.
    public var problems: [String] {
        var problems: [String] = []
        switch declaredVariant {
        case DistributionBuild.standard.rawValue, DistributionBuild.unleashed.rawValue:
            if declaredVariant != linkedBackend.rawValue {
                problems.append("Info.plist declares the \(declaredVariant) variant, but the \(linkedBackend.rawValue) backend is linked.")
            }
        default:
            problems.append("Info.plist does not declare a build variant (HCGBuildVariant is \(declaredVariant)).")
        }
        let unleashedBundle = bundleIdentifier.hasSuffix(".unleashed")
        if unleashedBundle != (linkedBackend == .unleashed) {
            problems.append("Bundle identifier \(bundleIdentifier) does not match the linked \(linkedBackend.rawValue) backend.")
        }
        let unleashedName = displayName.localizedCaseInsensitiveContains("unleashed")
        if unleashedName && linkedBackend != .unleashed {
            problems.append("The app is named “\(displayName)” but does not contain the Unleashed backend.")
        }
        return problems
    }

    /// Plain-text summary for the `version` built-in and log exports.
    public var summaryLines: [String] {
        [
            "Variant:   \(variantLabel)",
            "Version:   \(versionLabel)",
            "Revision:  \(sourceRevision)",
            "Bundle ID: \(bundleIdentifier)",
        ] + problems.map { "WARNING:   \($0)" }
    }
}
