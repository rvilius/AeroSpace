import AppKit
import Common

/// Whether the mouse currently sits on a Dock window (icon strip or a
/// minimized-window tile). Frontmost window under the cursor wins —
/// CGWindowListCopyWindowInfo returns front-to-back order.
/// Whether a keyDown is a deliberate *app-switch* gesture that can activate a
/// window on another (hidden) workspace: Cmd-Tab / Cmd-Shift-Tab (app switcher)
/// or Cmd-` / Cmd-~ (window cycle within the front app). Ordinary Cmd shortcuts
/// (Cmd-C/V/S/Z/W/F/arrows…) are NOT app switches — recording them kept the 0.5s
/// deliberate-activation gate perpetually open during normal work and let real
/// background steals through. This is the keyboard twin of the every-click mouse
/// bug fixed by gating the mouse on the Dock (b06b6f4); `.command`-only matched
/// far more than the "app-switch gestures" its comment claimed.
func isAppSwitchKeyGesture(_ modifierFlags: NSEvent.ModifierFlags, _ keyCode: UInt16) -> Bool {
    // kVK_Tab = 48, kVK_ANSI_Grave (`) = 50
    if modifierFlags.contains(.command) && (keyCode == 48 || keyCode == 50) { return true }
    return isHyperChord(modifierFlags)
}

/// A full hyper chord (⌃⌥⇧⌘, e.g. a Caps Lock remap driving global app
/// hotkeys) is never ordinary typing — always a deliberate jump. Checked on
/// flagsChanged too, because a RegisterEventHotKey-consumed chord (Raycast &
/// co.) never reaches keyDown global monitors — only its modifier press does.
func isHyperChord(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.isSuperset(of: [.command, .control, .option, .shift])
}

/// True when the mouse is over the Dock's icon strip. Asks the Dock's AX tree
/// for its AXList frame (CG top-left coords, same space as mouseLocation).
/// Not CGWindowList: the Dock owns a full-screen layer-20 window, so a
/// window hit-test says "Dock" for every click on the main display.
private let launcherBundleIds: Set<String> = ["com.raycast.macos", "com.apple.Spotlight"]
/// Raycast/Spotlight run as non-activating panels — they never become the
/// frontmost app — but they own an on-screen window only while open.
private func isLauncherOnScreen() -> Bool {
    let pids = Set(NSWorkspace.shared.runningApplications
        .filter { launcherBundleIds.contains($0.bundleIdentifier ?? "") }
        .map { $0.processIdentifier })
    if pids.isEmpty { return false }
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], CGWindowID(0)) as? [[String: Any]] else { return false }
    return windows.contains { pids.contains((($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value) ?? -1) }
}

private func isClickOnDock() -> Bool {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .first?.processIdentifier else { return false }
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXChildrenAttribute as CFString, &kids) == .success,
          let children = kids as? [AXUIElement] else { return false }
    let point = mouseLocation
    for c in children {
        var role: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXListRole,
              AXUIElementCopyAttributeValue(c, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(c, kAXSizeAttribute as CFString, &size) == .success else { continue }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &sz)
        return CGRect(origin: p, size: sz).contains(point)
    }
    return false
}

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        Task { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        // Record physical user gestures for the deliberate-activation gate in
        // updateFocusCache (see focusCache.swift / lastUserInputDate). Written
        // synchronously — the monitor callback runs on the main thread (AppKit
        // event-monitor contract), so this beats any later didActivate-triggered
        // refresh that reads it.
        //
        // Keyboard is gated on the app-switch gestures only (Cmd-Tab, Cmd-`).
        // Recording on *every* Cmd shortcut — Cmd-C/V/S/Z/W/F/arrows — kept the
        // 0.5s gate open all through normal work and let real background steals
        // through (VS Code's self-activation landing within 0.5s of any Cmd
        // press). That was the keyboard twin of the every-click mouse bug; see
        // isAppSwitchKeyGesture.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if isAppSwitchKeyGesture(event.modifierFlags, event.keyCode) {
                MainActor.assumeIsolated { lastUserInputDate = .now; lastGestureWasDockClick = false }
            } else if isLauncherOnScreen() {
                // Typing/Enter in Raycast or Spotlight: the launcher's activation
                // of an app is as deliberate as a Dock click, so it may follow
                // from an empty workspace too.
                MainActor.assumeIsolated {
                    lastUserInputDate = .now
                    lastGestureWasDockClick = true
                    logFocusGuard("launcher-key code=\(event.keyCode)")
                }
            }
        }

        // Hyper-chord hotkeys (Caps Lock remap + key, registered by Raycast &
        // co. via RegisterEventHotKey) are consumed by the window server and
        // never reach the keyDown monitor above. The modifier press itself is
        // not consumed though — record the gesture on hyper-down instead.
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            if isHyperChord(event.modifierFlags) {
                MainActor.assumeIsolated { lastUserInputDate = .now; lastGestureWasDockClick = false }
            }
        }

        // Mouse is gated on the Dock: a click can only *deliberately* activate a
        // hidden-workspace window through the Dock (icon / minimized-window
        // click). Ordinary window clicks land on the visible workspace, so
        // recording them only kept the 0.5s gate perpetually open during normal
        // mouse work and let real background steals through (the mouse twin of
        // the every-keystroke bug above).
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            let onDock = isClickOnDock()
            if onDock {
                MainActor.assumeIsolated {
                    lastUserInputDate = .now
                    lastGestureWasDockClick = true
                    logFocusGuard("dock-click at=\(mouseLocation)")
                }
            }
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
