import XCTest
@testable import xFinderKit

final class SmokeTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(xFinderKit.keychainService, "xFinder")
    }
}
