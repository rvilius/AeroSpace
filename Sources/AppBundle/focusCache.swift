import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// Timestamp of the last physical user gesture (mouse click / keypress),
/// recorded synchronously by GlobalObserver. Used to tell a deliberate app
/// activation (Dock click, Cmd-Tab, Spotlight) from an app's background focus
/// steal: a deliberate activation closely trails a gesture, a steal does not.
@MainActor var lastUserInputDate: Date? = nil

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
        // above, but no new window is involved). Don't follow the steal.
        if isCrossWorkspaceStealToHiddenWorkspace(nativeFocused) {
            if let home = focus.windowOrNil {
                // Pull focus back onto the window the user was actually on.
                _ = home.focusWindow()
                home.nativeFocus()
                lastKnownNativeFocusedWindowId = home.windowId
            } else {
                // The focused workspace has no window to refocus. Re-assert it
                // anyway so the steal is *not* followed: following it would drag
                // the stolen window's monitor — and, cascading, the whole
                // context — onto the hidden workspace. (The empty-workspace bug:
                // opening a new window scoped to an empty workspace yanked the
                // desktop to the app's other workspace's context.) The imminent
                // new window is born here (bornWorkspace = focus.workspace).
                _ = focus.workspace.focusWorkspace()
                lastKnownNativeFocusedWindowId = nil
            }
            return
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// Whether `nativeFocused` is a focus steal to a *hidden* workspace — an app
/// activating one of its background windows on a workspace that isn't currently
/// displayed, dragging the user's visible monitor over to it. updateFocusCache
/// uses this to *not* follow such a steal.
///
/// Covers any app that raises a background window (VS Code / Electron, Spark,
/// Finder, Teams, …). Anchored on the user's current logical `focus`, which
/// still points at the user's real workspace here because AeroSpace's own
/// ctrl-1..5 navigation moves logical focus first via its command — so this
/// never fights deliberate workspace switches. Gated on the stolen workspace
/// being hidden (`!isVisible`), so focusing a window on an already-visible
/// workspace — e.g. clicking a window on the second monitor — is followed
/// normally; only steals that would yank a hidden workspace into view are
/// suppressed.
///
/// Deliberately does NOT require the focused workspace to hold a window: an
/// empty focused workspace must still suppress the steal, not follow it.
/// Otherwise opening a new window scoped to an empty workspace (e.g. a fresh
/// Hotrema) drags the desktop onto the app's other workspace's context.
@MainActor func isCrossWorkspaceStealToHiddenWorkspace(_ nativeFocused: Window?) -> Bool {
    let f = focus
    guard config.keepNewWindowOnActiveWorkspace,
          let stolen = nativeFocused,
          stolen.windowId != f.windowOrNil?.windowId,
          let stolenWs = stolen.nodeWorkspace,
          stolenWs.name != f.workspace.name,
          !stolenWs.isVisible,
          !config.focusStealAllowApps.contains(stolen.app.rawAppBundleId ?? "")
    else { return false }

    // A cross-workspace focus change that closely trails a physical user
    // gesture is a deliberate activation of an already-open app (Dock click,
    // Cmd-Tab, Spotlight) — follow it, don't treat it as a steal. Three-part
    // gate so this never re-opens the steals the guard exists to stop:
    //   1. a gesture just happened;
    //   2. the focused workspace has a real window — an empty focused workspace
    //      is ab88df1's launch-steal case (imminent new window born on it), so
    //      the gate must not fire there;
    //   3. no new-window/launch is in flight — a launch is itself a gesture, and
    //      its background raise must stay suppressed (covers ab88df1 and the VS
    //      Code new-window steal even if the raise beats window registration).
    // ponytail: temporal correlation, not causality — a real background steal
    //   within 0.5s of unrelated input on the current workspace still gets
    //   followed. Gates 2–3 kill the worst cases; the short window keeps the
    //   rest rare. 0.5 is the tunable knob.
    if let input = lastUserInputDate,
       input.distance(to: .now) < 0.5,
       f.windowOrNil != nil,
       recentlyOpenedWindow.map({ $0.date.distance(to: .now) >= 2.0 }) ?? true
    {
        return false
    }
    return true
}

/// The window focus should be held on for a detected steal, or nil when it
/// isn't a steal *or* the focused workspace is empty (no window to hold). Kept
/// for callers/tests that want the hold target directly.
@MainActor func crossWorkspaceStealHoldTarget(_ nativeFocused: Window?) -> Window? {
    isCrossWorkspaceStealToHiddenWorkspace(nativeFocused) ? focus.windowOrNil : nil
}
