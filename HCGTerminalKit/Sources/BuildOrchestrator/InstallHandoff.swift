import DeveloperWorkspace
import Foundation
import TerminalCore

/// A Simulator on the build host.
public struct SimulatorDevice: Codable, Sendable, Hashable, Identifiable {
    public var udid: String
    public var name: String
    /// e.g. "iOS 26.1".
    public var runtime: String
    public var runtimeVersion: String
    public var state: String
    public var isBooted: Bool { state == "Booted" }
    public var id: String { udid }
}

/// A physical device the build host can see through `devicectl` (connected or paired).
public struct HostVisibleDevice: Codable, Sendable, Hashable, Identifiable {
    public var udid: String
    public var name: String
    public var osVersion: String?
    public var connection: String?
    public var id: String { udid }
}

/// How an artifact is signed, read on the host with `codesign` and its embedded profile.
public struct SigningInspection: Codable, Sendable, Hashable {
    public var isSigned: Bool
    public var authority: String?
    public var teamIdentifier: String?
    public var profile: ProvisioningProfileInfo?
    public var codesignOutput: String
}

/// What the user can do next with an artifact, and why other options are not offered.
public struct InstallOptions: Sendable, Equatable {
    public enum Option: Sendable, Equatable, Identifiable {
        /// Install and launch in a Simulator on the build host.
        case simulator(SimulatorDevice, host: String)
        /// Install on a device the Mac can see, with `xcrun devicectl`.
        case deviceThroughHost(HostVisibleDevice, host: String)
        /// Download the .deb and hand it to the device's package workflow.
        case jailbreakPackage
        /// Download (and share) only.
        case download

        public var id: String {
            switch self {
            case .simulator(let device, _): "sim-\(device.udid)"
            case .deviceThroughHost(let device, _): "dev-\(device.udid)"
            case .jailbreakPackage: "deb"
            case .download: "download"
            }
        }
    }

    public var options: [Option]
    /// Where the product can run (desktop products, device builds).
    public var compatibility: [String]
    /// Plain statements about methods that are not offered, and why.
    public var notOffered: [String]
}

/// Read-only inspection scripts on the build host.
public enum InstallInspection {
    /// `xcrun simctl list devices available -j`.
    public static let simulatorsCommand = RemoteShell.login("xcrun simctl list devices available -j 2>/dev/null")

    public static func parseSimulators(_ json: Data) -> [SimulatorDevice] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [SimulatorDevice] = []
        for (runtimeID, list) in devices {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-1 → iOS 26.1
            guard let suffix = runtimeID.split(separator: ".").last else { continue }
            let parts = suffix.split(separator: "-").map(String.init)
            guard let platform = parts.first, ["iOS", "iPadOS"].contains(platform) else { continue }
            let version = parts.dropFirst().joined(separator: ".")
            for device in list where (device["isAvailable"] as? Bool) ?? true {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                result.append(SimulatorDevice(udid: udid, name: name, runtime: "\(platform) \(version)", runtimeVersion: version, state: device["state"] as? String ?? "Shutdown"))
            }
        }
        return result.sorted { ($0.isBooted ? 0 : 1, Version($1.runtimeVersion), $0.name) < ($1.isBooted ? 0 : 1, Version($0.runtimeVersion), $1.name) }
    }

    /// Signing details of an app bundle or an .ipa on the host. Never exports keys.
    public static func signingCommand(path: String) -> String {
        let p = ShellQuote.quote(path)
        return RemoteShell.login("""
        t=""; a=\(p)
        case "$a" in *.ipa) t=$(mktemp -d "${TMPDIR:-/tmp}/hcg-ipa.XXXXXX") && unzip -q -o "$a" 'Payload/*' -d "$t" 2>/dev/null; a=$(ls -d "$t"/Payload/*.app 2>/dev/null | head -1) ;; *.xcarchive) a=$(ls -d "$a"/Products/Applications/*.app 2>/dev/null | head -1) ;; esac
        printf 'BEGIN\\tcodesign\\n'; codesign -dv --verbose=2 "$a" 2>&1 | head -30; printf '\\nEND\\tcodesign\\n'
        if [ -f "$a/embedded.mobileprovision" ]; then
          f=$(mktemp "${TMPDIR:-/tmp}/hcg-prof.XXXXXX")
          if security cms -D -i "$a/embedded.mobileprovision" > "$f" 2>/dev/null; then
            x() { plutil -extract "$1" raw -o - "$f" 2>/dev/null; }
            printf 'PROFILE\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$(x Name)" "$(x TeamIdentifier.0)" "$(x ExpirationDate)" "$(x Entitlements.application-identifier)" "$(x ProvisionsAllDevices)" "$(x Entitlements.get-task-allow)" "$(plutil -extract ProvisionedDevices json -o - "$f" 2>/dev/null | tr -d '[]" \\n')" embedded
          fi
          rm -f "$f"
        fi
        [ -n "$t" ] && rm -rf "$t"
        printf 'K\\tprobe.done\\t1\\n'
        """)
    }

    public static func parseSigning(_ output: String) -> SigningInspection {
        let facts = DoctorFacts.parse(output)
        let codesign = facts.block("codesign") ?? ""
        func field(_ name: String) -> String? {
            codesign.split(separator: "\n").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let unsigned = codesign.contains("not signed at all") || codesign.isEmpty
        let authority = field("Authority")
        let team = field("TeamIdentifier").flatMap { $0 == "not set" ? nil : $0 }
        return SigningInspection(isSigned: !unsigned && (authority != nil || codesign.contains("Signature=adhoc")), authority: authority ?? (codesign.contains("Signature=adhoc") ? "ad hoc" : nil),
                                 teamIdentifier: team, profile: facts.profiles.first, codesignOutput: codesign)
    }

    /// Devices the Mac sees with `devicectl` (Xcode 15+). JSON written to a temporary file.
    public static let devicesCommand = RemoteShell.login("t=$(mktemp \"${TMPDIR:-/tmp}/hcg-dev.XXXXXX\") && xcrun devicectl list devices --json-output \"$t\" >/dev/null 2>&1; cat \"$t\" 2>/dev/null; rm -f \"$t\"")

    public static func parseDevices(_ json: Data) -> [HostVisibleDevice] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any]
            let properties = device["deviceProperties"] as? [String: Any]
            let connection = device["connectionProperties"] as? [String: Any]
            guard let udid = hardware?["udid"] as? String else { return nil }
            return HostVisibleDevice(
                udid: udid, name: properties?["name"] as? String ?? "Device", osVersion: properties?["osVersionNumber"] as? String,
                connection: [connection?["tunnelState"] as? String, connection?["pairingState"] as? String].compactMap { $0 }.joined(separator: ", ")
            )
        }
    }
}

/// Decides which installation methods an artifact supports. Pure: every rule is testable.
public enum InstallPlanner {
    public static func options(
        for artifact: JobArtifact,
        buildHost: String,
        hostEnvironment: DoctorEnvironment?,
        simulators: [SimulatorDevice] = [],
        signing: SigningInspection? = nil,
        hostDevices: [HostVisibleDevice] = [],
        appSupportsLocalPackageInstall: Bool = false
    ) -> InstallOptions {
        var options: [InstallOptions.Option] = [.download]
        var compatibility: [String] = []
        var notOffered: [String] = []
        let neverAutomatic = "HCG Terminal never installs, publishes or uploads anything on its own; every install below needs your confirmation."

        switch artifact.kind {
        case .simulatorApp:
            let minimum = artifact.minimumOS.map(Version.init)
            let suitable = simulators.filter { minimum == nil || Version($0.runtimeVersion) >= minimum! }
            if hostEnvironment?.isMac == false {
                notOffered.append("Simulator apps run only in the iOS Simulator on a Mac.")
            } else if suitable.isEmpty {
                notOffered.append(simulators.isEmpty
                    ? "No iOS Simulator is available on \(buildHost). Install a Simulator runtime in Xcode → Settings → Components."
                    : "No Simulator on \(buildHost) runs iOS \(artifact.minimumOS ?? "") or newer.")
            } else {
                options += suitable.prefix(12).map { .simulator($0, host: buildHost) }
            }
            compatibility.append("Runs only in the iOS Simulator (built for iphonesimulator). It cannot be installed on an iPhone.")

        case .deviceApp, .ipa, .xcarchive:
            if artifact.kind == .xcarchive {
                notOffered.append("An archive is not installable as is. Export a signed IPA from it (for example with HCG Executable Maker's IPA output).")
                break
            }
            guard let signing else {
                notOffered.append("Signing has not been inspected yet.")
                break
            }
            guard signing.isSigned else {
                notOffered.append("The app is not signed, so iOS will not install it on a device (except on a jailbroken device with signature checks disabled, which HCG Terminal does not set up).")
                break
            }
            guard let profile = signing.profile else {
                notOffered.append("The app has no embedded provisioning profile, so it cannot be installed on a device.")
                break
            }
            if profile.isExpired() {
                notOffered.append("Its provisioning profile “\(profile.name)” expired on \(profile.expiration.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "an earlier date").")
                break
            }
            switch profile.kind {
            case .appStore:
                notOffered.append("It is signed for App Store distribution: it installs only through TestFlight or the App Store. HCG Terminal never uploads builds.")
            case .enterprise:
                compatibility.append("Enterprise-signed: installs on any device that trusts team \(profile.teamID).")
                options += hostDevices.map { .deviceThroughHost($0, host: buildHost) }
            case .development, .adHoc:
                compatibility.append("\(profile.kind.rawValue)-signed for \(profile.deviceUDIDs.count) registered device(s).")
                let registered = hostDevices.filter { device in profile.deviceUDIDs.contains { $0.caseInsensitiveCompare(device.udid) == .orderedSame } }
                options += registered.map { .deviceThroughHost($0, host: buildHost) }
                let unregistered = hostDevices.filter { !registered.contains($0) }
                if !unregistered.isEmpty {
                    notOffered.append("Not offered for \(unregistered.map(\.name).joined(separator: ", ")): not in the profile's device list.")
                }
                notOffered.append("This iPhone cannot read its own device ID, so HCG Terminal cannot tell whether it is in the profile. Connect it to \(buildHost) (cable or network pairing in Xcode) to install through the Mac.")
            }
            if hostDevices.isEmpty, profile.kind != .appStore {
                notOffered.append("No device is connected to or paired with \(buildHost) (checked with `xcrun devicectl list devices`).")
            }

        case .deb:
            compatibility.append("A Debian package for a jailbroken device.")
            if appSupportsLocalPackageInstall {
                options.append(.jailbreakPackage)
            } else {
                notOffered.append("Installing packages needs HCG Terminal Unleashed with a working local shell and dpkg on a jailbroken device. Download it and open it in your package manager (Sileo, Zebra, Filza) instead.")
            }

        case .macApp:
            compatibility.append(desktopCompatibility(artifact: artifact, buildHost: buildHost, environment: hostEnvironment))
            notOffered.append("macOS apps are not installed from HCG Terminal. It is on \(buildHost) at \(artifact.sourcePath).")

        case .dotnetOutput, .executable, .other:
            compatibility.append(desktopCompatibility(artifact: artifact, buildHost: buildHost, environment: hostEnvironment))
        }
        notOffered.append(neverAutomatic)
        return InstallOptions(options: options, compatibility: compatibility, notOffered: notOffered)
    }

    /// Which desktop host the product runs on, from its runtime identifier or the build host.
    static func desktopCompatibility(artifact: JobArtifact, buildHost: String, environment: DoctorEnvironment?) -> String {
        let path = artifact.sourcePath
        // .NET runtime identifiers in the output path, e.g. bin/Release/net8.0/osx-arm64/.
        let rids = ["win-x64", "win-arm64", "win-x86", "osx-arm64", "osx-x64", "linux-x64", "linux-arm64", "linux-musl-x64"]
        if let rid = rids.first(where: { path.contains("/\($0)/") }) {
            let os = rid.hasPrefix("win") ? "Windows" : rid.hasPrefix("osx") ? "macOS" : "Linux"
            let arch = rid.split(separator: "-").last.map(String.init) ?? ""
            return "Runs on \(os) (\(arch)) hosts (runtime identifier \(rid))."
        }
        if artifact.kind == .dotnetOutput {
            return "Framework-dependent .NET output: runs on any host with a matching .NET runtime installed."
        }
        let os = environment?.operatingSystem ?? "the build host's system"
        let arch = environment?.architecture ?? "its architecture"
        var text = "Built on \(buildHost) for \(os) (\(arch)); it runs there and on compatible hosts."
        if artifact.kind == .macApp, let minimum = artifact.minimumOS { text += " Needs macOS \(minimum) or newer." }
        return text
    }
}

/// The steps of an install, each one confirmed by its own exit status.
public enum InstallCommands {
    /// Boots (if needed), installs and launches in a Simulator. Prints `HCG_INSTALLED` after a
    /// successful install and `HCG_LAUNCHED <pid>` after a successful launch.
    public static func simulator(appPath: String, udid: String, bundleID: String?) -> String {
        let app = ShellQuote.quote(appPath), device = ShellQuote.quote(udid)
        var script = """
        set -u
        echo "Booting Simulator…"
        if ! out=$(xcrun simctl boot \(device) 2>&1); then
          case "$out" in *Booted*) echo "Simulator already booted" ;; *) echo "$out"; exit 1 ;; esac
        fi
        open -a Simulator --args -CurrentDeviceUDID \(device) >/dev/null 2>&1 || echo "(The Simulator window could not be opened; the app still installs.)"
        echo "Installing…"
        xcrun simctl install \(device) \(app) || exit 2
        echo HCG_INSTALLED
        """
        if let bundleID {
            script += """

            echo "Launching \(bundleID)…"
            out=$(xcrun simctl launch \(device) \(ShellQuote.quote(bundleID)) 2>&1); rc=$?
            echo "$out"
            [ $rc -eq 0 ] || exit 3
            echo "HCG_LAUNCHED ${out##*: }"
            """
        }
        return RemoteShell.login(script)
    }

    /// Installs on a device the Mac sees. Prints `HCG_INSTALLED` only after devicectl succeeds.
    public static func device(appPath: String, udid: String) -> String {
        let app = ShellQuote.quote(appPath), device = ShellQuote.quote(udid)
        return RemoteShell.login("""
        a=\(app); t=""
        case "$a" in *.ipa) t=$(mktemp -d "${TMPDIR:-/tmp}/hcg-ipa.XXXXXX") && unzip -q -o "$a" 'Payload/*' -d "$t" && a=$(ls -d "$t"/Payload/*.app | head -1) ;; esac
        echo "Installing on \(udid) with devicectl…"
        xcrun devicectl device install app --device \(device) "$a"; rc=$?
        [ -n "$t" ] && rm -rf "$t"
        [ $rc -eq 0 ] && echo HCG_INSTALLED
        exit $rc
        """)
    }

    public enum Outcome: Sendable, Equatable {
        case installed
        case installedAndLaunched(pid: String)
        case failed(exitStatus: Int32)
    }

    /// Reads the outcome from the markers; nothing is assumed from a zero exit alone.
    public static func outcome(output: String, exitStatus: Int32) -> Outcome {
        let lines = output.split(separator: "\n").map(String.init)
        let installed = lines.contains("HCG_INSTALLED")
        if let launched = lines.last(where: { $0.hasPrefix("HCG_LAUNCHED ") }), installed {
            return .installedAndLaunched(pid: String(launched.dropFirst("HCG_LAUNCHED ".count)))
        }
        if installed { return .installed }
        return .failed(exitStatus: exitStatus)
    }
}
