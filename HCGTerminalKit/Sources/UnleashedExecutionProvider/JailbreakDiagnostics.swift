import Foundation
import TerminalCore
#if canImport(Darwin)
import Darwin
import MachO
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads the code signature of a Mach-O file: whether it is signed, how, and its entitlements.
/// Pure parsing of bytes; used to show which entitlements this copy of the app actually carries.
public enum MachOSignature {
    public struct Info: Sendable, Equatable {
        public var signed: Bool
        /// True when a CMS (certificate) signature is present; false for ad hoc / ldid.
        public var hasCertificateSignature: Bool
        /// Entitlement keys mapped to a short description of their values.
        public var entitlements: [String: String]
    }

    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let machO64: UInt32 = 0xFEED_FACF
    static let lcCodeSignature: UInt32 = 0x1D
    static let cpuTypeARM64: UInt32 = 0x0100_000C

    public static func read(path: String) -> Info? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse([UInt8](data))
    }

    public static func parse(_ bytes: [UInt8]) -> Info? {
        func be32(_ o: Int) -> UInt32? { o + 4 <= bytes.count ? bytes[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } : nil }
        func le32(_ o: Int) -> UInt32? { o + 4 <= bytes.count ? bytes[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : nil }

        var slice = 0
        if be32(0) == fatMagic, let count = be32(4) {
            var chosen: Int?
            for index in 0..<Int(min(count, 16)) {
                let entry = 8 + index * 20
                guard let cpu = be32(entry), let offset = be32(entry + 8) else { break }
                if chosen == nil || cpu == cpuTypeARM64 { chosen = Int(offset) }
                if cpu == cpuTypeARM64 { break }
            }
            guard let chosen else { return nil }
            slice = chosen
        }
        guard le32(slice) == machO64, let ncmds = le32(slice + 16) else { return nil }
        var cursor = slice + 32
        var signature: (offset: Int, size: Int)?
        for _ in 0..<min(Int(ncmds), 512) {
            guard let cmd = le32(cursor), let size = le32(cursor + 4), size >= 8 else { break }
            if cmd == lcCodeSignature, let off = le32(cursor + 8), let len = le32(cursor + 12) {
                signature = (slice + Int(off), Int(len))
            }
            cursor += Int(size)
        }
        guard let signature, be32(signature.offset) == 0xFADE_0CC0, let count = be32(signature.offset + 8) else {
            return Info(signed: false, hasCertificateSignature: false, entitlements: [:])
        }
        var entitlements: [String: String] = [:]
        var certificate = false
        for index in 0..<Int(min(count, 64)) {
            let entry = signature.offset + 12 + index * 8
            guard let type = be32(entry), let offset = be32(entry + 4) else { break }
            let blob = signature.offset + Int(offset)
            guard let magic = be32(blob), let length = be32(blob + 4) else { continue }
            if type == 0x10000, magic == 0xFADE_0B01, length > 8 { certificate = true }
            if type == 5, magic == 0xFADE_7171, length > 8, blob + Int(length) <= bytes.count {
                let xml = Data(bytes[(blob + 8)..<(blob + Int(length))])
                if let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] {
                    for (key, value) in plist { entitlements[key] = describe(value) }
                }
            }
        }
        return Info(signed: true, hasCertificateSignature: certificate, entitlements: entitlements)
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let bool as Bool: bool ? "true" : "false"
        case let string as String: string
        case let array as [Any]: "[" + array.map(describe).joined(separator: ", ") + "]"
        case let number as NSNumber: number.stringValue
        default: "\(value)"
        }
    }
}

/// Read-only jailbreak diagnostics for the Unleashed tools. Nothing here writes, installs,
/// removes, resprings or changes a setting; every finding says what was read.
public struct JailbreakDiagnostics: Sendable {
    public struct Input: Sendable {
        /// Prefix for every path (tests use a temporary tree; on a device it is empty).
        public var fileSystemRoot: String
        public var bundlePath: String
        public var executablePath: String
        /// The jailbreak root that was found (`/var/jb`, a relocated root, or "" for rootful).
        public var jailbreakRoot: String?
        public var environmentVisible: Bool
        public var loadedImages: [String]
        public var now: Date

        public init(fileSystemRoot: String = "", bundlePath: String, executablePath: String, jailbreakRoot: String?, environmentVisible: Bool, loadedImages: [String], now: Date = Date()) {
            self.fileSystemRoot = fileSystemRoot
            self.bundlePath = bundlePath
            self.executablePath = executablePath
            self.jailbreakRoot = jailbreakRoot
            self.environmentVisible = environmentVisible
            self.loadedImages = loadedImages
            self.now = now
        }
    }

    public let input: Input
    private var fm: FileManager { .default }

    public init(_ input: Input) {
        self.input = input
    }

    /// The real process: bundle, executable, loaded images.
    public static func currentProcess(jailbreakRoot: String?, environmentVisible: Bool) -> Input {
        var images: [String] = []
        #if canImport(Darwin)
        for index in 0..<_dyld_image_count() {
            if let name = _dyld_get_image_name(index) { images.append(String(cString: name)) }
        }
        #endif
        return Input(
            bundlePath: Bundle.main.bundlePath, executablePath: Bundle.main.executablePath ?? "",
            jailbreakRoot: jailbreakRoot, environmentVisible: environmentVisible, loadedImages: images
        )
    }

    func p(_ path: String) -> String { input.fileSystemRoot + path }
    /// The rootless jailbreak root to check. An empty prefix (programs found at the system root)
    /// still means the rootless root is `/var/jb`, never "" (which printed as "at .").
    var jb: String {
        guard let root = input.jailbreakRoot, !root.isEmpty, root != "/" else { return "/var/jb" }
        return root
    }

    public func report() -> DiagnosticReport {
        DiagnosticReport(sections: [installation(), bootstrap(), packages(), repositories(), injectionAndSafeMode(), storage()], generatedAt: input.now)
    }

    // MARK: Installation and signature

    func installation() -> DiagnosticReport.Section {
        var items: [DiagnosticReport.Item] = []
        let bundle = input.bundlePath
        let location: (DiagnosticReport.Item.Status, String)
        if bundle.hasPrefix("/var/jb/Applications/") || bundle.contains("/procursus/Applications/") || (bundle.hasPrefix("/private/preboot/") && bundle.contains("/Applications/")) {
            location = (.ok, "Installed by the package manager in the rootless jailbreak's Applications folder.")
        } else if bundle.hasPrefix("/Applications/") {
            location = (.ok, "Installed in /Applications (rootful layout).")
        } else if bundle.contains("/containers/Bundle/Application/") {
            location = (.warning, "Installed as an ordinary app (Xcode, IPA, TrollStore or the App Store). This copy is not the .deb; a sandboxed copy cannot start local shells.")
        } else {
            location = (.info, "Installed at an unusual location.")
        }
        items.append(.init(id: "location", title: "Install location", status: location.0, detail: location.1, evidence: [bundle]))

        if let info = MachOSignature.read(path: p(input.executablePath)) {
            let noSandbox = info.entitlements["com.apple.private.security.no-sandbox"] == "true"
            let kind = !info.signed ? "not signed" : info.hasCertificateSignature ? "certificate signature" : "ad hoc / ldid signature"
            items.append(.init(
                id: "signature", title: "Signature and entitlements",
                status: !info.signed ? .problem : noSandbox ? .ok : .warning,
                detail: noSandbox ? "\(kind); outside the app sandbox (no-sandbox entitlement)." : "\(kind); no no-sandbox entitlement, so the system keeps this copy in the app sandbox.",
                evidence: info.entitlements.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            ))
        } else {
            items.append(.init(id: "signature", title: "Signature and entitlements", status: .unknown, detail: "The app executable could not be read.", evidence: [input.executablePath]))
        }

        let helper = (bundle as NSString).appendingPathComponent(PTYHelper.name)
        let helperOK = fm.isExecutableFile(atPath: p(helper))
        items.append(.init(
            id: "pty-helper", title: "Controlling-terminal helper", status: helperOK ? .ok : .info,
            detail: helperOK ? "Present: shells get job control (Ctrl-C, Ctrl-Z, window size)." : "Not bundled (only the .deb includes it). Shells run without job control.",
            evidence: [helper]
        ))
        items.append(.init(
            id: "sandbox", title: "Outside the sandbox", status: input.environmentVisible ? .ok : .warning,
            detail: input.environmentVisible ? "Folders outside the app container are readable." : "Folders outside the app container are not visible: this process is sandboxed or the device is not jailbroken.",
            evidence: []
        ))
        return .init(id: "installation", title: "Installation", items: items)
    }

    // MARK: Bootstrap

    func bootstrap() -> DiagnosticReport.Section {
        var items: [DiagnosticReport.Item] = []
        let link = try? fm.destinationOfSymbolicLink(atPath: p("/var/jb"))
        let rootExists = fm.fileExists(atPath: p(jb))
        items.append(.init(
            id: "jbroot", title: "Jailbreak root", status: rootExists ? .ok : (input.environmentVisible ? .problem : .unknown),
            detail: rootExists ? "\(jb)" + (link.map { " → \($0)" } ?? "") : (input.environmentVisible ? "No rootless jailbreak root at \(jb)." : "Not visible from this process."),
            evidence: link.map { ["/var/jb → \($0)"] } ?? []
        ))
        let markers = [".procursus_strapped", ".installed_dopamine", ".bootstrapped", ".installed_palera1n"].filter { fm.fileExists(atPath: p(jb + "/" + $0)) }
        items.append(.init(id: "markers", title: "Bootstrap markers", status: markers.isEmpty ? .unknown : .info,
                           detail: markers.isEmpty ? "None found." : markers.joined(separator: ", "), evidence: markers.map { jb + "/" + $0 }))
        let tools: [(String, [String])] = [
            ("Shell", ["bin/sh", "bin/bash", "bin/zsh", "usr/bin/bash", "usr/bin/zsh", "bin/dash"]),
            ("dpkg", ["usr/bin/dpkg"]), ("apt", ["usr/bin/apt", "usr/bin/apt-get"]),
            ("uicache (uikittools)", ["usr/bin/uicache"]), ("sudo", ["usr/bin/sudo"]),
        ]
        for (name, candidates) in tools {
            let found = candidates.map { jb + "/" + $0 }.filter { fm.isExecutableFile(atPath: p($0)) }
            let required = name == "Shell" || name.hasPrefix("uicache")
            items.append(.init(
                id: "tool-\(name)", title: name, status: !found.isEmpty ? .ok : (input.environmentVisible ? (required ? .problem : .info) : .unknown),
                detail: found.first ?? (input.environmentVisible ? "Not found under \(jb)." : "Not visible from this process."), evidence: found
            ))
        }
        return .init(id: "bootstrap", title: "Rootless bootstrap", items: items,
                     footer: "Roothide (iphoneos-arm64e) is not supported by this package. HCG Terminal never installs or repairs bootstrap components.")
    }

    // MARK: Packages

    func packages() -> DiagnosticReport.Section {
        let statusPath = jb + "/var/lib/dpkg/status"
        guard let text = try? String(contentsOfFile: p(statusPath), encoding: .utf8) else {
            return .init(id: "packages", title: "Package database", items: [
                .init(id: "status", title: "dpkg status", status: .unknown, detail: "\(statusPath) could not be read.", evidence: [statusPath]),
            ])
        }
        var items: [DiagnosticReport.Item] = []
        var unhealthy: [String] = []
        var installed = 0
        for stanza in text.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in stanza.split(separator: "\n") where !line.hasPrefix(" ") {
                if let colon = line.firstIndex(of: ":") { fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            guard let name = fields["Package"], let status = fields["Status"] else { continue }
            if status == "install ok installed" { installed += 1 } else if !status.hasSuffix("not-installed") && !status.hasSuffix("config-files") {
                unhealthy.append("\(name): \(status)")
            }
        }
        items.append(.init(id: "installed", title: "Installed packages", status: .info, detail: "\(installed) fully installed.", evidence: [statusPath]))
        items.append(.init(
            id: "unhealthy", title: "Interrupted or broken installs", status: unhealthy.isEmpty ? .ok : .problem,
            detail: unhealthy.isEmpty ? "None: every recorded package is fully installed or removed." : "\(unhealthy.count) package(s) are half installed, unpacked or waiting for configuration.",
            evidence: unhealthy
        ))
        let locks = ["lock", "lock-frontend"].map { jb + "/var/lib/dpkg/" + $0 }.filter { fm.fileExists(atPath: p($0)) }
        items.append(.init(id: "locks", title: "dpkg lock files", status: .info,
                           detail: locks.isEmpty ? "None present." : "Present (normal; held only while a package manager runs).", evidence: locks))
        return .init(id: "packages", title: "Package database", items: items,
                     footer: unhealthy.isEmpty ? nil : "Finish or undo interrupted installs in Sileo or Zebra, or run `sudo dpkg --configure -a` yourself. HCG Terminal does not change the package database.")
    }

    // MARK: Repositories

    func repositories() -> DiagnosticReport.Section {
        var items: [DiagnosticReport.Item] = []
        let directory = jb + "/etc/apt/sources.list.d"
        let files = ((try? fm.contentsOfDirectory(atPath: p(directory))) ?? []).filter { $0.hasSuffix(".sources") || $0.hasSuffix(".list") }.sorted()
        var uris: [String] = []
        for file in files {
            let text = (try? String(contentsOfFile: p(directory + "/" + file), encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.hasPrefix("#") {
                if line.hasPrefix("URIs:") {
                    uris += line.dropFirst(5).split(separator: " ").map(String.init)
                } else if line.hasPrefix("deb ") {
                    if let uri = line.split(separator: " ").first(where: { $0.contains("://") }) { uris.append(String(uri)) }
                }
            }
        }
        uris = Array(Set(uris)).sorted()
        if files.isEmpty {
            items.append(.init(id: "sources", title: "APT sources", status: input.environmentVisible ? .warning : .unknown,
                               detail: input.environmentVisible ? "No source files in \(directory)." : "Not visible from this process.", evidence: [directory]))
        } else {
            items.append(.init(id: "sources", title: "APT sources", status: .info, detail: "\(uris.count) repositories in \(files.count) file(s).", evidence: uris))
        }
        let http = uris.filter { $0.hasPrefix("http://") }
        if !http.isEmpty {
            items.append(.init(id: "http", title: "Unencrypted sources", status: .warning, detail: "\(http.count) source(s) use http://; their packages are not protected in transit.", evidence: http))
        }
        let hcg = uris.filter { $0.contains("repo.hakmicapitalgroup.com") }
        items.append(.init(id: "hcg-repo", title: "HCG Repo", status: hcg.isEmpty ? .info : .ok,
                           detail: hcg.isEmpty ? "Not added. Add https://repo.hakmicapitalgroup.com/repo/ in Sileo or Zebra to get HCG packages." : "Added.", evidence: hcg))
        let lists = jb + "/var/lib/apt/lists"
        let dates = ((try? fm.contentsOfDirectory(atPath: p(lists))) ?? []).compactMap { name -> Date? in
            (try? fm.attributesOfItem(atPath: p(lists + "/" + name)))?[.modificationDate] as? Date
        }
        if let newest = dates.max() {
            let days = Int(input.now.timeIntervalSince(newest) / 86400)
            items.append(.init(id: "refresh", title: "Last refresh", status: days > 30 ? .warning : .ok,
                               detail: days == 0 ? "Package lists were refreshed today." : "Package lists were last refreshed \(days) day(s) ago.", evidence: [lists]))
        }
        return .init(id: "repositories", title: "Repositories", items: items, footer: "Read only: sources are listed, never edited.")
    }

    // MARK: Tweak injection and Safe Mode

    func injectionAndSafeMode() -> DiagnosticReport.Section {
        var items: [DiagnosticReport.Item] = []
        let injectors = ["ellekit", "libhooker", "substitute", "substrate", "TweakInject", "systemhook"]
        let loaded = input.loadedImages.filter { image in injectors.contains { image.localizedCaseInsensitiveContains($0) } }
        items.append(.init(
            id: "injection", title: "Tweak injection in this app", status: .info,
            detail: loaded.isEmpty ? "No tweak-injection library is loaded into HCG Terminal." : "Loaded into HCG Terminal: \(loaded.count) injection librar\(loaded.count == 1 ? "y" : "ies").",
            evidence: loaded
        ))

        // Tweaks that hook processes, newest first (dpkg's file lists change on install/upgrade).
        let statusPath = jb + "/var/lib/dpkg/status"
        let text = (try? String(contentsOfFile: p(statusPath), encoding: .utf8)) ?? ""
        var tweaks: [(String, Date?)] = []
        for stanza in text.components(separatedBy: "\n\n") where stanza.contains("Status: install ok installed") {
            let lines = stanza.split(separator: "\n")
            guard let name = lines.first(where: { $0.hasPrefix("Package:") })?.dropFirst(8).trimmingCharacters(in: .whitespaces) else { continue }
            let depends = lines.first { $0.hasPrefix("Depends:") }.map(String.init) ?? ""
            guard ["mobilesubstrate", "ellekit", "libhooker", "substitute"].contains(where: { depends.contains($0) }) else { continue }
            let date = (try? fm.attributesOfItem(atPath: p(jb + "/var/lib/dpkg/info/\(name).list")))?[.modificationDate] as? Date
            tweaks.append((name, date))
        }
        tweaks.sort { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
        let recent = tweaks.filter { ($0.1.map { input.now.timeIntervalSince($0) < 7 * 86400 }) ?? false }
        items.append(.init(
            id: "tweaks", title: "Installed tweaks", status: recent.isEmpty ? .info : .warning,
            detail: tweaks.isEmpty ? "No installed package depends on a tweak injector." : "\(tweaks.count) tweak(s); \(recent.count) installed or updated in the last 7 days.",
            evidence: tweaks.prefix(15).map { "\($0.0)" + ($0.1.map { " · \(ISO8601DateFormatter().string(from: $0))" } ?? "") }
        ))

        let crashDir = "/var/mobile/Library/Logs/CrashReporter"
        let crashes = ((try? fm.contentsOfDirectory(atPath: p(crashDir))) ?? []).filter { $0.hasPrefix("SpringBoard") }.compactMap { name -> (String, Date)? in
            guard let date = (try? fm.attributesOfItem(atPath: p(crashDir + "/" + name)))?[.modificationDate] as? Date else { return nil }
            return (name, date)
        }.filter { input.now.timeIntervalSince($0.1) < 7 * 86400 }.sorted { $0.1 > $1.1 }
        let crashReadable = fm.fileExists(atPath: p(crashDir))
        items.append(.init(
            id: "springboard-crashes", title: "SpringBoard crashes (7 days)", status: !crashReadable ? .unknown : crashes.isEmpty ? .ok : .warning,
            detail: !crashReadable ? "\(crashDir) is not readable." : crashes.isEmpty ? "None recorded." : "\(crashes.count) crash report(s). Safe Mode usually follows a SpringBoard crash caused by a tweak.",
            evidence: crashes.prefix(10).map { "\($0.0) · \(ISO8601DateFormatter().string(from: $0.1))" }
        ))
        return .init(
            id: "safe-mode", title: "Tweak injection and Safe Mode", items: items,
            footer: "If the device entered Safe Mode: remove the most recently installed tweak in Sileo or Zebra (they work in Safe Mode), or turn off Tweak Injection in the Dopamine app and reboot into the jailbreak again. HCG Terminal changes nothing here."
        )
    }

    // MARK: Storage

    func storage() -> DiagnosticReport.Section {
        var items: [DiagnosticReport.Item] = []
        var seen = Set<UInt64>()
        for (label, path) in [("System", "/"), ("Data", "/private/var"), ("Jailbreak root", jb), ("Preboot", "/private/preboot")] {
            var stats = statvfs()
            guard statvfs(p(path), &stats) == 0 else {
                items.append(.init(id: "storage-\(label)", title: label, status: .unknown, detail: "\(path) could not be measured.", evidence: [path]))
                continue
            }
            let blockSize = UInt64(stats.f_frsize)
            let total = UInt64(stats.f_blocks) * blockSize
            let free = UInt64(stats.f_bavail) * blockSize
            // Volumes shared by several paths are shown once.
            let fingerprint = total &* 31 &+ UInt64(stats.f_blocks)
            if seen.contains(fingerprint), label != "Jailbreak root" { continue }
            seen.insert(fingerprint)
            let gb = Double(free) / 1_000_000_000
            let status: DiagnosticReport.Item.Status = label == "Data" && gb < 1 ? .problem : label == "Data" && gb < 5 ? .warning : .info
            items.append(.init(
                id: "storage-\(label)", title: label, status: status,
                detail: "\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))",
                evidence: [path]
            ))
        }
        return .init(id: "storage", title: "Storage", items: items)
    }
}
