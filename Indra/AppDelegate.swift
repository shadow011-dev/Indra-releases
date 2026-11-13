import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindow = MainWindowController()
    private var notch: NotchWindowController?
    private var lockScreen: LockScreenController?
    private let jobs = BackgroundJobs()
    /// v481: true once macOS itself is shutting down, restarting or logging out. Those must never wait for a fingerprint.
    private var systemIsEnding = false
    /// True while the "Quit Indra" fingerprint / password prompt is open, so a second Cmd+Q cannot stack another one.
    private var quitPromptOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Preferences.migrateVisualizerDefault()
        Trace.startStallWatch()
        FreezeTrail.startSession(build: IndraLog.appBuild)   // v544: the black box for a whole-Mac freeze
        TrackpadActuator.shared.warmUp()   // the first haptic must not wait for the motor to be found
        SceneGuard.recoverFromCrash()
        let controller = NotchWindowController(openSettings: { [weak self] in
            self?.showMainWindow()
        })
        controller.show()
        notch = controller
        lockScreen = LockScreenController(media: controller.media, levels: controller.levels)
        jobs.start(weather: controller.weather)
        // Face Lock (face unlock at the lock screen) lives inside Indra: its controllers start here.
        FaceLockHost.shared.start()
        ScreenAccess.shared.warmUp()   // v547: the Screen Recording answer is read in the background, never on the main thread
        UpdateManager.shared.startAutoCheck()   // v544: looks for a newer version on GitHub (6 s after launch, then every 10 min, after waking and when the network returns; always on)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemIsEnding = true
                IndraLog.cleanExit()   // v543: a shutdown or restart is a normal end, not an abrupt one
            }
        }

        NotificationCenter.default.addObserver(forName: .indraOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showMainWindow() }
        }
    }

    /// v481: quitting Indra (menu bar, notch right-click menu, Cmd+Q, anything) asks for a fingerprint or the password first,
    /// the same as "Quit Face Lock". Shutdown, restart and logout are not asked. With no password and no Touch ID set up
    /// there is nothing to ask, so Indra just quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // v553: an update the person has just confirmed quits Indra without asking for a fingerprint / password on the way out
        // (that question came up unseen and the update never ran).
        guard !systemIsEnding, !UpdateManager.shared.quittingForUpdate, FaceLockGate.shared.canVerify else { return .terminateNow }
        guard !quitPromptOpen else { return .terminateCancel }
        quitPromptOpen = true
        FaceLockGate.shared.require(
            title: "Quit Indra", force: true, allowCancel: true,
            onCancel: { [weak self] in
                self?.quitPromptOpen = false
                NSApp.reply(toApplicationShouldTerminate: false)
            },
            always: true,
            action: { [weak self] in
                self?.quitPromptOpen = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        )
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        IndraLog.cleanExit()
    }

    /// Launching the app again (Finder / Spotlight) no longer throws the window up: Indra lives in the notch.
    /// Settings stay one right-click away on the notch (or in the menu-bar icon). Only when the menu-bar
    /// icon is switched off would there be no way back in, so then the window opens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Preferences.menuBarIcon { showMainWindow() }
        return true
    }

    @objc private func showMainWindow() {
        mainWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
