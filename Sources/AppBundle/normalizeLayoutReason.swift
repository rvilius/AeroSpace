@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel) {
            try await popup.relayoutWindow(on: focus.workspace)
            try await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind, prevWorkspaceName: nil)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        // Remember the workspace before the bind below drops it — the
                        // minimized container is global, so this is the only record left.
                        window.layoutReason = .macos(prevParentKind: parent.kind, prevWorkspaceName: window.nodeWorkspace?.name)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind, prevWorkspaceName: nil)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind, let prevWorkspaceName):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    let target = restoreWorkspace(prevWorkspaceName: prevWorkspaceName, fallback: workspace)
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: target)
                }
        }
    }
}

/// The workspace a window exiting a macOS-native state should be restored to.
///
/// Minimized windows are called with `focus.workspace` as the fallback, which on a
/// multi-monitor setup is always the *primary* monitor's workspace — so without the
/// remembered origin a window minimized on a secondary monitor can never come back to it,
/// it lands on the primary instead.
///
/// The origin only wins while it is still on screen. Restoring onto a hidden workspace
/// would make clicking the app's Dock icon look like it did nothing, so that case keeps
/// the old behaviour and brings the window to the user instead.
@MainActor
func restoreWorkspace(prevWorkspaceName: String?, fallback: Workspace) -> Workspace {
    guard let prevWorkspaceName else { return fallback }
    let origin = Workspace.get(byName: prevWorkspaceName)
    return origin.isVisible ? origin : fallback
}

@MainActor
func exitMacOsNativeUnconventionalState(window: Window, prevParentKind: NonLeafTreeNodeKind, workspace: Workspace) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            // Same gate as closedWindowsCache: when default-window-mode =
            // 'floating', a window exiting native fullscreen/minimize/hide
            // that was previously tiled must not be force-tiled back —
            // forceTile=true bypasses unbindAndGetBindingDataForNewWindow's
            // floating reroute and the next layoutWorkspaces pass would
            // re-maximize the window.
            if config.defaultWindowMode == .floating {
                window.bindAsFloatingWindow(to: workspace)
            } else {
                try await window.relayoutWindow(on: workspace, forceTile: true)
            }
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace)
    }
}
