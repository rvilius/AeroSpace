import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // keep-new-window-on-active-workspace focus-hold guard.
        // Shortly after opening a new window, some apps (notably VS Code /
        // Electron) raise an older window of theirs on another workspace and
        // steal focus, yanking the user away. Suppress that steal and pull
        // focus back to the new window. Gated on logical `focus` still being on
        // the new window's workspace: a deliberate workspace switch moves
        // logical focus first (via its command), so this never fights the
        // user's own ctrl-1..5 navigation; same-workspace focus changes are
        // also untouched (the steal must be to a *different* workspace).
        if config.keepNewWindowOnActiveWorkspace,
           let r = recentlyOpenedWindow,
           r.date.distance(to: .now) < 2.0,
           let stolen = nativeFocused,
           stolen.windowId != r.windowId,
           stolen.app.pid == r.appPid,
           stolen.nodeWorkspace?.name != r.workspaceName,
           focus.workspace.name == r.workspaceName,
           let newWindow = Window.get(byId: r.windowId),
           newWindow.nodeWorkspace?.name == r.workspaceName
        {
            _ = newWindow.focusWindow()
            newWindow.nativeFocus()
            lastKnownNativeFocusedWindowId = r.windowId
            return
        }

        // Cross-workspace focus-steal guard (sibling of the new-window guard
        // above, but no new window is involved). Pull focus back to where the
        // user actually is instead of following the steal.
        if let home = crossWorkspaceStealHoldTarget(nativeFocused) {
            _ = home.focusWindow()
            home.nativeFocus()
            lastKnownNativeFocusedWindowId = home.windowId
            return
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// If `nativeFocused` is a focus steal to a *hidden* workspace — an app
/// activating one of its background windows on a workspace that isn't currently
/// displayed, dragging the user's visible monitor over to it — returns the
/// window focus should be held on instead. nil if it isn't such a steal.
///
/// Covers any app that raises a background window (VS Code / Electron, Spark,
/// Finder, Teams, …). Anchored on the user's current logical `focus`, which
/// still points at the user's real window here because AeroSpace's own
/// ctrl-1..5 navigation moves logical focus first via its command — so this
/// never fights deliberate workspace switches. Gated on the stolen workspace
/// being hidden (`!isVisible`), so focusing a window on an already-visible
/// workspace — e.g. clicking a window on the second monitor — is followed
/// normally; only steals that would yank the visible monitor are suppressed.
@MainActor func crossWorkspaceStealHoldTarget(_ nativeFocused: Window?) -> Window? {
    let f = focus
    guard config.keepNewWindowOnActiveWorkspace,
          let stolen = nativeFocused,
          let home = f.windowOrNil,
          stolen.windowId != home.windowId,
          let stolenWs = stolen.nodeWorkspace,
          stolenWs.name != f.workspace.name,
          !stolenWs.isVisible,
          home.nodeWorkspace?.name == f.workspace.name,
          !config.focusStealAllowApps.contains(stolen.app.rawAppBundleId ?? "")
    else { return nil }
    return home
}
