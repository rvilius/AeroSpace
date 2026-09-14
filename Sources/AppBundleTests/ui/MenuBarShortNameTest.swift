@testable import AppBundle
import XCTest

final class MenuBarShortNameTest: XCTestCase {
    func testShortNames() {
        XCTAssertEqual(menuBarShortName("Personal"), "PER")
        XCTAssertEqual(menuBarShortName("Personal-2"), "PER-2")
        XCTAssertEqual(menuBarShortName("Hotrema"), "HOT")
        XCTAssertEqual(menuBarShortName("KD-Jupiter"), "KDJ")
        XCTAssertEqual(menuBarShortName("KD-Jupiter-2"), "KDJ-2")
        XCTAssertEqual(menuBarShortName("Corp-Opus"), "COR")
        XCTAssertEqual(menuBarShortName("Ismpro-2"), "ISM-2")
        XCTAssertEqual(menuBarShortName("1"), "1")
    }
}
