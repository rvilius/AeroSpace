@testable import AppBundle
import AppKit
import Common
import XCTest

// Covers crossWorkspaceStealHoldTarget: the focus-steal decision used by
// updateFocusCache. An app raising a background window on a hidden workspace
// must not yank the user off their current (visible) workspace.
// See focusCache.swift.
@MainActor
final class FocusStealGuardTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
        recentlyOpenedWindow = nil // isolate from the new-window guard
    }

    func test_stealToHiddenWorkspace_holdsActiveWindow() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        let home = focus.workspace
        let homeWin = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        _ = homeWin.focusWindow()

        // Different window on a hidden (non-visible) workspace -> steal.
        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        XCTAssertTrue(crossWorkspaceStealHoldTarget(stealer) === homeWin,
                      "a steal to a hidden workspace must hold focus on the active window")
    }

    func test_allowListedApp_isFollowed() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        config.focusStealAllowApps = [TestApp.shared.rawAppBundleId ?? ""]
        let home = focus.workspace
        let homeWin = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        _ = homeWin.focusWindow()
        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        XCTAssertNil(crossWorkspaceStealHoldTarget(stealer),
                     "an allow-listed app's cross-workspace focus change must be followed")
    }

    func test_sameWorkspaceFocusChange_isNotASteal() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        let home = focus.workspace
        let homeWin = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        _ = homeWin.focusWindow()

        // Sibling on the SAME workspace must be followed, never held back.
        let sibling = TestWindow.new(id: 2, parent: home.rootTilingContainer)

        XCTAssertNil(crossWorkspaceStealHoldTarget(sibling),
                     "same-workspace focus change must be followed, never snapped back")
    }

    func test_flagOff_isNotASteal() async throws {
        config.keepNewWindowOnActiveWorkspace = false
        let home = focus.workspace
        let homeWin = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        _ = homeWin.focusWindow()
        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        XCTAssertNil(crossWorkspaceStealHoldTarget(stealer),
                     "with the flag off, upstream follow-the-steal behavior is preserved")
    }
}
