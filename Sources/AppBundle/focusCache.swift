import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// Timestamp of the last physical user gesture (mouse click / keypress),
/// recorded synchronously by GlobalObserver. Used to tell a deliberate app
/// activation (Dock click, Cmd-Tab, Spotlight) from an app's background focus
/// steal: a deliberate activation closely trails a gesture, a steal does not.
@MainActor var lastUserInputDate: Date? = nil
/// Whether the gesture behind lastUserInputDate was a Dock-strip click. A Dock
/// click can only mean "bring this app forward", so it may follow even from an
/// empty focused workspace (ab88df1's empty-workspace hold is for hotkey-driven
/// new windows, where the raise of an existing hidden window is a side effect).
@MainActor var lastGestureWasDockClick = false

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
          !stolenWs.isVisible
    else { return false }
    let stealDesc = "\(stolen.app.rawAppBundleId ?? "?") id=\(stolen.windowId) \(f.workspace.name) -> \(stolenWs.name)"
    if config.focusStealAllowApps.contains(stolen.app.rawAppBundleId ?? "") {
        logFocusGuard("FOLLOW allow-app \(stealDesc)")
        return false
    }

    // A brand-new window that an on-window-detected rule routed to a hidden
    // workspace, activating within launch-scale time of a gesture, is the
    // user's hotkey landing (cold Safari profile launch: hyper-N -> Safari
    // starts -> window born -> rule moves it -> Safari focuses it, 1-3s after
    // the keypress). The rule is the user's explicit routing; follow it. The
    // gesture requirement keeps login auto-launches (Slack -> Corp-Opus) from
    // yanking focus. ponytail: 5s is the cold-launch knob.
    if let r = recentlyOpenedWindow, r.windowId == stolen.windowId, r.placedByRule,
       let input = lastUserInputDate, input.distance(to: .now) < 5.0
    {
        logFocusGuard("FOLLOW new-rule-window(\(Int(input.distance(to: .now) * 1000))ms) \(stealDesc)")
        return false
    }

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
    //   within 0.5s of a Dock click or Cmd-keypress still gets followed.
    //   Ordinary typing and window clicks no longer open this gate (see
    //   GlobalObserver: Cmd-gated keyboard, Dock-gated mouse), so the race is
    //   now rare by construction. 0.5 is the tunable knob.
    if let input = lastUserInputDate,
       input.distance(to: .now) < 0.5,
       f.windowOrNil != nil || lastGestureWasDockClick,
       recentlyOpenedWindow.map({ $0.date.distance(to: .now) >= 2.0 }) ?? true
    {
        logFocusGuard("FOLLOW gesture(\(Int(input.distance(to: .now) * 1000))ms) \(stealDesc)")
        return false
    }
    let age = lastUserInputDate.map { "\(Int($0.distance(to: .now) * 1000))ms" } ?? "none"
    logFocusGuard("SNAP-BACK gesture=\(age) focusedWin=\(f.windowOrNil != nil) recentOpen=\(recentlyOpenedWindow.map { Int($0.date.distance(to: .now) * 1000) } ?? -1)ms \(stealDesc)")
    return true
}

/// Appends cross-workspace focus-guard decisions to ~/.config/aerospace/aerospace.log
/// (same file the watchdog/snap-size helpers write to) so post-hoc "why was I
/// yanked to workspace X" questions are answerable.
@MainActor func logFocusGuard(_ msg: String) {
    let path = NSHomeDirectory() + "/.config/aerospace/aerospace.log"
    let line = "\(ISO8601DateFormatter().string(from: Date())) [focus-guard] \(msg)\n"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let h = FileHandle(forWritingAtPath: path), let data = line.data(using: .utf8) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }
}

/// The window focus should be held on for a detected steal, or nil when it
/// isn't a steal *or* the focused workspace is empty (no window to hold). Kept
/// for callers/tests that want the hold target directly.
@MainActor func crossWorkspaceStealHoldTarget(_ nativeFocused: Window?) -> Window? {
    isCrossWorkspaceStealToHiddenWorkspace(nativeFocused) ? focus.windowOrNil : nil
}
