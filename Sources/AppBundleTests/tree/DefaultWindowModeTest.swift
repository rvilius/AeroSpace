@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class DefaultWindowModeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
        config.defaultWindowMode = .tiling // tests opt in
    }

    // MARK: - exitMacOsNativeUnconventionalState

    func test_exitNative_tilingParent_floatingMode_bindsToWorkspace() async throws {
        config.defaultWindowMode = .floating
        let workspace = focus.workspace
        let w = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try await exitMacOsNativeUnconventionalState(window: w, prevParentKind: .tilingContainer, workspace: workspace)

        XCTAssertTrue(w.parent === workspace,
                      "floating mode must rebind tiling-prev-parent exits as floating, not force-tile them back")
    }

    func test_exitNative_tilingParent_tilingMode_forcesTiling() async throws {
        config.defaultWindowMode = .tiling
        let workspace = focus.workspace
        let w = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try await exitMacOsNativeUnconventionalState(window: w, prevParentKind: .tilingContainer, workspace: workspace)

        XCTAssertTrue(w.parent is TilingContainer,
                      "tiling mode must preserve upstream's forceTile behavior on native-state exit")
    }

    // MARK: - closedWindowsCache restore (orphan path)

    func test_cacheRestore_orphan_floatingMode_bindsToWorkspace() async throws {
        config.defaultWindowMode = .floating
        let workspace = focus.workspace
        // Window in the frozen tree
        let cached = TestWindow.new(id: 100, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        // Window added after cache → will be a potentialOrphan during restore
        let orphan = TestWindow.new(id: 200, parent: workspace.rootTilingContainer)

        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: cached)

        XCTAssertTrue(restored)
        XCTAssertTrue(orphan.parent === workspace,
                      "floating mode must bind orphans directly to the workspace, not force-tile them")
    }

    func test_cacheRestore_orphan_tilingMode_forceTilesOrphan() async throws {
        config.defaultWindowMode = .tiling
        let workspace = focus.workspace
        let cached = TestWindow.new(id: 100, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        let orphan = TestWindow.new(id: 200, parent: workspace.rootTilingContainer)

        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: cached)

        XCTAssertTrue(restored)
        XCTAssertTrue(orphan.parent is TilingContainer,
                      "tiling mode must preserve upstream's forceTile orphan recovery")
    }
}
