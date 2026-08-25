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

private func isClickOnDock() -> Bool {
    guard let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .first?.processIdentifier else { return false }
    let point = mouseLocation
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else { return false }
    for w in windows {
        guard let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.contains(point) else { continue }
        return (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPid
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
                MainActor.assumeIsolated { lastUserInputDate = .now }
            }
        }

        // Hyper-chord hotkeys (Caps Lock remap + key, registered by Raycast &
        // co. via RegisterEventHotKey) are consumed by the window server and
        // never reach the keyDown monitor above. The modifier press itself is
        // not consumed though — record the gesture on hyper-down instead.
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            if isHyperChord(event.modifierFlags) {
                MainActor.assumeIsolated { lastUserInputDate = .now }
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
            MainActor.assumeIsolated {
                if onDock { lastUserInputDate = .now }
                logFocusGuard("mouseUp dock=\(onDock) at=\(mouseLocation)")
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
