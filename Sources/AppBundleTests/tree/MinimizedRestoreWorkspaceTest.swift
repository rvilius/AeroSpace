@testable import AppBundle
import AppKit
import Common
import XCTest

/// A minimized window is parked in the single global macosMinimizedWindowsContainer and
/// loses its workspace, so restoring it used to bind it to whatever workspace happened to
/// be focused. On a multi-monitor setup focus.workspace is always the primary monitor's,
/// so a window minimized on a secondary monitor could never come back to it — it jumped to
/// the primary. restoreWorkspace remembers the origin instead.
@MainActor
final class MinimizedRestoreWorkspaceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    func test_restoreWorkspace_visibleOrigin_winsOverFallback() {
        let origin = focus.workspace // the only workspace on screen in tests
        let fallback = Workspace.get(byName: "fallback-ws")

        XCTAssertTrue(origin.isVisible, "precondition: the focused workspace is on screen")
        XCTAssertTrue(restoreWorkspace(prevWorkspaceName: origin.name, fallback: fallback) === origin,
                      "a window must return to the workspace it was minimized from")
    }

    func test_restoreWorkspace_hiddenOrigin_fallsBackToCurrent() {
        let fallback = focus.workspace
        let hidden = Workspace.get(byName: "hidden-ws")

        XCTAssertFalse(hidden.isVisible, "precondition: an unfocused workspace is off screen")
        XCTAssertTrue(restoreWorkspace(prevWorkspaceName: hidden.name, fallback: fallback) === fallback,
                      "restoring onto a hidden workspace would make a Dock click look like a no-op")
    }

    func test_restoreWorkspace_noOrigin_fallsBackToCurrent() {
        let fallback = focus.workspace

        XCTAssertTrue(restoreWorkspace(prevWorkspaceName: nil, fallback: fallback) === fallback,
                      "fullscreen/hidden exits carry no origin and must keep upstream behavior")
    }
}
