import DeveloperWorkspace
import Foundation
import TerminalCore

/// The read-only probe Doctor runs on a host, and the facts it reports.
///
/// One POSIX `sh` script runs in the host user's **login shell** (`RemoteShell.login`), which is
/// the same environment every remote build job uses, so a tool Doctor finds is the tool the build
/// finds. The script only reads: it runs version queries, `command -v`, `df`, `xcodebuild -list`
/// / `-showBuildSettings` (with automatic package resolution off), `security find-identity` (names
/// and hashes only, never private keys) and decodes provisioning profiles to a temporary file that
/// it deletes. It installs nothing and changes no settings.
public enum DoctorProbe {
    /// Places tools are commonly installed outside a login shell's PATH. Used to tell "not
    /// installed" from "installed, but not found in this environment".
    static let knownLocations: [String: [String]] = [
        "dotnet": ["/usr/local/share/dotnet/dotnet", "/opt/homebrew/bin/dotnet", "/usr/local/bin/dotnet", "$HOME/.dotnet/dotnet", "/usr/share/dotnet/dotnet", "/usr/lib/dotnet/dotnet"],
        "make": ["/opt/homebrew/opt/make/libexec/gnubin/make", "/usr/local/opt/make/libexec/gnubin/make"],
        "gmake": ["/opt/homebrew/bin/gmake", "/usr/local/bin/gmake"],
        "ldid": ["/opt/homebrew/bin/ldid", "/usr/local/bin/ldid", "$HOME/theos/toolchain/linux/iphone/bin/ldid", "$HOME/theos/bin/ldid"],
        "dpkg-deb": ["/opt/homebrew/bin/dpkg-deb", "/usr/local/bin/dpkg-deb", "/usr/bin/dpkg-deb"],
        "swift": ["/usr/bin/swift", "$HOME/.swiftly/bin/swift", "/usr/share/swift/usr/bin/swift"],
        "git": ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"],
    ]

    /// Folders checked for an HCG Executable Maker source checkout when none is configured.
    public static let executableMakerCandidates = [
        "$HOME/HCG-Executable-Maker", "$HOME/hcg-executable-maker", "$HOME/Developer/HCG-Executable-Maker",
        "$HOME/Developer/hcg-executable-maker", "$HOME/Projects/HCG-Executable-Maker", "$HOME/src/HCG-Executable-Maker",
        "$HOME/Documents/GitHub/HCG-Executable-Maker", "$HOME/GitHub/HCG-Executable-Maker",
    ]

    /// The probe script. `scheme` limits the build-settings query to one scheme.
    public static func script(projectPath: String, project: ProjectKind?, scheme: String?, executableMakerPath: String?, timeoutSeconds: Int = 60) -> String {
        var s = """
        LC_ALL=C; export LC_ALL
        k() { printf 'K\\t%s\\t%s\\n' "$1" "$2"; }
        blk() { printf 'BEGIN\\t%s\\n' "$1"; }
        endblk() { printf '\\nEND\\t%s\\n' "$1"; }
        lim() { "$@" & hp=$!; ( sleep \(timeoutSeconds); kill -TERM $hp 2>/dev/null ) >/dev/null 2>&1 & hw=$!; wait $hp; hr=$?; kill $hw 2>/dev/null; return $hr; }
        tool() { k "tool.$1" "$(command -v "$1" 2>/dev/null)"; }
        cand() { n=$1; shift; for c in "$@"; do if [ -x "$c" ]; then k "candidate.$n" "$c"; fi; done; }
        k probe.version 1
        k os.kernel "$(uname -s)"
        k os.release "$(uname -r)"
        k os.arch "$(uname -m)"
        if command -v sw_vers >/dev/null 2>&1; then k os.product "macOS $(sw_vers -productVersion 2>/dev/null)"; k os.build "$(sw_vers -buildVersion 2>/dev/null)"; elif [ -r /etc/os-release ]; then k os.product "$(. /etc/os-release; printf '%s' "$PRETTY_NAME")"; fi
        k env.shell "${SHELL:-}"
        k env.path "$PATH"
        k env.user "$(id -un 2>/dev/null)"
        k env.developer_dir "${DEVELOPER_DIR:-}"
        k env.theos "${THEOS:-}"
        if cd \(RemoteShell.quotePath(projectPath)) 2>/dev/null; then k project.dir "$(pwd)"; else k project.dir ""; k project.error "cannot open the project folder"; fi
        k disk.project_kb "$(df -Pk . 2>/dev/null | awk 'NR==2{print $4}')"
        k disk.home_kb "$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
        k disk.mount "$(df -Pk . 2>/dev/null | awk 'NR==2{print $6}')"
        for t in xcodebuild xcrun xcode-select swift dotnet make gmake ldid dpkg-deb git security codesign plutil perl; do tool "$t"; done

        """
        for (name, locations) in knownLocations.sorted(by: { $0.key < $1.key }) {
            s += "cand \(name) " + locations.map { "\"\($0)\"" }.joined(separator: " ") + "\n"
        }
        // Xcode
        s += """
        if command -v xcode-select >/dev/null 2>&1; then
          k xcode.select "$(xcode-select -p 2>&1)"
          for a in /Applications/Xcode*.app; do [ -d "$a" ] && k xcode.app "$a"; done
          blk xcode.version; lim xcodebuild -version 2>&1 | head -5; endblk xcode.version
          lim xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; k xcode.first_launch_status "$?"
          for sdk in iphoneos iphonesimulator macosx; do k "sdk.$sdk" "$(lim xcrun --sdk $sdk --show-sdk-version 2>/dev/null)"; done
          blk simulator.runtimes; lim xcrun simctl list runtimes available 2>/dev/null | grep -E '^(iOS|iPadOS) ' | head -20; endblk simulator.runtimes
        fi

        """
        // Project-specific Xcode queries.
        let container: String? = switch project {
        case .xcodeProject(let name)?: "-project \(ShellQuote.quote(name))"
        case .xcodeWorkspace(let name)?: "-workspace \(ShellQuote.quote(name))"
        default: nil
        }
        if let container {
            s += "if command -v xcodebuild >/dev/null 2>&1; then\n"
            s += "  blk xcode.list; lim xcodebuild -list -json \(container) -disableAutomaticPackageResolution 2>&1 | head -400; endblk xcode.list\n"
            if let scheme, !scheme.isEmpty {
                s += "  blk xcode.settings; lim xcodebuild -showBuildSettings -json \(container) -scheme \(ShellQuote.quote(scheme)) -disableAutomaticPackageResolution 2>&1 | head -20000; endblk xcode.settings\n"
            }
            s += "fi\n"
        }
        // .NET
        s += """
        if command -v dotnet >/dev/null 2>&1; then
          blk dotnet.version; lim dotnet --version 2>&1 | head -12; endblk dotnet.version
          blk dotnet.sdks; lim dotnet --list-sdks 2>&1 | head -30; endblk dotnet.sdks
        fi
        if [ -f global.json ]; then blk dotnet.global_json; head -c 4000 global.json; endblk dotnet.global_json; fi
        blk dotnet.frameworks; for f in *.csproj */*.csproj */*/*.csproj *.fsproj */*.fsproj; do [ -f "$f" ] && grep -hoE '<TargetFrameworks?>[^<]*</TargetFrameworks?>' "$f" | sed "s|^|$f	|"; done 2>/dev/null | head -50; endblk dotnet.frameworks

        """
        // Theos, make, ldid
        s += """
        if [ -f Makefile ]; then
          blk theos.makefile; grep -E '^[[:space:]]*(TARGET|ARCHS|THEOS_PACKAGE_SCHEME|INSTALL_TARGET_PROCESSES|THEOS_DEVICE_IP)[[:space:]]*[:?+]?=|include[[:space:]]+\\$\\(THEOS' Makefile | head -20; endblk theos.makefile
          [ -f control ] && k theos.control "$(grep -E '^(Package|Version|Architecture):' control | tr '\\n' ' ')"
        fi
        for d in "${THEOS:-}" "$HOME/theos" /opt/theos; do
          if [ -n "$d" ] && [ -d "$d/makefiles" ]; then k theos.dir "$d"; blk "theos.sdks.$d"; ls -1 "$d/sdks" 2>/dev/null | head -40; endblk "theos.sdks.$d"; fi
        done
        for m in make gmake /opt/homebrew/opt/make/libexec/gnubin/make /usr/local/opt/make/libexec/gnubin/make; do
          p=$(command -v "$m" 2>/dev/null); [ -n "$p" ] && k "make.version.$p" "$("$p" --version 2>/dev/null | head -1)"
        done
        if command -v ldid >/dev/null 2>&1; then k ldid.version "$(lim ldid -v 2>&1 | head -1)"; fi
        if command -v dpkg-deb >/dev/null 2>&1; then k dpkg_deb.version "$(dpkg-deb --version 2>/dev/null | head -1)"; fi
        if command -v swift >/dev/null 2>&1 && [ -f Package.swift ]; then blk swift.version; lim swift --version 2>&1 | head -3; endblk swift.version; fi

        """
        // Signing (Apple). Identity names and hashes only.
        s += """
        if command -v security >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then
          blk signing.identities; lim security find-identity -v -p codesigning 2>&1 | head -60; endblk signing.identities
          n=0
          for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
            [ -f "$f" ] || continue; n=$((n+1)); [ $n -gt 80 ] && break
            t=$(mktemp "${TMPDIR:-/tmp}/hcg-doctor.XXXXXX") || break
            if security cms -D -i "$f" > "$t" 2>/dev/null; then
              x() { plutil -extract "$1" raw -o - "$t" 2>/dev/null; }
              printf 'PROFILE\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$(x Name)" "$(x TeamIdentifier.0)" "$(x ExpirationDate)" "$(x Entitlements.application-identifier)" "$(x ProvisionsAllDevices)" "$(x Entitlements.get-task-allow)" "$(plutil -extract ProvisionedDevices json -o - "$t" 2>/dev/null | tr -d '[]" \\n')" "$(basename "$f")"
            fi
            rm -f "$t"
          done
        fi

        """
        // HCG Executable Maker (source checkout with the mobile-build CLI).
        var candidates = executableMakerCandidates
        if let executableMakerPath, !executableMakerPath.isEmpty {
            candidates.insert(executableMakerPath.hasPrefix("~/") ? "$HOME/" + executableMakerPath.dropFirst(2) : executableMakerPath, at: 0)
        }
        s += "for d in " + candidates.map { $0.hasPrefix("$HOME") ? "\"$HOME\"\(ShellQuote.quote(String($0.dropFirst(5))))" : ShellQuote.quote($0) }.joined(separator: " ") + "; do\n"
        s += """
          if [ -f "$d/\(ExecutableMakerCLI.relativeScript)" ]; then k em.path "$d"; k em.revision "$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"; [ -f "$d/global.json" ] && k em.global_json "$(tr -d '\\n ' < "$d/global.json" | head -c 300)"; break; fi
        done
        [ -d "/Applications/HCG Executable Maker.app" ] && k em.app "/Applications/HCG Executable Maker.app"
        k probe.done 1

        """
        return s
    }

    /// The probe wrapped for sending: the user's login shell, like every build job.
    public static func command(projectPath: String, project: ProjectKind?, scheme: String?, executableMakerPath: String?) -> String {
        RemoteShell.login(script(projectPath: projectPath, project: project, scheme: scheme, executableMakerPath: executableMakerPath))
    }
}

/// The raw facts from one probe run.
public struct DoctorFacts: Sendable, Equatable {
    public var values: [String: [String]] = [:]
    public var blocks: [String: String] = [:]
    public var profiles: [ProvisioningProfileInfo] = []

    public init() {}

    public func value(_ key: String) -> String? {
        values[key]?.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func all(_ key: String) -> [String] { (values[key] ?? []).filter { !$0.isEmpty } }

    public func block(_ key: String) -> String? {
        blocks[key].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Keys with a prefix, e.g. every `make.version.<path>`.
    public func keys(withPrefix prefix: String) -> [String] { values.keys.filter { $0.hasPrefix(prefix) }.sorted() }

    /// True when the probe ran to the end (a timeout or a broken shell stops it early).
    public var isComplete: Bool { value("probe.done") == "1" }

    public static func parse(_ output: String) -> DoctorFacts {
        var facts = DoctorFacts()
        var openBlock: String?
        var blockLines: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let name = openBlock {
                if line.hasPrefix("END\t"), String(line.dropFirst(4)) == name {
                    facts.blocks[name] = blockLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    openBlock = nil
                    blockLines = []
                } else {
                    blockLines.append(line)
                }
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "K" where fields.count >= 3:
                facts.values[fields[1], default: []].append(fields[2...].joined(separator: "\t"))
            case "BEGIN" where fields.count >= 2:
                openBlock = fields[1...].joined(separator: "\t")
            case "PROFILE" where fields.count >= 9:
                facts.profiles.append(ProvisioningProfileInfo(
                    name: fields[1], teamID: fields[2], expiration: ProvisioningProfileInfo.parseDate(fields[3]),
                    applicationIdentifier: fields[4], provisionsAllDevices: fields[5] == "true",
                    getTaskAllow: fields[6] == "true",
                    deviceUDIDs: fields[7].split(separator: ",").map(String.init).filter { !$0.isEmpty },
                    fileName: fields[8]
                ))
            default:
                break
            }
        }
        return facts
    }
}

/// Metadata of one provisioning profile on the host. No certificates or keys.
public struct ProvisioningProfileInfo: Codable, Sendable, Hashable {
    public var name: String
    public var teamID: String
    public var expiration: Date?
    /// e.g. `ABCDE12345.com.example.app` or `ABCDE12345.*`.
    public var applicationIdentifier: String
    public var provisionsAllDevices: Bool
    /// Development profiles allow debugging; distribution profiles do not.
    public var getTaskAllow: Bool
    public var deviceUDIDs: [String]
    public var fileName: String

    public enum Kind: String, Codable, Sendable {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case enterprise = "Enterprise"
        case appStore = "App Store"
    }

    /// Inferred the way Xcode does: device list and get-task-allow.
    public var kind: Kind {
        if provisionsAllDevices { return .enterprise }
        if !deviceUDIDs.isEmpty { return getTaskAllow ? .development : .adHoc }
        return .appStore
    }

    public func isExpired(at date: Date = Date()) -> Bool { expiration.map { $0 < date } ?? false }

    /// Whether this profile covers `bundleID` (exact or wildcard).
    public func covers(bundleID: String) -> Bool {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return false }
        let pattern = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast(1))) }
        return pattern == bundleID
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
