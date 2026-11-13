import AppKit
import SwiftUI

/// Last line of defence for the edge light: independent of RingLight's own timer, it keeps checking and removes any
/// edge-light window that exists while no locked app's blur cover is on screen and scanning.
@MainActor
enum RingLightGuard {
    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        // Common run-loop modes: keeps firing while a menu is open, a dialog is up or the mouse is dragging.
        let t = Timer(timeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sweep() }
            }
        }
    }

    static func sweep() {
        let allowed = AppLockController.shared.isCoverScanning
            && AppLockController.shared.scanningCoverScreen != nil   // v543: the blur cover must really be on screen
            && NotchOverlayController.shared.phase == .scanning
        guard !allowed else { return }
        // Remove every edge-light window, including any that RingLight lost track of.
        for window in NSApp.windows where window is NSPanel
            && window.contentView is NSHostingView<RingLightView> {
            window.alphaValue = 0
            window.orderOut(nil)
        }
        RingLight.shared.hide()
    }
}
