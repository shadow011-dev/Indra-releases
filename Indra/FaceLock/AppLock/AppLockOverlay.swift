import AppKit
import SwiftUI
import LocalAuthentication

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onQuitShortcut: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "q",
           let handler = onQuitShortcut {
            handler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AppLockOverlay {
    private enum Interruption { case appSwitch, screenLock }

    private struct WindowInfo {
        let frame: NSRect
        let topWindowNumber: Int
    }

    /// Which overlay currently owns the notch UI.
    private static weak var notchOwner: AppLockOverlay?

    /// Full-screen level: above the Dock and the menu bar.
    private static let fullScreenLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    private let maxFaceAttempts = 5
    private let fadeDuration: TimeInterval = 0.18
    private let modeAnimationDuration: TimeInterval = AnimationFlags.consistentTiming ? Motion.base : 0.25

    let pid: pid_t
    /// v541: the start time of the process this cover protects (a quit and reopen is another launch, never this cover).
    let launchDate: Date?
    private let appName: String
    private let panel: KeyablePanel
    private let blurView = NSVisualEffectView()
    private let state = AppLockState()
    private weak var faceScanner: FaceUnlockCoordinator?
    private let onUnlocked: () -> Void

    private var timer: Timer?
    private(set) var isScanning = false
    /// True only while this app's blur cover is really on screen and its face scan is running.
    var isCoverScanning: Bool {
        isScanning && isTargetActive && isCovering && !finished
    }
    /// The locked app is the one in front, so a face scan may run and the whole screen is covered.
    private var isTargetActive = false { didSet { syncCoverFlag() } }
    private let createdAt = Date()
    private var activeSince = Date.distantFuture
    private var finished = false { didSet { syncCoverFlag() } }
    private var quitMonitor: Any?
    /// Still protecting the app: following it and keeping the panel up, in front or not.
    private var isCovering = false { didSet { syncCoverFlag() } }
    /// True while the panel covers the whole screen; false while it only covers the app's window.
    private var isFullScreenMode = false
    private var frameAnimationEnd = Date.distantPast
    private var panelShown = false { didSet { syncCoverFlag() } }

    /// v477: true while this app's full-screen blur cover is really on screen. Indra's own notch (hover, live activity,
    /// the closed notch itself) stays away for as long as any cover is up; only the face scan animation may appear there.
    var isCoverShown: Bool { panelShown && isTargetActive && isCovering && !finished }
    /// The screen the cover is on (nil while it has no window on any screen).
    var coverScreen: NSScreen? { panel.screen }
    private var lastCoverShown = false
    private func syncCoverFlag() {
        let now = isCoverShown
        guard now != lastCoverShown else { return }
        lastCoverShown = now
        NotificationCenter.default.post(name: .indraAppLockCoverChanged, object: nil)
    }
    private var visibilityToken = 0
    private var missingFrameTicks = 0
    private var inactiveSince: Date?
    /// True once the locked app has really been the front app for a moment. Only then may Indra close it for "leaving".
    private var confirmedFront = false
    private var frontSince: Date?
    private var leaving = false
    private var hiddenForLeave = false
    private var hadWindow = false
    private var goneTicks = 0
    private var topWindowNumber: Int?
    private var faceTask: Task<Void, Never>?
    private var activeGeneration = 0
    private var hasScanned = false
    private var failedFaceAttempts = 0
    private var closeRequests = 0
    /// True while the system Touch ID dialog is up. That dialog belongs to another process and takes focus,
    /// which must not be mistaken for switching apps.
    private var isAuthenticating = false
    private var interruption: Interruption?

    init(app: NSRunningApplication, faceScanner: FaceUnlockCoordinator?, onUnlocked: @escaping () -> Void) {
        pid = app.processIdentifier
        launchDate = app.launchDate
        appName = app.localizedName ?? "This app"
        self.faceScanner = faceScanner
        self.onUnlocked = onUnlocked

        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 16
        blurView.layer?.masksToBounds = true
        panel.contentView = blurView

        let view = AppLockView(
            appName: appName,
            state: state,
            isFirstUse: false,
            onRetryFace: { [weak self] in self?.startFaceCheck() },
            onTouchID: { [weak self] in self?.tryTouchID() },
            onSubmitPassword: { [weak self] password in self?.submit(password) ?? false },
            onCloseApp: { [weak self] in self?.closeApp() }
        )
        let host = NSHostingView(rootView: view)
        host.frame = blurView.bounds
        host.autoresizingMask = [.width, .height]
        blurView.addSubview(host)
    }

    // MARK: - App switching and screen lock

    /// The locked app came to the front (first time, or the user came back to it).
    func targetActivated() {
        guard !finished else { return }
        let returning = !isTargetActive
        state.compact = false
        inactiveSince = nil
        leaving = false
        hiddenForLeave = false
        if returning { activeSince = Date() }
        state.isUnlocked = false
        isTargetActive = true
        isCovering = true
        updatePanelLevel()
        startTracking()
        if panelShown {
            panel.makeKey()
            panel.makeKeyAndOrderFront(nil)
        }
        if scansOnDemand {
            // v476: no automatic scan. Wait for a hover on the notch or a tap on the face button.
            if !isScanning { waitForFaceRequest(message: (!hasScanned || returning) ? Self.hoverPrompt : nil) }
        } else if !hasScanned {
            startFaceCheck()
        } else if returning, !isScanning, state.canRetryFace {
            switch interruption {
            case .appSwitch:
                state.status = "Face check stopped because you switched apps. Tap Try face again."
            case .screenLock:
                // v490: the Mac was locked (and has now been unlocked, by face or any other way). That is not a failed
                // attempt, so the face check simply starts again by itself instead of waiting for a tap.
                startFaceCheck()
            case nil:
                state.status = "Tap Try face again to scan your face."
            }
        }
    }

    /// The user switched to another app. Leaving mid-scan counts as a failed face check.
    /// The full-screen cover shrinks back to the locked app's own window, so it never covers the app now in front.
    func targetDeactivated() {
        guard isTargetActive, !isAuthenticating else { return }
        Self.debugNote("\(appName): lost focus to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (scanning: \(isScanning))")
        isTargetActive = false

        if isScanning {
            cancelScan()
            interruption = .appSwitch
            failedFaceAttempts += 1
            if failedFaceAttempts >= maxFaceAttempts {
                state.status = "Too many face attempts. Use Fingerprint or Password."
                state.canRetryFace = false
            } else {
                state.status = "Face check stopped because you switched apps."
                state.canRetryFace = true
            }
        }
        releaseNotch()
        updatePanelLevel()
        placeAboveLockedWindow()
        quitBecauseSwitched()
    }

    /// Another app took focus. Right after a locked app opens (for example from Spotlight, whose window closes and
    /// briefly hands focus around) that is often just a blip, so wait a moment and only react if the locked app
    /// really is no longer in front.
    func targetDeactivatedWhenSettled() {
        guard isTargetActive else { return }
        if Date().timeIntervalSince(activeSince) > 2 {
            targetDeactivated()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !self.finished, self.isTargetActive else { return }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != self.pid,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.targetDeactivated()
            }
        }
    }

    /// Tiny text log in ~/Library/Application Support/Indra/debug.log (the system log hides our messages).
    static func debugNote(_ text: String) {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("Indra", isDirectory: true)
        let file = dir.appendingPathComponent("debug.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        LogTrim.trimIfNeeded(file)
        let line = "\(Date()) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Set to true to force-quit the locked app if it ignores the polite quit request
    /// (for example it is waiting on a "save changes?" dialog). Unsaved work in it would be lost.
    private static let forceQuitOnSwitch = false

    /// The user opened another app without unlocking this one: quit the locked app so it can't
    /// sit minimized in Stage Manager. Only acts when a different app really is in front, so
    /// our own panel or the Touch ID dialog taking focus never triggers it.
    private func quitBecauseSwitched() {
        guard confirmedFront,
              Date().timeIntervalSince(createdAt) > 1.5,
              Date().timeIntervalSince(activeSince) > 0.4,
              let front = NSWorkspace.shared.frontmostApplication,
              front.activationPolicy == .regular,
              front.processIdentifier != pid,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        Self.debugNote("\(appName): closing because another app came to the front (\(front.localizedName ?? "?"))")
        leaving = true
        app.hide()
        app.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !app.isTerminated, Self.forceQuitOnSwitch else { return }
            app.forceTerminate()
        }
    }

    /// The locked app disappeared (hidden, minimized, Stage Manager sidebar) while still locked: close it.
    private func quitBecauseGone(_ app: NSRunningApplication) {
        guard confirmedFront, Date().timeIntervalSince(createdAt) > 1.5, !finished else { return }
        goneTicks = 0
        Self.debugNote("\(appName): closing because its window disappeared")
        isCovering = false
        app.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !app.isTerminated, Self.forceQuitOnSwitch else { return }
            app.forceTerminate()
        }
    }

    /// Hides the app at once (so it cannot sit in Stage Manager), then asks it to quit.
    private func quitBecauseLeft(_ app: NSRunningApplication) {
        Self.debugNote("\(appName): closing because it left focus (front is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        leaving = true
        app.hide()
        app.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !app.isTerminated, Self.forceQuitOnSwitch else { return }
            app.forceTerminate()
        }
    }

    /// The Mac locked or went to sleep. Stops any scan (this is not counted as a failed attempt).
    func screenLocked() {
        startWaitTask?.cancel()
        startWaitTask = nil
        let wasActive = isTargetActive
        isTargetActive = false

        if isScanning {
            cancelScan()
            interruption = .screenLock
            state.status = "Face check stopped because the Mac was locked."
            state.canRetryFace = failedFaceAttempts < maxFaceAttempts
        } else if wasActive {
            interruption = .screenLock
        }
        releaseNotch(immediately: true)
        updatePanelLevel()
    }

    /// Immediate teardown (app quit).
    func dismiss() {
        startWaitTask?.cancel()
        startWaitTask = nil
        RingLight.shared.hide()
        levelToken &+= 1
        hideEdgeStrips()
        MenuBarIconTinter.shared.setCover(self, shown: false)
        if let monitor = quitMonitor {
            NSEvent.removeMonitor(monitor)
            quitMonitor = nil
        }
        isCovering = false
        isTargetActive = false
        stopTracking()
        cancelScan()
        releaseNotch(immediately: true)
        visibilityToken &+= 1
        panelShown = false
        panel.orderOut(nil)
    }

    // MARK: - Close app

    /// First tap asks the app to quit politely; a second tap force-quits if it is stuck
    /// (for example waiting on a "save changes?" dialog hidden behind the blur).
    private func closeApp() {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        closeRequests += 1
        cancelScan()
        releaseNotch()
        state.canRetryFace = failedFaceAttempts < maxFaceAttempts

        if closeRequests == 1 {
            state.status = "Closing \(appName)…"
            app.terminate()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !app.isTerminated else { return }
                self.state.status = "\(self.appName) didn't close (it may be asking to save). Tap Close app again to force quit."
            }
        } else {
            state.status = "Force quitting \(appName)…"
            app.forceTerminate()
        }
    }

    // MARK: - Face check

    /// v476: App Lock setting "Scan only on notch hover or button". The face scan (and the notch animation) then starts
    /// only when the cursor goes to the notch or the face button on the cover is pressed, never by itself.
    /// v482: this scan was started by hovering the notch, so the cursor goes back to the centre once the cover is gone.
    private var scanStartedByHover = false

    private var scansOnDemand: Bool {
        let defaults = UserDefaults.standard
        guard (defaults.object(forKey: "appLockUseFace") as? Bool) ?? true else { return false }
        return defaults.bool(forKey: "appLockScanOnHover")
    }

    /// v525: "Face check first" is on (the face button, the space bar and the notch only mean something then).
    private var usesFace: Bool {
        (UserDefaults.standard.object(forKey: "appLockUseFace") as? Bool) ?? true
    }

    /// v525: whether the notch should be parked so a hover starts a scan. With "Scan only on notch hover or button" ON that is
    /// always; with it OFF the first scan starts by itself, and once that first try has ended (and the notch has collapsed
    /// while the cover is still up) a hover on the notch starts the next one, exactly like the ON mode.
    private var hoverRearmWanted: Bool { usesFace && (scansOnDemand || hasScanned) }

    private var notchAvailableForHover: Bool { FaceLockSettings.shared.showUnlockAnimation }

    private static var hoverPrompt: String {
        FaceLockSettings.shared.showUnlockAnimation
            ? "Move your cursor to the notch, or tap Scan face, to unlock."
            : "Tap Scan face to unlock."
    }

    /// Shows the face button and parks the notch so a hover starts the scan.
    private func waitForFaceRequest(message: String?) {
        guard isTargetActive, !isScanning, !finished else { return }
        guard failedFaceAttempts < maxFaceAttempts else { return }
        if let message { state.status = message }
        if scansOnDemand { state.retryTitle = "Scan face" }   // v525: with the option off the button keeps "Try face again"
        state.canRetryFace = true
        guard notchAvailableForHover else { return }
        let notch = NotchOverlayController.shared
        guard !notch.hoverScanArmed else { return }
        guard notch.phase == .closed, !notch.isArmed else { return }
        Self.notchOwner = self
        notch.armForHoverScan { [weak self] in self?.startFaceCheck() }
    }

    /// v506: with "Scan only on notch hover or button" on (v525: and off), the space bar also starts the face scan on the cover (like a tap on
    /// "Scan face"). True while this cover is up, waiting for that request, and the person is not typing a password in it
    /// (a space inside the password must never start a scan).
    var wantsSpaceBar: Bool {
        // v525: whatever the "Scan only on notch hover or button" setting says: when no scan is running (and one can be
        // started) the space bar starts it. Before, only the ON mode listened.
        guard usesFace, isTargetActive, isCoverShown, !isScanning, !finished, !isAuthenticating,
              failedFaceAttempts < maxFaceAttempts, state.canRetryFace else { return false }
        return (panel.firstResponder as? NSTextView)?.isEditable != true
    }

    /// The space bar was pressed while `wantsSpaceBar` was true (see AppLockController).
    func spaceBarPressed() {
        guard wantsSpaceBar else { return }
        Trace.log("APPLOCK: \(appName): the space bar starts the face scan")
        startFaceCheck()
    }

    /// v481: "scan only on hover" must survive anything that takes the parked notch away while the cover is still up. The
    /// case that broke: the Mac is locked while the app is covered, unlocked with the face, and the unlock animation (or
    /// the unlock's own tidy-up) removed or was still using the notch at the moment this cover asked for it, so nothing
    /// was parked and a hover did nothing. Checked on every tracking tick; parks the notch again as soon as it is free.
    private func keepHoverScanParked() {
        // v525: also with "Scan only on notch hover or button" OFF, once the first scan has run (see `hoverRearmWanted`); never
        // while a start is still waiting for the unlock to settle.
        guard hoverRearmWanted, notchAvailableForHover, isTargetActive, !isScanning, !finished, !isAuthenticating,
              failedFaceAttempts < maxFaceAttempts, startWaitTask == nil else { return }
        guard !LockMonitor.isScreenActuallyLocked() else { return }
        let notch = NotchOverlayController.shared
        guard !notch.hoverScanArmed, !notch.isArmed, notch.phase == .closed else { return }
        guard Self.notchOwner == nil || Self.notchOwner === self else { return }
        waitForFaceRequest(message: nil)
    }

    /// After a scan that did not unlock: once the notch has finished its failure animation and gone, park it again so the
    /// next hover can scan again.
    private func rearmHoverWhenNotchIdle() {
        Task { @MainActor [weak self] in
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !self.finished, self.isTargetActive, !self.isScanning else { return }
                let notch = NotchOverlayController.shared
                if notch.phase == .closed, !notch.isArmed {
                    if Self.notchOwner == nil || Self.notchOwner === self { self.waitForFaceRequest(message: nil) }
                    return
                }
            }
        }
    }

    /// v490: set while a start is waiting for the unlock to settle (see `startFaceCheckWhenReady`).
    private var startWaitTask: Task<Void, Never>?

    /// Why a scan cannot start this very moment although it will be able to in a second: the screen still reports being
    /// locked, or the lock screen's own success animation is still using the notch after a face unlock.
    private func faceStartBlocker() -> String? {
        if LockMonitor.isScreenActuallyLocked() { return "locked" }
        if FaceLockSettings.shared.showUnlockAnimation {
            let phase = NotchOverlayController.shared.phase
            // v518: with "Scan only on notch hover or button" ON, the lock screen's unlock animation is played out to the end
            // (success, then the collapse) before the locked app's scan starts. With it OFF the notch skips its collapse and
            // goes straight into this scan (see `startFaceCheckWhenReady`).
            if phase == .success || phase == .collapsing { return "notch busy" }
        }
        return nil
    }

    /// Waits (at most about 5 seconds) for `faceStartBlocker` to clear, then starts the scan. Right after a face unlock the
    /// desktop is back before the lock screen's animation has finished; starting then either found the screen still
    /// "locked" (and gave up with a message) or fought the animation for the notch (and nothing appeared).
    private func startFaceCheckWhenReady() {
        startWaitTask?.cancel()
        state.status = "Looking for your face…"
        state.canRetryFace = false
        startWaitTask = Task { @MainActor [weak self] in
            // v518: "Scan only on notch hover or button" ON: wait for the previous scan's success animation AND its collapse to
            // finish (about 2.5 s; the loop allows 6 s), then open this scan. OFF (v496): asked once up front and again every
            // tick (cheap): while the previous scan's success is still playing the notch keeps it, then skips the collapse and
            // opens this scan directly, so the unlock collapse never shows and this scan replaces it.
            let notch = NotchOverlayController.shared
            let waitsForCollapse = UserDefaults.standard.bool(forKey: "appLockScanOnHover")
            for _ in 0..<60 {
                if !waitsForCollapse, FaceLockSettings.shared.showUnlockAnimation { notch.requestChainedScan() }
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, !self.finished, self.isTargetActive, !self.isScanning else {
                    notch.cancelChainedScan()
                    return
                }
                if self.faceStartBlocker() == nil { break }
            }
            guard let self, !Task.isCancelled, !self.finished, self.isTargetActive, !self.isScanning else {
                notch.cancelChainedScan()
                return
            }
            self.startWaitTask = nil
            self.startFaceCheck(ignoringBlockers: true)
        }
    }

    private func startFaceCheck(ignoringBlockers: Bool = false) {
        guard isTargetActive else { return }
        guard (UserDefaults.standard.object(forKey: "appLockUseFace") as? Bool) ?? true else {
            state.status = ""
            state.canRetryFace = false
            releaseNotch()
            return
        }
        guard !isScanning else { return }
        guard failedFaceAttempts < maxFaceAttempts else {
            state.status = "Too many face attempts. Use Fingerprint or Password."
            state.canRetryFace = false
            releaseNotch()
            return
        }
        if !ignoringBlockers, !isScanning, faceStartBlocker() != nil {
            startFaceCheckWhenReady()
            return
        }
        guard let scanner = faceScanner ?? AppLockController.shared.faceScanner else {
            state.status = "Face scanner is not connected."
            state.canRetryFace = true
            releaseNotch()
            return
        }
        if let reason = scanner.appLockFaceUnavailableReason {
            state.status = "Face check unavailable: " + reason
            state.canRetryFace = true
            releaseNotch()
            return
        }

        scanStartedByHover = NotchOverlayController.shared.consumeHoverStart()
        hasScanned = true
        isScanning = true
        interruption = nil
        state.canRetryFace = false
        state.retryTitle = "Try face again"
        state.status = "Looking for your face…"

        AppLockScanGate.generation &+= 1
        let generation = AppLockScanGate.generation
        activeGeneration = generation
        NSLog("AppLock: %@ starting scan %ld", appName, generation)

        let showNotch = FaceLockSettings.shared.showUnlockAnimation
        if showNotch {
            Self.notchOwner = self
            // A hover retry has already put the notch into scanning; only show it if it isn't.
            if NotchOverlayController.shared.phase != .scanning {
                NotchOverlayController.shared.present(onRetry: { [weak self] in
                    self?.startFaceCheck()
                })
            }
            // Self-repair: if the scan is running but the notch never opened (or was closed by something else), open it again.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.isScanning, self.isTargetActive, Self.notchOwner === self,
                      NotchOverlayController.shared.phase == .closed else { return }
                NotchOverlayController.shared.present(onRetry: { [weak self] in
                    self?.startFaceCheck()
                })
            }
        }

        faceTask = Task { [weak self] in
            let result = await scanner.runAppLockFaceScan(
                duration: TimeInterval(FaceLockSettings.shared.faceDetectionSeconds),
                generation: generation
            )
            guard let self, self.activeGeneration == generation, !Task.isCancelled else { return }
            self.isScanning = false
            guard self.isTargetActive else { return }
            self.handleFaceResult(result, showNotch: showNotch)
        }
        watchScan(generation: generation)
    }

    /// v543: the scan animation and the scan itself can never come apart.
    ///  - A scan that is still "running" long after its time is up (the camera never started, the task was dropped) is ended here,
    ///    so "Try face again" works again instead of being ignored because a scan is still marked as running.
    ///  - A scan that has ended while the notch still plays the scanning animation (nothing is looking at the face any more)
    ///    gets the notch taken away.
    private func watchScan(generation: Int) {
        let limit = TimeInterval(FaceLockSettings.shared.faceDetectionSeconds) + 8
        Task { @MainActor [weak self] in
            var waited = 0.0
            var animationWithoutScan = 0
            while waited < limit + 6 {
                try? await Task.sleep(for: .milliseconds(300))
                waited += 0.3
                guard let self, self.activeGeneration == generation, !self.finished, self.isTargetActive else { return }
                if self.isScanning {
                    animationWithoutScan = 0
                    if waited >= limit {
                        Trace.log("APPLOCK SCAN: \(self.appName) was still scanning \(Int(waited)) s after it started: ended")
                        self.faceTask?.cancel()
                        self.faceTask = nil
                        self.isScanning = false
                        if !LockMonitor.isScreenActuallyLocked(), !AppLockController.shared.isFaceScanActive {
                            (self.faceScanner ?? AppLockController.shared.faceScanner)?.camera.stop()
                        }
                        self.state.status = "Face check took too long. Tap Try face again."
                        self.state.canRetryFace = self.failedFaceAttempts < self.maxFaceAttempts
                        self.releaseNotch(immediately: true)
                        return
                    }
                } else {
                    guard Self.notchOwner === self, NotchOverlayController.shared.phase == .scanning else { return }
                    animationWithoutScan += 1
                    if animationWithoutScan >= 3 {
                        Trace.log("APPLOCK SCAN: the notch was playing the scan animation with no scan behind it: taken away")
                        self.state.canRetryFace = self.failedFaceAttempts < self.maxFaceAttempts
                        if self.state.status.isEmpty || self.state.status == "Looking for your face…" {
                            self.state.status = "Face check was interrupted. Tap Try face again."
                        }
                        self.releaseNotch(immediately: true)
                        return
                    }
                }
            }
        }
    }

    /// Stops the running scan and switches its camera off (unless the lock screen owns it).
    private func cancelScan() {
        RingLight.shared.hide()
        guard isScanning else { return }
        // v494: the generation number is shared by every locked app. A scan that is no longer the newest one (another locked
        // app has started its own scan since) must not bump it: that silently cancelled the newer scan, which then ended with
        // no result and left its cover on "Looking for your face…" with no button to try again.
        if activeGeneration == AppLockScanGate.generation {
            AppLockScanGate.generation &+= 1
        }
        faceTask?.cancel()
        faceTask = nil
        isScanning = false
        // v494: and it must not switch the camera off under another app's running scan either.
        if !LockMonitor.isScreenActuallyLocked(), !AppLockController.shared.isFaceScanActive {
            (faceScanner ?? AppLockController.shared.faceScanner)?.camera.stop()
        }
    }

    private func handleFaceResult(_ result: AppLockFaceResult, showNotch: Bool) {
        NSLog("AppLock: %@ scan result %@", appName, String(describing: result))
        Self.debugNote("\(appName): scan result \(result)")
        if result != .matched { scanStartedByHover = false }   // only a face unlock brings the cursor back
        switch result {
        case .matched:
            if showNotch {
                NotchOverlayController.shared.finish(success: true)
                Self.notchOwner = nil   // the success animation ends by itself
            }
            finish()
        case .wrongFace, .spoofSuspected:
            LockSounds.playAppFailed()
            failedFaceAttempts += 1
            if failedFaceAttempts >= maxFaceAttempts {
                state.status = "Too many face attempts. Use Fingerprint or Password."
                state.canRetryFace = false
            } else {
                state.status = "Face not recognized."
                state.canRetryFace = true
            }
            if showNotch { NotchOverlayController.shared.finish(success: false) }
        case .noFace:
            state.status = "No face detected."
            state.canRetryFace = true
            releaseNotch()
        case .unavailable:
            state.status = "Face check unavailable (camera or face data)."
            state.canRetryFace = true
            releaseNotch()
        case .cancelled:
            // v494: a scan that ended as "cancelled" while this app is still the one in front (something else took the
            // camera or the scan number) used to leave "Looking for your face…" on screen with no way forward. Say so and
            // offer the face button again; fingerprint and password were never affected.
            if isTargetActive, !finished, !isScanning {
                state.status = "Face check was interrupted. Tap Try face again."
                state.canRetryFace = failedFaceAttempts < maxFaceAttempts
                releaseNotch()
            }
        }
        // v525: in both modes (see `hoverRearmWanted`): once the notch has collapsed, park it again so a hover scans again.
        if hoverRearmWanted, result != .matched, result != .cancelled, state.canRetryFace {
            if scansOnDemand { state.retryTitle = "Scan face" }
            rearmHoverWhenNotchIdle()
        }
    }

    /// Collapses the notch, but only if this overlay still owns it.
    private func releaseNotch(immediately: Bool = false) {
        RingLight.shared.hide()
        guard Self.notchOwner === self else { return }
        // A notch that is only parked (waiting for a hover) is taken away, not collapsed.
        if NotchOverlayController.shared.hoverScanArmed {
            Self.notchOwner = nil
            NotchOverlayController.shared.releaseHoverScan()
            return
        }
        // Armed by something else (the lock screen took the notch over): not ours to close.
        if NotchOverlayController.shared.isArmed {
            Self.notchOwner = nil
            return
        }
        if immediately {
            Self.notchOwner = nil
            NotchOverlayController.shared.dismissImmediately()
            return
        }
        Task { @MainActor [weak self] in
            guard let self, Self.notchOwner === self else { return }
            Self.notchOwner = nil
            await NotchOverlayController.shared.collapse()
        }
    }

    // MARK: - Unlocking

    private func submit(_ password: String) -> Bool {
        guard FaceLockSecrets.hasPassword else {
            state.status = "No app-lock password is set. Set one in Indra Settings > App Lock."
            return false
        }
        guard FaceLockSecrets.verify(password) else { LockSounds.playAppFailed(); return false }
        finish()
        return true
    }

    private func tryTouchID() {
        guard !isAuthenticating else { return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            state.status = "Touch ID isn't available. Use your password."
            return
        }
        cancelScan()
        releaseNotch()
        state.canRetryFace = failedFaceAttempts < maxFaceAttempts
        isAuthenticating = true
        FaceLockLog.note("\(appName): fingerprint prompt")
        updatePanelLevel()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            context.invalidate()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var ok = false
            do {
                ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock \(self.appName)"
                )
            } catch let err as LAError {
                switch err.code {
                case .biometryLockout:
                    self.state.status = "Touch ID is locked. Use your password."
                case .userCancel, .systemCancel, .appCancel:
                    break
                default:
                    self.state.status = "Fingerprint not recognized. Try again or use your password."
                    LockSounds.playAppFailed()
                }
            } catch {}
            self.isAuthenticating = false
            if ok {
                self.finish()
            } else {
                self.updatePanelLevel()
                self.resyncAfterAuthentication()
            }
        }
    }

    /// After a cancelled or failed Touch ID prompt: if you really left for another app meanwhile, treat it as a switch.
    private func resyncAfterAuthentication() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.isTargetActive,
                  let front = NSWorkspace.shared.frontmostApplication else { return }
            let frontPID = front.processIdentifier
            if frontPID != self.pid, frontPID != ProcessInfo.processInfo.processIdentifier,
               front.activationPolicy == .regular {
                self.targetDeactivated()
            }
        }
    }

    private func finish() {
        guard !finished else { return }   // v543: one unlock, one sound (a late result can call this again)
        LockSounds.playAppUnlocked()
        RingLight.shared.hide()
        hideEdgeStrips()
        isCovering = false
        isTargetActive = false
        stopTracking()
        cancelScan()
        releaseNotch()
        if AnimationFlags.successDissolve {
            // Show the lock opening, then let the blur dissolve instead of vanishing.
            state.isUnlocked = true
            FaceLockHaptics.success()
            finished = true
            NSRunningApplication(processIdentifier: pid)?.activate()
            onUnlocked()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                self.ensureHidden(duration: Motion.base)
                if self.scanStartedByHover {
                    self.scanStartedByHover = false
                    try? await Task.sleep(for: .seconds(Motion.base))   // the blur has now vanished
                    CursorCenter.moveToCenter()
                    try? await Task.sleep(for: .milliseconds(50))
                } else {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                self.finished = false
            }
            return
        }
        ensureHidden()
        NSRunningApplication(processIdentifier: pid)?.activate()
        onUnlocked()
        if scanStartedByHover { scanStartedByHover = false; CursorCenter.moveToCenter() }
    }

    // MARK: - Panel tracking, ordering and fading

    private func startTracking() {
        guard timer == nil else { return }
        missingFrameTicks = 0
        tick()
        // Common run-loop modes: the default mode pauses while a window is being dragged or a menu is open, which left the
        // cover standing still (and the app uncovered) exactly while the locked app's window was being moved.
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isCovering else { return }
        let info = Self.windowInfo(forPID: pid)
        topWindowNumber = info?.topWindowNumber

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            let since = frontSince ?? Date()
            frontSince = since
            if !confirmedFront, Date().timeIntervalSince(since) > 0.8 { confirmedFront = true }
        } else {
            frontSince = nil
        }

        if isTargetActive {
            keepHoverScanParked()
            // In front: cover the whole screen, whether or not the app has a window yet.
            guard let screen = Self.screen(containing: info?.frame) else { return }
            missingFrameTicks = 0
            applyFrame(screen.frame, fullScreen: true)
            ensureShown()
            // Full-screen apps are their own Space: if the cover ended up on another Space, bring it here.
            if panelShown, !panel.isOnActiveSpace {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            return
        }

        // The locked app is not in front (Stage Manager, minimize, hide, another app): hide it and close it.
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           !finished, !leaving, !isAuthenticating, !LockMonitor.isScreenActuallyLocked() {
            let front = NSWorkspace.shared.frontmostApplication
            if front == nil
                || front?.processIdentifier == pid
                || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                || front?.activationPolicy != .regular {
                inactiveSince = nil
            } else {
                let since = inactiveSince ?? Date()
                inactiveSince = since
                let away = Date().timeIntervalSince(since)
                // Hidden first, so it never sits in the Stage Manager strip with a half-size cover on it.
                // An app that was in front first and then left is hidden and closed at once. An app that never got to
                // the front (another app kept focus) is only hidden, never closed, so its tile cannot sit over other apps.
                if away > (confirmedFront ? 0.1 : 1.0), !hiddenForLeave, Date().timeIntervalSince(createdAt) > 1.5 {   // FAST_CLOSE
                    hiddenForLeave = true
                    app.hide()
                }
                if confirmedFront, away > 0.3, Date().timeIntervalSince(createdAt) > 1.5 {
                    quitBecauseLeft(app)
                }
                // Never reached the front, and another app is in front: nothing of ours may stay on screen, because the
                // tile would sit over that other app at the locked app's old window size.
                if !confirmedFront, away > 0.3 {
                    ensureHidden()
                    return
                }
            }
        }

        // Cover only the locked app's own window.
        guard let info else {
            // Brief gaps happen while windows animate; only hide after a short while.
            missingFrameTicks += 1
            if missingFrameTicks >= 6 { ensureHidden() }
            return
        }
        missingFrameTicks = 0
        applyFrame(info.frame, fullScreen: false)
        ensureShown()
        placeAboveLockedWindow()
    }

    /// Moves the panel to `frame`, animating when it switches between window and full-screen mode.
    private func applyFrame(_ frame: NSRect, fullScreen: Bool) {
        // Small window or Stage Manager thumbnail: show the plain black lock tile instead of the full lock screen.
        // TILE_STRICT: never for the app in front, whatever the frame says.
        let wantsTile = !fullScreen && !isTargetActive
        if state.compact != wantsTile { state.compact = wantsTile }
        let modeChanged = fullScreen != isFullScreenMode
        if modeChanged {
            isFullScreenMode = fullScreen
            blurView.layer?.cornerRadius = fullScreen ? 0 : 16
            updatePanelLevel()
            if panel.isVisible {
                frameAnimationEnd = Date().addingTimeInterval(modeAnimationDuration)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = modeAnimationDuration
                    panel.animator().setFrame(frame, display: true)
                }
                return
            }
        }
        // Leave an in-flight mode animation alone.
        guard Date() >= frameAnimationEnd else { return }
        if !Self.isClose(panel.frame, frame) { panel.setFrame(frame, display: true) }
    }

    // MARK: - Menu bar and Dock cover while the Touch ID dialog is up

    private var edgePanels: [NSPanel] = []

    /// While Touch ID is showing, the main cover sits low so the system dialog stays visible, which lets the
    /// menu bar and Dock show through. Blur strips at the top level cover just those areas.
    private func updateEdgeStrips() {
        guard isTargetActive, isAuthenticating, let screen = panel.screen ?? NSScreen.main else {
            hideEdgeStrips()
            return
        }
        guard edgePanels.isEmpty else { return }
        let f = screen.frame, v = screen.visibleFrame
        // Each strip reaches `fade` points into the main blur and fades out there, so the two blurs merge smoothly.
        enum Side { case top, bottom, left, right }
        let fade: CGFloat = 170
        let bars: [(Side, CGFloat, NSRect)] = [
            (.top, f.maxY - v.maxY, NSRect(x: f.minX, y: v.maxY - fade, width: f.width, height: f.maxY - v.maxY + fade)),
            (.bottom, v.minY - f.minY, NSRect(x: f.minX, y: f.minY, width: f.width, height: v.minY - f.minY + fade)),
            (.left, v.minX - f.minX, NSRect(x: f.minX, y: v.minY, width: v.minX - f.minX + fade, height: v.height)),
            (.right, f.maxX - v.maxX, NSRect(x: v.maxX - fade, y: v.minY, width: f.maxX - v.maxX + fade, height: v.height))
        ].filter { $0.1 > 0.5 }
        for (side, _, r) in bars {
            let strip = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            strip.isOpaque = false
            strip.backgroundColor = .clear
            strip.hasShadow = false
            strip.level = Self.fullScreenLevel
            strip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            strip.isReleasedWhenClosed = false
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: r.size))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            blur.maskImage = NSImage(size: r.size, flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                let zone: NSRect
                let angle: CGFloat
                switch side {
                case .top:    zone = NSRect(x: 0, y: 0, width: rect.width, height: fade); angle = 90
                case .bottom: zone = NSRect(x: 0, y: rect.height - fade, width: rect.width, height: fade); angle = 270
                case .left:   zone = NSRect(x: rect.width - fade, y: 0, width: fade, height: rect.height); angle = 180
                case .right:  zone = NSRect(x: 0, y: 0, width: fade, height: rect.height); angle = 0
                }
                NSColor.clear.setFill()
                zone.fill(using: .copy)
                // Eased (smoothstep) fade: no visible start or end, so the strip melts into the main blur.
                let steps = 12
                var locations: [CGFloat] = []
                var colors: [NSColor] = []
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    locations.append(t)
                    colors.append(NSColor.black.withAlphaComponent(t * t * (3 - 2 * t)))
                }
                NSGradient(colors: colors, atLocations: &locations, colorSpace: .deviceRGB)?.draw(in: zone, angle: angle)
                return true
            }
            // Cancels the extra darkness caused by the strip stacking on top of the main blur.
            let lift = NSView(frame: NSRect(origin: .zero, size: r.size))
            lift.wantsLayer = true
            lift.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            let liftMask = CAGradientLayer()
            liftMask.frame = lift.bounds
            let along: CGFloat = (side == .top || side == .bottom) ? r.height : r.width
            let frac = min(1, fade / max(along, 1))
            var liftColors: [CGColor] = []
            var liftLocations: [NSNumber] = []
            for i in 0...12 {
                let t = CGFloat(i) / 12
                liftColors.append(NSColor.black.withAlphaComponent(t * t * (3 - 2 * t)).cgColor)
                liftLocations.append(NSNumber(value: Double(t * frac)))
            }
            liftColors.append(NSColor.black.cgColor)
            liftLocations.append(1)
            liftMask.colors = liftColors
            liftMask.locations = liftLocations
            switch side {
            case .top:    liftMask.startPoint = CGPoint(x: 0.5, y: 0); liftMask.endPoint = CGPoint(x: 0.5, y: 1)
            case .bottom: liftMask.startPoint = CGPoint(x: 0.5, y: 1); liftMask.endPoint = CGPoint(x: 0.5, y: 0)
            case .left:   liftMask.startPoint = CGPoint(x: 1, y: 0.5); liftMask.endPoint = CGPoint(x: 0, y: 0.5)
            case .right:  liftMask.startPoint = CGPoint(x: 0, y: 0.5); liftMask.endPoint = CGPoint(x: 1, y: 0.5)
            }
            lift.layer?.mask = liftMask
            blur.addSubview(lift)
            strip.contentView = blur
            strip.orderFrontRegardless()
            edgePanels.append(strip)
        }
    }

    private func hideEdgeStrips() {
        for strip in edgePanels { strip.orderOut(nil) }
        edgePanels.removeAll()
    }

    /// In front: above the Dock and menu bar. Not in front: normal level.
    private func updatePanelLevel() {
        // Lowered while the Touch ID dialog is up, so the dialog is never hidden behind the blur.
        levelToken += 1
        let token = levelToken
        if isTargetActive && isAuthenticating {
            // Strips first, cover lowered a moment later: the Dock never shows through.
            updateEdgeStrips()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.levelToken == token else { return }
                self.panel.level = .floating
            }
        } else {
            // Cover raised at once, strips removed only after it is back in front.
            panel.level = isTargetActive ? Self.fullScreenLevel : .normal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.levelToken == token else { return }
                self.updateEdgeStrips()
            }
        }
    }
    private var levelToken = 0

    /// When the locked app is not in front, keep the panel directly above its window (and below the app in front).
    /// Skipped while Indra itself is active, so a panel you just clicked to type a password stays on top.
    private func placeAboveLockedWindow() {
        guard panelShown, !isTargetActive, !NSApp.isActive, let number = topWindowNumber else { return }
        panel.order(.above, relativeTo: number)
    }

    private func ensureShown() {
        guard !panelShown else { return }
        panelShown = true
        visibilityToken &+= 1
        state.isUnlocked = false
        state.appearCount &+= 1
        MenuBarIconTinter.shared.setCover(self, shown: true)
        (panel as? KeyablePanel)?.onQuitShortcut = { [weak self] in self?.closeApp() }
        if quitMonitor == nil {
            quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.panelShown, self.isTargetActive else { return false }
                    self.closeApp()
                    return true
                }
                return handled ? nil : event
            }
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AnimationFlagsB.softBlurIn ? 0.3 : fadeDuration
            panel.animator().alphaValue = 1
        }
        if isTargetActive {
            panel.makeKey()
            panel.makeKey()
        }
    }

    private func ensureHidden(duration: TimeInterval? = nil) {
        RingLight.shared.hide()
        guard panelShown else { return }
        panelShown = false
        hideEdgeStrips()
        MenuBarIconTinter.shared.setCover(self, shown: false)
        if let monitor = quitMonitor {
            NSEvent.removeMonitor(monitor)
            quitMonitor = nil
        }
        visibilityToken &+= 1
        let token = visibilityToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration ?? fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                guard self.visibilityToken == token else { return }
                self.panel.orderOut(nil)
            }
        })
        // v501 failsafe: the fade's completion handler is the only thing that removed the cover. An interrupted animation
        // (display sleep, a Space change, a busy window server) left an invisible window over the app that swallowed
        // every click. This removes it regardless, unless a newer show/hide has taken over.
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? fadeDuration) + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityToken == token, !self.panelShown else { return }
                self.panel.alphaValue = 0
                self.panel.orderOut(nil)
            }
        }
    }

    private static func isClose(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// The screen holding the app's window, or the main screen when the app has no window yet.
    private static func screen(containing rect: NSRect?) -> NSScreen? {
        if let rect {
            let center = NSPoint(x: rect.midX, y: rect.midY)
            if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return match }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Bounding box of the app's normal on-screen windows (AppKit coordinates) and the number of its front-most one.
    private static func windowInfo(forPID pid: pid_t) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var union: NSRect?
        var top: Int?
        // The list is ordered front to back, so the first match is the app's top-most window.
        for window in list {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 120, rect.height > 80 else { continue }
            if top == nil { top = window[kCGWindowNumber as String] as? Int }
            let appKitRect = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
            union = union.map { $0.union(appKitRect) } ?? appKitRect
        }
        guard let union, let top else { return nil }
        return WindowInfo(frame: union, topWindowNumber: top)
    }
}
