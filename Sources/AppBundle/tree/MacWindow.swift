import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId)
        let bornWorkspace = isStartup
            ? (rect?.center.monitorApproximation ?? mainMonitor).activeWorkspace
            : focus.workspace
        // Captured for the keep-new-window-on-active-workspace rescue below,
        // before any binding so they describe the state the new window is
        // born into: the workspace focused just before the activation jump,
        // whether that jump was recent, and whether the app already had a
        // window on bornWorkspace (the macOS window-grouping signature).
        let prevWs = prevFocusedWorkspace
        let prevWsRecent = prevFocusedWorkspaceDate.distance(to: .now) < 1.0
        let appHadSiblingOnBornWorkspace = allWindows.contains {
            $0.windowId != windowId && $0.macApp === macApp && $0.nodeWorkspace == bornWorkspace
        }
        let data = try await unbindAndGetBindingDataForNewWindow(windowId, macApp, bornWorkspace, window: nil)

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window

        // Whether the user has an explicit on-window-detected rule for this
        // window. Evaluated before the callbacks run (and before they can move
        // the window) so a rule that routes to bornWorkspace is still detected.
        // A matching rule means the user controls this app's placement, so the
        // rescue stays out of the way (e.g. the Safari "Open Profile" hotkeys).
        var hasMatchingDetectRule = false
        for callback in config.onWindowDetected where try await callback.matches(window) {
            hasMatchingDetectRule = true
            break
        }

        try await debugWindowsIfRecording(window)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            try await tryOnWindowDetected(window)
        }

        // keep-new-window-on-active-workspace: opening a new window forces the
        // app to activate, which makes macOS raise an existing window of that
        // app on another workspace and pulls AeroSpace focus there — the new
        // window is then born on that workspace, not the one the user was on.
        // When all the grouping conditions hold and no rule claimed the window,
        // rebind it back to the previously focused workspace and follow it.
        if config.keepNewWindowOnActiveWorkspace,
           !isStartup,
           !hasMatchingDetectRule,
           appHadSiblingOnBornWorkspace,
           prevWsRecent,
           let prevWs,
           prevWs != bornWorkspace
        {
            let target: NonLeafTreeNodeObject = window.isFloating ? prevWs : prevWs.rootTilingContainer
            window.bind(to: target, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            _ = window.focusWindow()
        }

        // Record the new window (on its final workspace) so updateFocusCache can
        // hold focus on it against a same-app cross-workspace steal for ~2s.
        if config.keepNewWindowOnActiveWorkspace, !isStartup, let ws = window.nodeWorkspace {
            recentlyOpenedWindow = RecentlyOpenedWindow(windowId: windowId, workspaceName: ws.name, appPid: macApp.pid, date: .now, placedByRule: hasMatchingDetectRule)
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel)
    }

    func dumpAxInfo() async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .workspace, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer:
                    break // Don't switch back on popup destruction
            }
        }
    }

    @MainActor override var title: String { get async throws { try await macApp.getAxTitle(windowId) ?? "" } }
    @MainActor override var isMacosFullscreen: Bool { get async throws { try await macApp.isMacosNativeFullscreen(windowId) == true } }
    @MainActor override var isMacosMinimized: Bool { get async throws { try await macApp.isMacosNativeMinimized(windowId) == true } }

    @MainActor
    override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    override func getAxSize() async throws -> CGSize? {
        try await macApp.getAxSize(windowId)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    func setAxFrameBlocking(_ topLeft: CGPoint?, _ size: CGSize?) async throws {
        try await macApp.setAxFrameBlocking(windowId, topLeft, size)
    }

    override func getAxRect() async throws -> Rect? {
        try await macApp.getAxRect(windowId)
    }
}

// Pure: recovers a floating window's absolute top-left from its previously-stored
// proportional position inside the workspace rect, then clamps so the window's
// (assumed) bounding box stays inside the workspace.
func computeFloatingUnhideTopLeft(
    workspaceRect: Rect,
    proportion: CGPoint,
    floatingSize: CGSize?,
) -> CGPoint {
    var newX = workspaceRect.topLeftX + workspaceRect.width * proportion.x
    var newY = workspaceRect.topLeftY + workspaceRect.height * proportion.y
    let windowWidth = floatingSize?.width ?? 0
    let windowHeight = floatingSize?.height ?? 0
    newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
    newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))
    return CGPoint(x: newX, y: newY)
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, forceTile: Bool = false) async throws {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect() else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                // Refresh lastFloatingSize from the actual AX rect so the clamp in
                // unhideFromCorner uses the window's current width, not a stale value
                // captured at registration or `layout floating`. Without this, any
                // resize between bind and workspace switch leaves the clamp using the
                // old width, so right-edge floating windows drift left on re-show.
                // Gated to floating: for tiling windows, lastFloatingSize must remain
                // the restore-on-refloat size, not the tiled rect.
                if let parent, case .floatingWindow = getChildParentRelation(child: self, parent: parent) {
                    lastFloatingSize = windowRect.size
                }
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize() else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = app.rawAppBundleId == KnownBundleId.zoom.rawValue ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = app.rawAppBundleId == KnownBundleId.zoom.rawValue ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let newTopLeft = computeFloatingUnhideTopLeft(
                    workspaceRect: nodeWorkspace.workspaceMonitor.rect,
                    proportion: prevUnhiddenProportionalPositionInsideWorkspaceRect,
                    floatingSize: lastFloatingSize,
                )
                setAxFrame(newTopLeft, nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowId: UInt32, _ macApp: MacApp, _ workspace: Workspace, window: Window?) async throws -> BindingData {
    let windowLevel = getWindowLevel(for: windowId)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel) {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window:
            // When default-window-mode = 'floating', new windows are bound
            // directly to the workspace (floating) instead of entering the
            // root tiling container. This sidesteps the tile-maximize that
            // the layout pass would otherwise apply — useful when aerospace
            // is being used purely for workspace switching and every window
            // is floated anyway via on-window-detected. Lives in this helper
            // (not getOrRegister) so it also covers relayoutWindow paths
            // like validateStillPopups (Slack's popup→window reclassify).
            config.defaultWindowMode == .floating
                ? BindingData(parent: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                : unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: mruWindow.ownIndex.orDie() + 1,
        )
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

@MainActor
func tryOnWindowDetected(_ window: Window) async throws {
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .tilingContainer, .workspace, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await onWindowDetected(window)
        case .macosPopupWindowsContainer:
            break
    }
}

@MainActor
private func onWindowDetected(_ window: Window) async throws {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    for callback in config.onWindowDetected where try await callback.matches(window) {
        _ = try await callback.run.runCmdSeq(.defaultEnv.copy(\.windowId, window.windowId), .emptyStdin)
        if !callback.checkFurtherCallbacks {
            return
        }
    }
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async throws -> Bool {
        if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != isStartup {
            return false
        }
        if let regex = matcher.windowTitleRegexSubstring, !(try await window.title).contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let appId = matcher.appId, appId != window.app.rawAppBundleId {
            return false
        }
        if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }
}
