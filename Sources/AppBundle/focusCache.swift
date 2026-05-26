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
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
