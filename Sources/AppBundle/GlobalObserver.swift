import AppKit
import Common

/// Whether the mouse currently sits on a Dock window (icon strip or a
/// minimized-window tile). Frontmost window under the cursor wins —
/// CGWindowListCopyWindowInfo returns front-to-back order.
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
        // Keyboard is gated on Cmd held: that captures the native app-switch
        // gestures (Cmd-Tab, Cmd-`) while ignoring ordinary typing. Recording on
        // *every* keystroke would keep the 0.5s gate perpetually open during
        // typing and let real background steals through — the exact bug the guard
        // exists to stop.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) {
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
            if isClickOnDock() {
                MainActor.assumeIsolated { lastUserInputDate = .now }
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
