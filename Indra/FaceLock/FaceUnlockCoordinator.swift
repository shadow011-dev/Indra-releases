//
//  FaceUnlockCoordinator.swift
//  Indra Face Lock
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()

    /// Persisted via FaceLockSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            FaceLockSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// "Quit Face Lock" from the menu bar: face unlock stays off for this run (not saved) until Face Lock is started again.
    var isPaused = false {
        didSet {
            if isPaused { disarmOverlay() } else { evaluateTrigger() }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    var matchThreshold: Float {
        didSet { FaceLockSettings.shared.matchThreshold = matchThreshold }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    private var scanWindowDuration: TimeInterval {
        TimeInterval(FaceLockSettings.shared.faceDetectionSeconds)
    }
    /// A wake often catches the owner while they are still looking away from
    /// the camera. Require a sustained non-match rather than a few early
    /// frames before giving the failure animation.
    private let wrongFaceGraceDuration: Duration = .seconds(2)

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    private var showsUI: Bool { FaceLockSettings.shared.showUnlockAnimation }

    /// Reads the space key on the lock screen for the "On space" trigger; only runs while locked + opted in.
    private let spaceKeyMonitor = SpaceKeyMonitor()

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = FaceLockSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = FaceLockSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        spaceKeyMonitor.allowsAnyKeyFallback = true   // v508: see SpaceKeyMonitor.allowsAnyKeyFallback
        observeLockAndWakeEvents()
        startSpaceMonitorWatch()
        AppLockController.shared.faceScanner = self
        // v498: "On space" needs Input Monitoring. Nothing ever asked for it (the app only pointed at Accessibility), so on
        // some Macs the space key was never allowed to be read. Ask now, while the Mac is unlocked and a prompt can be answered.
        if isEnabled, spaceStartsScan,
           SpaceKeyMonitor.inputMonitoringAccess == .notDetermined {
            SpaceKeyMonitor.requestInputMonitoringAccess()
        }
    }

    /// v501: once a second, makes sure the space key reader runs exactly while the Mac is locked and "On space" is on. It
    /// used to be started only from lock / wake notifications. Those can arrive while Indra is suspended (lid close, display
    /// sleep) or before the session reports "locked", and then nothing ever started the reader, so space did nothing.
    private var spaceWatchTimer: Timer?
    private var cameraPreparedForLock = false
    private func startSpaceMonitorWatch() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, !self.isPaused, self.spaceStartsScan else { return }
                self.updateSpaceMonitor()
                // v510b: the camera input is built while the Mac waits on the lock screen (no light, nothing runs), so a space
                // press only has to start the session. Building it at press time blocked the main thread.
                // Once per lock, not every second: rebuilding the capture input each second kept the main thread busy.
                if LockMonitor.isScreenActuallyLocked() {
                    if !self.cameraPreparedForLock, !AppLockController.shared.isFaceScanActive {
                        self.camera.prepare()
                        self.cameraPreparedForLock = true
                    }
                } else {
                    self.cameraPreparedForLock = false
                }
                // A lock that no notification announced: arm the notch so the space key has something to open.
                if LockMonitor.isScreenActuallyLocked(), !self.lockMonitor.isSleeping,
                   !self.hasArmedForCurrentLock, !NotchOverlayController.shared.isArmed {
                    self.evaluateTrigger()
                }
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        spaceWatchTimer = timer
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents()
                // Brief settle delay: CGSession's reported state can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.evaluateTrigger()
            }
        }
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled, !isPaused, !hasArmedForCurrentLock else { return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = FaceLockSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { return }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.arm(autoScan: shouldAutoScan)
        }
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarmOverlay() {
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        // An app-lock face scan owns the camera and notch right now; don't pull them out from under it.
        if !AppLockController.shared.isFaceScanActive {
            camera.stop()
            // v481: a notch parked on the desktop for App Lock's "scan only on hover" is not the lock screen's to take
            // away; unlocking used to disarm it and leave the hover doing nothing.
            if LockMonitor.isScreenActuallyLocked() || !NotchOverlayController.shared.hoverScanArmed {
                NotchOverlayController.shared.disarm()
            }
        }
        cameraPreparedForLock = false
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen = isEnabled
            && spaceStartsScan
            && LockMonitor.isScreenActuallyLocked()
        // v498: no longer requires the Input Monitoring check to be "granted" first. That check reported "not granted" on
        // some Macs although the key can still be read, which silently kept the space key switched off. The monitor now
        // always tries (and also polls the key state), and logs what it finds.
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// v507: whether the space bar may start a scan on the lock screen. "On space" in the lock-screen triggers does, and so does
    /// App Lock's "Scan only on notch hover or button": a person who chose to start scans by hand there (hover, button, space)
    /// expects the space bar to work on the lock screen too, not only on an app's cover. Before, only "On space" counted, so
    /// space did nothing on the lock screen in that mode.
    private var spaceStartsScan: Bool { SpaceKeyMonitor.isWanted }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private var spaceAfterCollapseTask: Task<Void, Never>?
    private var lastSpaceStartAt = Date.distantPast

    private func handleSpaceKeyPress() {
        // v501: every reason a space press is ignored is written to the timeline (Problems/timeline.txt), so "space did
        // nothing" can be read from the file instead of guessed.
        func ignore(_ why: String) {
            Trace.log("SPACE: press ignored: \(why)")
            SpaceKeyMonitor.lastIgnoreReason = "Last space press on the lock screen was ignored: \(why)."   // v508: shown in Settings
        }
        guard isEnabled else { return ignore("face unlock is off") }
        guard !isPaused else { return ignore("Face Lock was quit from the menu bar") }
        guard spaceStartsScan else { return ignore("\"On space\" is not selected and App Lock's \"scan only on hover\" is off") }
        guard LockMonitor.isScreenActuallyLocked() else { return ignore("the Mac is not locked") }
        guard NotchGeometry.preferredScreen() != nil else { return ignore("the chosen display is not connected") }
        guard SecureCredentialManager.isSessionUnlocked else { return ignore("the password session is locked (authenticate once in Password settings)") }
        guard SecureCredentialManager.hasStoredPassword() else { return ignore("no password is stored") }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return ignore("a scan is already running") }

        // v525: the notch is still playing an animation (the result, or its fold back into the notch). A press used to start
        // the next scan right in the middle of it, which cut the animation short. A result in progress is left alone; a
        // collapse is waited out, then the press starts its scan.
        switch NotchOverlayController.shared.phase {
        case .success:
            return ignore("the notch is showing a success")
        case .collapsing:
            Trace.log("SPACE: pressed while the notch folds away: the scan starts when it has finished")
            spaceAfterCollapseTask?.cancel()
            spaceAfterCollapseTask = Task { [weak self] in
                for _ in 0..<60 {   // up to 3 s
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let self else { return }
                    if NotchOverlayController.shared.phase != .collapsing {
                        try? await Task.sleep(for: .milliseconds(80))   // let it settle
                        guard !Task.isCancelled else { return }
                        self.spaceAfterCollapseTask = nil
                        self.handleSpaceKeyPress()
                        return
                    }
                }
                self?.spaceAfterCollapseTask = nil
            }
            return
        default:
            break
        }
        // v525: two presses within half a second are one request (the second used to restart the scan's opening).
        guard Date().timeIntervalSince(lastSpaceStartAt) > 0.5 else { return ignore("a scan was just started") }
        lastSpaceStartAt = Date()

        // v507: a notch parked on the desktop for App Lock's "scan only on hover" still carries App Lock's own start action
        // (and its desktop colours). On the lock screen it must be the lock screen's: hand it back, then arm it again below.
        if NotchOverlayController.shared.hoverScanArmed {
            Trace.log("SPACE: the notch was parked for App Lock; taking it over for the lock screen")
            NotchOverlayController.shared.releaseHoverScan()
        }

        Trace.log("SCAN: space press accepted (notch armed: \(NotchOverlayController.shared.isArmed))")
        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            // v525: show the closed notch first and start the scan a beat later, so the opening has a closed frame to grow
            // from (shown and opened in the same pass it jumped open and the animation never played out).
            Task { [weak self] in
                guard let self else { return }
                await self.arm(autoScan: false)
                try? await Task.sleep(for: .milliseconds(90))
                guard LockMonitor.isScreenActuallyLocked(),
                      NotchOverlayController.shared.phase != .scanning else { return }
                self.startScanCycle()
            }
        }
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    private func arm(autoScan: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        // v498: the camera input is set up now, while the notch waits, so the scan itself starts quickly.
        if !AppLockController.shared.isFaceScanActive { camera.prepare() }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself. This was a real bug — a superseded `camera.stop()` queued behind the newer cycle's `startRunning()` made the
    /// camera visibly switch on then die mid-warm-up, leaving the surviving cycle polling a dead session and never unlocking.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        // v498: the notch opens FIRST, the moment the hover / space key / wake arrives. Starting the camera used to come
        // before this, and waking it (building the capture input, a cold camera) took long enough to look like the hover
        // had done nothing for a second or more.
        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }

        Trace.log("SCAN: notch opened")
        await camera.start()
        guard generation == scanGeneration else { return }
        Trace.log("SCAN: camera started")

        if let error = camera.errorMessage {
            statusMessage = error
            // v494: not under an App Lock scan that is using the camera right now.
            if !AppLockController.shared.isFaceScanActive { camera.stop() }
            // v498: the notch was already opened above, so close it again instead of leaving it waiting.
            if showsUI { await NotchOverlayController.shared.collapse() }
            return
        }

        // v498: the camera is up: the time to find a face starts counting from here.
        if showsUI {
            NotchOverlayController.shared.restartScanTimeout()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration),
            requireOverlayScanning: showsUI
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }
        Trace.log("SCAN: finished (\(outcome))")

        // v490: a face unlock opens the desktop while this cycle is still finishing; the locked app's own face scan may
        // already be using the camera by now. Switching the camera off under it left that scan with no picture at all
        // (no animation, no camera) whenever the Mac had been unlocked by face.
        if !AppLockController.shared.isFaceScanActive { camera.stop() }

        switch outcome {
        case .matched:
            // The unlock already happened inside observeScanWindow — this only decides whether anything is shown about it.
            CursorCenter.moveAfterMacUnlock()   // v482
            if showsUI {
                NotchOverlayController.shared.finish(success: true)
            }
        case .consistentlyWrongFace:
            statusMessage = "Face not recognized."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Face not recognized — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .spoofSuspected:
            statusMessage = "Couldn't confirm a live face."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Couldn't confirm a live face — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .noResolution:
            // v495: the scan also ends this way when the Mac was unlocked by password mid-scan; saying "No face detected"
            // and spending the one-shot auto-retry then was wrong (the next lock would start without its retry).
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "Idle"
                return
            }
            statusMessage = "No face detected."
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
                statusMessage = "No face detected — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard FaceLockSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    private enum ScanOutcome {
        case matched
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match. Same failure path as `.consistentlyWrongFace`.
        case spoofSuspected
        case noResolution
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second lands;
    /// liveness never fails the scan by staying undecided, it just keeps scanning until `deadline`.
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool) async -> ScanOutcome {
        let livenessEnabled = FaceLockSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { FaceLockSettings.shared.livenessMode }
        /// Set by the first consecutive non-match. A gap in face detection or
        /// a valid match clears it, so only a sustained wrong face resolves the scan.
        var wrongFaceStartedAt: ContinuousClock.Instant?

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?

        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            // v501: cached for half a second (this loop spins every 20 ms); the password path re-checks live.
            guard LockMonitor.isScreenLockedCached() else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                // 20ms keeps the liveness window's sample count high while staying close to the camera's native ~33ms cadence.
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays a genuinely independent gate rather than one starved by recognition confidence.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any confirmation that already happened.
                    lastOutcome = snapshot.decision.denialReason
                    return .spoofSuspected
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // `activeIdentities`, not `identities`: someone switched off on the Your Face page stays enrolled but must not unlock.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold)

            if let matched {
                wrongFaceStartedAt = nil
                readyMatch = matched
            } else {
                readyMatch = nil
                if wrongFaceStartedAt == nil {
                    wrongFaceStartedAt = .now
                }
                if ContinuousClock.now - wrongFaceStartedAt! >= wrongFaceGraceDuration {
                    return .consistentlyWrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                statusMessage = "Recognized — unlocking…"
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return .noResolution
    }
}
