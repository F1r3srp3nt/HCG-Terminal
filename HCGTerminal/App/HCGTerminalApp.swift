import FileWorkspace
import Foundation
import MachO
import SwiftUI
import TerminalCore
import TerminalUI

@main
struct HCGTerminalApp: App {
    /// The startup journal opens before anything else, so a failure later in startup is recorded
    /// and the next launch can offer the recovery screen (docs/JAILBREAK_EDITION.md).
    @State private var launch = LaunchController(journal: AppComposition.beginJournal()) {
        AppComposition.makeModel()
    }

    var body: some Scene {
        WindowGroup {
            LaunchRootView(controller: launch)
        }
    }
}

/// Composition root. `VariantComposition` comes from the target's own Variants/<name> folder:
/// the standard target neither compiles nor links any Unleashed code (docs/BUILD_VARIANTS.md).
@MainActor
enum AppComposition {
    static var supportDirectory: URL {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return support.appendingPathComponent("HCGTerminal", isDirectory: true)
    }

    static func beginJournal() -> StartupJournal {
        let info = Bundle.main.infoDictionary ?? [:]
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { bytes in String(decoding: bytes.prefix { byte in byte != 0 }, as: UTF8.self) }
        let header: [(String, String)] = [
            ("app", "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")), \(VariantComposition.variant), revision \(info["HCGSourceRevision"] as? String ?? "?")"),
            ("bundle", Bundle.main.bundlePath),
            ("home", NSHomeDirectory()),
            ("device", "\(model), \(ProcessInfo.processInfo.operatingSystemVersionString)"),
            ("user", "uid \(getuid()), euid \(geteuid())"),
            ("injected libraries", injectedLibraries()),
        ]
        return StartupJournal.begin(directory: supportDirectory.appendingPathComponent("Startup", isDirectory: true), header: header)
    }

    /// Libraries loaded into this process from outside the app and the OS, i.e. jailbreak tweaks
    /// and their loaders, by file name. Used to tell whether tweak injection is involved in a failure.
    static func injectedLibraries() -> String {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        var names: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            if path.hasPrefix(bundle) || path.hasPrefix(Bundle.main.bundlePath) { continue }
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") || path.hasPrefix("/Developer/") { continue }
            names.append(path)
        }
        return names.isEmpty ? "none" : "\(names.count): " + names.prefix(40).joined(separator: ", ")
    }

    static func makeModel() -> TerminalAppModel {
        let fileManager = FileManager.default
        let journal = StartupJournal.shared
        journal?.phase("file workspace")
        let workspace: FileWorkspace
        do {
            workspace = try FileWorkspace.appContainerDefault()
        } catch {
            journal?.note("workspace in Documents unavailable (\(error)); trying a temporary workspace")
            do {
                workspace = try FileWorkspace(rootURL: fileManager.temporaryDirectory.appendingPathComponent("Workspace", isDirectory: true))
            } catch {
                // Last resort: an in-memory-only root that FileWorkspace accepts. Never stop the launch.
                journal?.note("temporary workspace unavailable (\(error))")
                workspace = FileWorkspace.unavailable
            }
        }
        journal?.note("workspace \(workspace.rootURL.path)")
        journal?.phase("app services")
        let dependencies = VariantComposition.dependencies(workspace: workspace, supportDirectory: supportDirectory)
        journal?.phase("app model")
        return TerminalAppModel(dependencies: dependencies)
    }
}
