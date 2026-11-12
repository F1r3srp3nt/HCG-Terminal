import FileWorkspace
import Foundation
import SwiftUI
import TerminalUI

@main
struct HCGTerminalApp: App {
    @State private var model = AppComposition.makeModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// Composition root. `VariantComposition` comes from the target's own Variants/<name> folder:
/// the standard target neither compiles nor links any Unleashed code (docs/BUILD_VARIANTS.md).
@MainActor
enum AppComposition {
    static func makeModel() -> TerminalAppModel {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let supportDirectory = support.appendingPathComponent("HCGTerminal", isDirectory: true)
        let workspace: FileWorkspace
        do {
            workspace = try FileWorkspace.appContainerDefault()
        } catch {
            // Fall back to a temporary workspace rather than failing to launch.
            workspace = try! FileWorkspace(rootURL: fileManager.temporaryDirectory.appendingPathComponent("Workspace", isDirectory: true))
        }
        let dependencies = VariantComposition.dependencies(workspace: workspace, supportDirectory: supportDirectory)
        return TerminalAppModel(dependencies: dependencies)
    }
}
