@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class FloatingUnhideTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // MARK: - Pure helper: documents the coerce math used by unhideFromCorner.

    func test_helper_freshSize_rightEdgeWindowStaysPut() {
        // 2000x1000 monitor. Window at topLeft (1400,100), width 600 -> right edge at 2000.
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)
        let proportion = CGPoint(x: 0.7, y: 0.1)
        let size = CGSize(width: 600, height: 400)
        let p = computeFloatingUnhideTopLeft(workspaceRect: monitor, proportion: proportion, floatingSize: size)
        XCTAssertEqual(p.x, 1400, accuracy: 1)
        XCTAssertEqual(p.y, 100, accuracy: 1)
    }

    func test_helper_staleSize_clampsRightEdgeWindowLeft() {
        // The bug pattern: stale lastFloatingSize (1600) is much larger than the
        // window's current 600px width. Recovered topLeftX (1400) is still within
        // real bounds but gets clamped to maxX - staleWidth = 400.
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)
        let proportion = CGPoint(x: 0.7, y: 0.1)
        let staleSize = CGSize(width: 1600, height: 400)
        let p = computeFloatingUnhideTopLeft(workspaceRect: monitor, proportion: proportion, floatingSize: staleSize)
        XCTAssertEqual(p.x, 400, accuracy: 1, "stale size pulls the window left by stale - actual = 1000")
    }

    func test_helper_nilSize_doesNotClampUpperBound() {
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)
        let p = computeFloatingUnhideTopLeft(workspaceRect: monitor,
                                             proportion: CGPoint(x: 0.95, y: 0.5),
                                             floatingSize: nil)
        XCTAssertEqual(p.x, 1900, accuracy: 1)
    }

    // MARK: - Regression test for the fix: hideInCorner must refresh lastFloatingSize
    // for floating windows (so unhideFromCorner clamps against the actual width)
    // and must NOT touch it for tiling windows (it tracks restore-on-refloat size).

    func test_hideInCorner_refreshesLastFloatingSize_forFloatingWindow() async throws {
        let workspace = focus.workspace
        let actualRect = Rect(topLeftX: 1400, topLeftY: 100, width: 600, height: 400)
        let w = TestWindow.new(id: 1, parent: workspace, rect: actualRect)
        w.lastFloatingSize = CGSize(width: 1600, height: 400) // stale: larger than actualRect.size

        try await w.hideInCorner(.bottomRightCorner)

        XCTAssertEqual(w.lastFloatingSize?.width, 600, "hideInCorner must refresh lastFloatingSize from the AX rect")
        XCTAssertEqual(w.lastFloatingSize?.height, 400)
    }

    func test_hideInCorner_doesNotRefreshLastFloatingSize_forTilingWindow() async throws {
        let workspace = focus.workspace
        let container = workspace.rootTilingContainer
        let actualRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let w = TestWindow.new(id: 2, parent: container, rect: actualRect)
        let originalFloatingSize = CGSize(width: 500, height: 300)
        w.lastFloatingSize = originalFloatingSize

        try await w.hideInCorner(.bottomRightCorner)

        XCTAssertEqual(w.lastFloatingSize?.width, originalFloatingSize.width,
                       "tiling windows must preserve their floating-restore size across hide")
        XCTAssertEqual(w.lastFloatingSize?.height, originalFloatingSize.height)
    }
}
