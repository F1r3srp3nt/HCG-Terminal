import Foundation
@testable import TerminalUI
import XCTest

final class BuildIdentityTests: XCTestCase {
    private func info(variant: String = "standard", bundle: String = "com.hakmicapitalgroup.hcgterminal", name: String = "HCG Terminal") -> [String: Any] {
        [
            "HCGBuildVariant": variant, "HCGSourceRevision": "830cdac1f2ab",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "CFBundleIdentifier": bundle, "CFBundleDisplayName": name,
        ]
    }

    func testConsistentStandardBuild() {
        let identity = BuildIdentity.from(infoDictionary: info(), linkedBackend: .standard)
        XCTAssertEqual(identity.problems, [])
        XCTAssertEqual(identity.versionLabel, "0.1.0 (1)")
        XCTAssertEqual(identity.sourceRevision, "830cdac1f2ab")
        XCTAssertTrue(identity.variantLabel.hasPrefix("Standard"))
    }

    func testConsistentUnleashedBuild() {
        let identity = BuildIdentity.from(
            infoDictionary: info(variant: "unleashed", bundle: "com.hakmicapitalgroup.hcgterminal.unleashed", name: "HCG Terminal Unleashed"),
            linkedBackend: .unleashed
        )
        XCTAssertEqual(identity.problems, [])
        XCTAssertTrue(identity.variantLabel.hasPrefix("Unleashed"))
    }

    /// The reported device situation: named Unleashed, but the standard backend is linked.
    func testUnleashedNameWithoutBackendIsFlagged() {
        let identity = BuildIdentity.from(info(name: "HCG Terminal Unleashed"), linkedBackend: .standard)
        XCTAssertTrue(identity.problems.contains { $0.contains("does not contain the Unleashed backend") }, "\(identity.problems)")
        XCTAssertTrue(identity.variantLabel.hasPrefix("Standard"), "the label follows the linked code, not the name")
    }

    func testDeclaredVariantMismatchAndMissingKeys() {
        let mismatch = BuildIdentity.from(info(variant: "unleashed"), linkedBackend: .standard)
        XCTAssertTrue(mismatch.problems.contains { $0.contains("declares the unleashed variant") })
        let unexpanded = BuildIdentity.from(infoDictionary: ["HCGBuildVariant": "$(HCG_BUILD_VARIANT)"], linkedBackend: .standard)
        XCTAssertEqual(unexpanded.declaredVariant, "unknown")
        XCTAssertEqual(unexpanded.sourceRevision, "unknown")
        XCTAssertTrue(unexpanded.problems.contains { $0.contains("does not declare a build variant") })
    }
}

private extension BuildIdentity {
    static func from(_ info: [String: Any], linkedBackend: DistributionBuild) -> BuildIdentity {
        from(infoDictionary: info, linkedBackend: linkedBackend)
    }
}
