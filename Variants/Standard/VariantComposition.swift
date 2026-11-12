// Compiled ONLY into the HCGTerminal (standard) target. The project gives each app target its
// own Variants/<name> folder, so which backend is linked follows from target membership, not
// from a build setting that could be overridden.
#if HCG_UNLEASHED_BUILD
#error("Variants/Standard was compiled with HCG_UNLEASHED_BUILD set. Each app target must compile only its own Variants folder; see docs/BUILD_VARIANTS.md.")
#endif

import FileWorkspace
import Foundation
import TerminalUI

@MainActor
enum VariantComposition {
    static let variant = "standard"

    static func dependencies(workspace: FileWorkspace, supportDirectory: URL) -> AppDependencies {
        AppDependencies.standard(workspace: workspace, supportDirectory: supportDirectory)
    }
}
