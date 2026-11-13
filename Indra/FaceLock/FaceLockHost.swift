//
//  FaceLockHost.swift
//  Indra Face Lock
//
//  Owns the Face Lock controllers for the whole app and starts them from Indra's app delegate (there is no second
//  app delegate and no second status item: Face Lock is a set of features inside Indra).
//

import AppKit
import Foundation

@MainActor
final class FaceLockHost {
    static let shared = FaceLockHost()

    /// The controllers every Face Lock settings page shares (camera, lock monitor, session, face store).
    let environment = FaceLockEnvironment()
    private var started = false
    private let menuBar = FaceLockMenuBar()
    /// True after "Quit Face Lock" in the menu bar: face unlock and App Lock are off for this run (Indra keeps running).
    private(set) var isFaceLockQuit = false

    private init() {}

    /// Called once from `AppDelegate.applicationDidFinishLaunching`. Creating the environment is what starts the lock /
    /// wake observers, so Face Unlock works without the Face Lock section ever being opened.
    func start() {
        guard !started else { return }
        started = true
        _ = environment
        // App Lock: the blur cover that appears when a locked app comes to the front.
        AppLockController.shared.start()
        AppLockController.shared.lockAllNow()
        menuBar.start()
        CursorCenter.install()
        // v476: picks up a change of the animation colour at once and rebuilds the animation in the new colour in the background.
        FaceScanColor.startObserving()
        // The recoloured still is built once, shortly after launch, so the first scan never pays for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            ScanAnimationHostView.prewarmStill()
        }
    }
}

extension FaceLockHost {
    /// Stops face unlock and App Lock for this run only. Settings are untouched; relaunching Indra, or "Start Face Lock",
    /// brings them back.
    func quitFaceLock() {
        guard !isFaceLockQuit else { return }
        isFaceLockQuit = true
        environment.faceUnlockCoordinator.isPaused = true
        AppLockController.shared.setPaused(true)
    }

    func startFaceLock() {
        guard isFaceLockQuit else { return }
        isFaceLockQuit = false
        environment.faceUnlockCoordinator.isPaused = false
        AppLockController.shared.setPaused(false)
    }
}

extension Notification.Name {
    /// Posted with `object: Bool`: true while the face scan animation owns the notch area (scanning, success, failure,
    /// closing), false once it is gone. Indra's own notch holds back its live activity while this is true.
    static let indraFaceScanBusyChanged = Notification.Name("indraFaceScanBusyChanged")
    /// v477: an App Lock blur cover went up or came down (see `AppLockController.isCoverShown`). Indra's own notch hides while it is up.
    static let indraAppLockCoverChanged = Notification.Name("indraAppLockCoverChanged")
}
