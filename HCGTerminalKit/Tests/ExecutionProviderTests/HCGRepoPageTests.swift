import Foundation
import UnleashedExecutionProvider
import XCTest

final class HCGRepoPageTests: XCTestCase {
    func testProductPageIsAFixedHTTPSAddressWithoutQueryOrIdentifiers() {
        let url = HCGRepoPage.url
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "repo.hakmicapitalgroup.com")
        XCTAssertEqual(url.pathComponents, ["/", "products", "hcg-terminal-unleashed"])
        XCTAssertEqual(url.absoluteString, "https://repo.hakmicapitalgroup.com/products/hcg-terminal-unleashed/")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.port)
    }
}
