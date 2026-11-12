// Compiled ONLY into the HCGTerminalUnleashed target, together with the UnleashedIntegration
// package product. If this file were missing from the target, the app would not compile
// (VariantComposition would be undefined); if the compile condition were dropped, the #error
// below stops the build. The executable is additionally checked for the backend marker by
// Scripts/verify-build-variant.sh in a build phase.
#if !HCG_UNLEASHED_BUILD
#error("Variants/Unleashed was compiled without HCG_UNLEASHED_BUILD. Build the HCGTerminalUnleashed scheme; see docs/BUILD_VARIANTS.md.")
#endif

import FileWorkspace
import Foundation
import TerminalUI
import UnleashedIntegration

@MainActor
enum VariantComposition {
    static let variant = "unleashed"

    static func dependencies(workspace: FileWorkspace, supportDirectory: URL) -> AppDependencies {
        UnleashedIntegration.dependencies(workspace: workspace, supportDirectory: supportDirectory)
    }
}
