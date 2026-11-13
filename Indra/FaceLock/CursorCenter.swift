//
//  CursorCenter.swift
//  Indra Face Lock
//
//  v482: after a face unlock the cursor goes back to the middle of the screen, so it is not left sitting on the notch.
//  Used when (1) a face scan started by hovering the notch unlocks an app, once its blur cover has gone, and
//  (2) the Mac is unlocked with the face, as soon as the desktop is back.
//

import AppKit
import CoreGraphics

@MainActor
enum CursorCenter {
    private static var installed = false
    /// Set when the lock screen's face scan matched; consumed by the "screen is unlocked" signal.
    private static var moveOnUnlockUntil = Date.distantPast

    /// Moves the cursor to the middle of the display the notch overlay uses (the main display if none is pinned).
    static func moveToCenter() {
        let screen = NotchGeometry.preferredScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let bounds = CGDisplayBounds(number)   // global display coordinates, origin top-left
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Call when the lock screen's face scan has matched and the Mac is about to unlock.
    static func moveAfterMacUnlock() {
        if LockMonitor.isScreenActuallyLocked() {
            moveOnUnlockUntil = Date().addingTimeInterval(20)
        } else {
            // The unlock signal already came in before the match was reported.
            moveToCenter()
        }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard Date() < moveOnUnlockUntil else { return }
                moveOnUnlockUntil = .distantPast
                try? await Task.sleep(for: .milliseconds(120))   // let the desktop come back first
                moveToCenter()
            }
        }
    }
}
