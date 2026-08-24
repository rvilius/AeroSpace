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
        lastUserInputDate = nil // isolate from the deliberate-activation gate
    }

    func test_isAppSwitchKeyGesture_onlyTabAndBacktick() async throws {
        let cmd: NSEvent.ModifierFlags = [.command]
        // App-switch keys under Cmd -> deliberate activation, gate opens.
        XCTAssertTrue(isAppSwitchKeyGesture(cmd, 48), "Cmd-Tab is an app switch")
        XCTAssertTrue(isAppSwitchKeyGesture([.command, .shift], 48), "Cmd-Shift-Tab is an app switch")
        XCTAssertTrue(isAppSwitchKeyGesture(cmd, 50), "Cmd-` cycles app windows")
        // Ordinary Cmd shortcuts must NOT open the gate (the recurrence bug).
        XCTAssertFalse(isAppSwitchKeyGesture(cmd, 8), "Cmd-C must not count")   // kVK_ANSI_C
        XCTAssertFalse(isAppSwitchKeyGesture(cmd, 9), "Cmd-V must not count")   // kVK_ANSI_V
        XCTAssertFalse(isAppSwitchKeyGesture(cmd, 1), "Cmd-S must not count")   // kVK_ANSI_S
        XCTAssertFalse(isAppSwitchKeyGesture(cmd, 49), "Cmd-Space must not count") // kVK_Space
        // Tab without Cmd is just a Tab.
        XCTAssertFalse(isAppSwitchKeyGesture([], 48), "bare Tab is not an app switch")
        // Hyper chord (Caps Lock remap ⌃⌥⇧⌘) is a deliberate global hotkey.
        let hyper: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        XCTAssertTrue(isAppSwitchKeyGesture(hyper, 18), "Hyper-1 is a deliberate jump") // kVK_ANSI_1
        XCTAssertFalse(isAppSwitchKeyGesture([.command, .option, .shift], 18), "3-mod chord must not count")
    }

    func test_ruleRoutedNewWindow_followedAfterGesture() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        let home = focus.workspace
        _ = TestWindow.new(id: 1, parent: home.rootTilingContainer).focusWindow()
        let other = Workspace.get(byName: "other")
        let newWin = TestWindow.new(id: 2, parent: other.rootTilingContainer)
        recentlyOpenedWindow = RecentlyOpenedWindow(windowId: 2, workspaceName: other.name, appPid: 999, date: .now, placedByRule: true)

        // Cold launch: gesture 2s ago (past the 0.5s gate), rule-routed new window -> follow.
        lastUserInputDate = Date.now.addingTimeInterval(-2)
        XCTAssertFalse(isCrossWorkspaceStealToHiddenWorkspace(newWin),
                       "rule-routed new window activating after a hotkey is the hotkey landing")

        // Same window, no gesture (login auto-launch) -> still a steal.
        lastUserInputDate = nil
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(newWin),
                      "rule-routed new window with no gesture must not yank focus")

        // Not rule-routed -> the 0.5s gate governs, 2s is stale.
        recentlyOpenedWindow = RecentlyOpenedWindow(windowId: 2, workspaceName: other.name, appPid: 999, date: .now)
        lastUserInputDate = Date.now.addingTimeInterval(-2)
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(newWin),
                      "unruled new window gets no launch-scale gesture window")
    }

    func test_recentUserGesture_followsDeliberateActivation() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        let home = focus.workspace
        let homeWin = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        _ = homeWin.focusWindow()
        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        // No recent gesture -> background steal, suppressed.
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(stealer),
                      "with no recent user gesture a cross-workspace focus change is a steal")

        // A physical gesture just happened -> deliberate activation (Dock click,
        // Cmd-Tab, Spotlight), followed.
        lastUserInputDate = .now
        XCTAssertFalse(isCrossWorkspaceStealToHiddenWorkspace(stealer),
                       "a cross-workspace focus change right after a user gesture is a deliberate activation")

        // A stale gesture must not keep classifying focus changes as deliberate.
        lastUserInputDate = Date.now.addingTimeInterval(-5)
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(stealer),
                      "a stale user gesture must not keep following steals")
    }

    func test_recentGesture_onEmptyFocusedWorkspace_isStillASteal() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        // setUp leaves the focused workspace empty. This is ab88df1's launch case:
        // opening a new window scoped to an empty workspace is itself a gesture,
        // so a fresh timestamp must NOT make the guard follow the raise.
        XCTAssertNil(focus.windowOrNil, "precondition: focused workspace must be empty")
        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        lastUserInputDate = .now
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(stealer),
                      "a fresh gesture on an empty focused workspace must not follow (ab88df1 regression)")
    }

    func test_recentGesture_duringNewWindowLaunch_isStillASteal() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        let home = focus.workspace
        let homeWin = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        _ = homeWin.focusWindow()
        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        // A new window just opened (a launch is a gesture): even with a fresh
        // timestamp, the app's background raise must stay suppressed.
        lastUserInputDate = .now
        recentlyOpenedWindow = RecentlyOpenedWindow(windowId: 1, workspaceName: home.name, appPid: 999, date: .now)
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(stealer),
                      "a fresh gesture during an in-flight new-window launch must not follow the raise")
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

    func test_stealToHiddenWorkspace_fromEmptyFocusedWorkspace_isStillASteal() async throws {
        config.keepNewWindowOnActiveWorkspace = true
        // setUp leaves the focused workspace empty — no home window to hold.
        XCTAssertNil(focus.windowOrNil, "precondition: focused workspace must be empty")

        let other = Workspace.get(byName: "other")
        let stealer = TestWindow.new(id: 2, parent: other.rootTilingContainer)

        // The empty-workspace bug: with no home window the old guard bailed and
        // updateFocusCache *followed* the steal, dragging the desktop to the
        // stolen window's context. Detection must not depend on a home window.
        XCTAssertTrue(isCrossWorkspaceStealToHiddenWorkspace(stealer),
                      "a steal to a hidden workspace must be detected even when the focused workspace is empty")
        XCTAssertNil(crossWorkspaceStealHoldTarget(stealer),
                     "an empty focused workspace has no window to hold, but it is still a steal")
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
