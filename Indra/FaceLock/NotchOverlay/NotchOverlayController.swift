//
//  NotchOverlayController.swift
//  Indra Face Lock
//
//  The only file other code should touch to show the notch overlay.
//
//  Interaction is hover-driven, not click-driven: a non-activating panel
//  otherwise needs a first click just to gain focus before a second click
//  registers — hover avoids that "have to double-click" bug entirely.
//

import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class NotchOverlayController {
    /// One overlay window for the whole app — sharing one instance guarantees
    /// the triggers never run concurrently, rather than leaving that incidental.
    static let shared = NotchOverlayController()

    enum Phase: Equatable {
        /// While armed, the window stays on-screen here (hover-reactive); otherwise ordered out.
        case closed
        /// Expanded, showing the idle still image — actively looking for a face.
        case scanning
        /// Success animation playing, then auto-collapses.
        case success
        /// Failure animation playing/held; collapses after a hold unless
        /// the user hovers first to retry.
        case failure
        case collapsing
        /// Hosting the multi-step onboarding flow, driven by the hosted
        /// OnboardingController rather than this controller's own machinery.
        case onboarding
    }

    /// Kept as one enum (rather than two independent optionals) so exactly one is ever active.
    enum Content: Equatable {
        case scan(ScanMedia)
        case onboarding(OnboardingController)

        static func == (lhs: Content, rhs: Content) -> Bool {
            switch (lhs, rhs) {
            case (.scan(let a), .scan(let b)): return a == b
            case (.onboarding(let a), .onboarding(let b)): return a === b
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .closed

    @ObservationIgnored private var lastBusy = false

    /// True when this scan started on the desktop (not the lock screen): the body then follows the notch's glass /
    /// translucent look. Decided once, when the scan starts, so it never changes mid-animation.
    private(set) var scanOnDesktop = false

    /// Tells Indra's notch whether the face animation owns the notch area. Called after every phase change.
    private func broadcastBusy() {
        let busy = Self.isBusy(phase)
        guard busy != lastBusy else { return }
        lastBusy = busy
        if busy {
            NotificationCenter.default.post(name: .indraFaceScanBusyChanged, object: true)
        } else {
            // Held a beat after the collapse, so the live activity only slides in once the window is really gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, !Self.isBusy(self.phase) else { return }
                NotificationCenter.default.post(name: .indraFaceScanBusyChanged, object: false)
            }
        }
    }

    private static func isBusy(_ phase: Phase) -> Bool {
        phase != .closed
    }
    private(set) var content: Content = .scan(.idle)
    /// Read-only convenience for the scan-mode view/callers — `.idle` while
    /// onboarding owns the panel.
    var media: ScanMedia {
        if case .scan(let media) = content { return media }
        return .idle
    }
    private(set) var geometry: NotchGeometry = .forMainScreen()
    /// Read by the view for the hover-driven size/shadow bump — irrelevant
    /// to the phase state machine itself.
    private(set) var isArmed = false

    /// Pill style only: whether the pill is parked on screen at rest vs. off-screen.
    /// Deliberately separate from `isArmed` — it lags it by a frame on the way in
    /// (making the pill slide into place) and leads it on the way out.
    private(set) var isPillDocked = false

    /// Snapshotted from `FaceLockSettings` when a cycle begins rather than read live,
    /// so a settings change mid-attempt can't resize the panel or change how it resolves.
    private(set) var activeUnlockStyle: UnlockAnimationStyle = .original

    /// v476: App Lock's "scan only on notch hover or button" mode. The notch sits armed (closed, waiting) on the desktop and a
    /// hover starts the scan, even when "retry on hover" is off. Cleared as soon as a scan starts or the notch is released.
    @ObservationIgnored private(set) var hoverScanArmed = false

    /// What a hover-driven activation should do — set by `arm()` (persists
    /// across scan cycles) or by one-shot `present(onRetry:)` (single use).
    private var onActivate: (() -> Void)?

    /// v482: set when a hover (not a button) started the scan; read once by App Lock to know it should bring the cursor back.
    @ObservationIgnored private var hoverStartedScan = false
    func consumeHoverStart() -> Bool {
        defer { hoverStartedScan = false }
        return hoverStartedScan
    }

    private let windowController = FaceScanWindowController()
    private var resolveTask: Task<Void, Never>?
    private var scanTimeoutTask: Task<Void, Never>?

    /// Guards `primeWindowIfNeeded` so the extra render pass only happens on the first show.
    private var hasPrimedWindow = false
    /// Lets the one-runloop-later start of a scan be dropped if something else happened in between.
    @ObservationIgnored private var presentToken = 0
    /// v495: bumped whenever a collapse starts or is overtaken, so an older collapse that wakes up from its sleep cannot
    /// finish (hide the window, set `.closed`) a newer one that has only just begun animating.
    @ObservationIgnored private var collapseToken = 0

    /// v496: set while a locked app's face scan is waiting for the notch right after another scan's success (the lock screen's
    /// face unlock, or another app). When the success animation ends the notch then goes straight into the next scan instead of
    /// collapsing first and opening again.
    @ObservationIgnored private var chainNextScan = false

    /// Matches the success asset duration (~1.22s) plus a short beat to read the final frame.
    private let successHoldDuration: Duration = .milliseconds(1_700)
    /// Non-private so FaceUnlockCoordinator's auto-retry can wait this out too.
    let failureHoldDuration: Duration = .seconds(5)
    /// Reads the same setting as `FaceUnlockCoordinator.scanWindowDuration` so
    /// the two separate timers expire together.
    private var scanTimeoutDuration: Duration {
        .seconds(FaceLockSettings.shared.faceDetectionSeconds)
    }
    /// Long enough for the closing spring to fully settle before the window is
    /// hidden/left closed — collapsing state too early made the window visibly pop away.
    let collapseAnimationDuration: Duration = .milliseconds(Int((700 / NotchGeometry.collapseSpeedFactor).rounded()))

    private init() {
        windowController.contentView = NSHostingView(rootView: NotchOverlayView(controller: self))
        // A display connecting/disconnecting mid-flow can flip notch vs. pill style.
        windowController.onScreenParametersChanged = { [weak self] in
            guard let self else { return }
            self.geometry = self.windowController.currentGeometry
        }
        // v481: on the desktop the cursor reaching the notch activates it directly, as fast as on the lock screen.
        windowController.onCursorEnteredPanel = { [weak self] in
            self?.activate()
        }
    }

    // MARK: - Armed mode (FaceUnlockCoordinator)

    /// Arms the overlay for the lock-screen flow: shows the window and keeps it
    /// up until `disarm()`. `onActivate` restarts scanning on hover.
    func arm(onActivate: @escaping () -> Void) {
        hoverScanArmed = false   // the lock screen (or a new hover park) takes over the notch
        isArmed = true
        self.onActivate = onActivate
        geometry = windowController.currentGeometry
        phase = .closed
        broadcastBusy()
        content = .scan(.idle)
        isPillDocked = false
        windowController.show()
        hasPrimedWindow = true // already shown+rendered while closed, same effect as primeWindowIfNeeded
        updateInteractivity()

        guard geometry.style == .pill else {
            // The notch silhouette has nowhere to travel from — it's on top of hardware already there.
            isPillDocked = true
            return
        }
        // Render one real frame with the pill still off-screen, so flipping the
        // flag next runloop animates it down instead of appearing already docked.
        windowController.displaySynchronously()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isArmed else { return }
            self.isPillDocked = true
        }
    }

    // MARK: - App Lock: scan only on hover (v476)

    /// Parks the notch on the desktop, closed and waiting. Moving the cursor onto the notch calls `onActivate`, which starts
    /// the scan. Does nothing while the lock screen (or another scan) owns the notch.
    func armForHoverScan(onActivate: @escaping () -> Void) {
        guard !hoverScanArmed, !isArmed, phase == .closed,
              !LockMonitor.isScreenActuallyLocked() else { return }
        arm(onActivate: onActivate)
        hoverScanArmed = true
        hoverStartedScan = false
        scanOnDesktop = true
        FaceScanColor.noteDesktopScan(true)
    }

    /// Takes the parked notch away again (the locked app went away, was unlocked, or the Mac locked).
    func releaseHoverScan() {
        guard hoverScanArmed else { return }
        hoverScanArmed = false
        disarm()
    }

    /// Truly hides the window. Only call once the lock-screen attempt is
    /// completely done — while armed, resolving an attempt goes back to `.closed`, not this.
    ///
    /// If a success/collapse sequence is already resolving, let it finish
    /// naturally: setting `isArmed = false` is enough, since the already-scheduled
    /// `collapse()` checks `isArmed` once its hold expires and hides for real then.
    func disarm() {
        isArmed = false
        hoverScanArmed = false
        onActivate = nil
        // Undocked before the guard: if a success collapse is already in flight, this
        // turns it into a full slide-off-screen exit rather than a shrink to a resting pill.
        isPillDocked = false
        guard phase != .success, phase != .collapsing else { return }
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        // Re-measured here, not just trusted from `arm()` — `arm()` typically
        // fires right around wake/unlock, when AppKit may not have finished
        // laying out the menu bar yet, so `auxiliaryTopLeftArea`/`RightArea`
        // can read back momentarily wrong. Refreshing right before settling
        // to `.closed` (the shape most directly compared against the real
        // notch) self-corrects instead of baking in a bad first reading.
        geometry = windowController.currentGeometry
        phase = .closed
        broadcastBusy()
        content = .scan(.idle)
        windowController.setInteractive(false)

        guard geometry.style == .pill, windowController.isVisible else {
            windowController.hide()
            return
        }
        // The pill is visible at rest, so hiding the window right now would blink it
        // away instead of playing the slide-up (visibility check above skips hidden windows).
        Task { [weak self] in
            try? await Task.sleep(for: self?.collapseAnimationDuration ?? .milliseconds(636))
            guard let self, !self.isArmed, self.phase == .closed else { return }
            self.windowController.hide()
        }
    }

    /// Shows the idle still; auto-collapses silently (no failure animation) after
    /// `scanTimeoutDuration` if nothing resolves it.
    func beginScanning() {
        presentToken &+= 1
        chainNextScan = false
        hoverScanArmed = false
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel()
        geometry = windowController.currentGeometry
        activeUnlockStyle = FaceLockSettings.shared.effectiveUnlockAnimationStyle
        content = .scan(.idle)
        scanOnDesktop = !LockMonitor.isScreenActuallyLocked()
        FaceScanColor.noteDesktopScan(scanOnDesktop)
        phase = .scanning
        broadcastBusy()
        updateInteractivity()

        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: self?.scanTimeoutDuration ?? .seconds(5))
            guard let self, !Task.isCancelled, self.phase == .scanning else { return }
            await self.collapse()
        }
    }

    // MARK: - Window priming (first show only)

    /// On the very first show, `present()`/`presentOnboarding()` would otherwise render
    /// already-expanded with no prior "closed" frame for SwiftUI to animate away from.
    /// This runs one real closed-state show+render pass first, only on that first call.
    private func primeWindowIfNeeded(_ completion: @escaping () -> Void) {
        guard !hasPrimedWindow else {
            completion()
            return
        }
        hasPrimedWindow = true
        content = .scan(.idle)
        phase = .closed
        broadcastBusy()
        windowController.show()
        windowController.displaySynchronously()
        DispatchQueue.main.async(execute: completion)
    }

    // MARK: - One-shot mode (onboarding, Face Lab preview)

    /// Shows the overlay in its scanning state. Safe to call again while already visible.
    /// `onRetry` runs on hover after a failed attempt; pass nil to just collapse on hover.
    ///
    /// - Parameter styleOverride: forces `.minimal`/`.original` regardless of the saved
    ///   preference, for the Animation section's live preview.
    func present(styleOverride: UnlockAnimationStyle? = nil, onRetry: (() -> Void)? = nil) {
        isArmed = false
        chainNextScan = false
        hoverScanArmed = false
        onActivate = onRetry
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        activeUnlockStyle = styleOverride ?? FaceLockSettings.shared.effectiveUnlockAnimationStyle
        presentToken &+= 1
        let token = presentToken
        primeWindowIfNeeded { [weak self] in
            // v495: dropped when something else (a dismiss, a result, another present) happened while this waited for the
            // next runloop. `presentToken` was bumped by those but never read, so a stale start could bring a dismissed
            // overlay back and leave it stuck on "scanning" with no timeout.
            guard let self, token == self.presentToken else { return }
            content = .scan(.idle)
            scanOnDesktop = !LockMonitor.isScreenActuallyLocked()
            FaceScanColor.noteDesktopScan(scanOnDesktop)
            phase = .scanning
            broadcastBusy()
            windowController.show()
            updateInteractivity()
        }
    }

    // MARK: - Onboarding mode (OnboardingController)

    /// Hands the panel to the onboarding flow — this object only owns visibility and
    /// interactivity while `.onboarding` is active; sizing/content is driven by `controller`.
    func presentOnboarding(_ controller: OnboardingController) {
        isArmed = false
        hoverScanArmed = false
        onActivate = nil
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        presentToken &+= 1
        let token = presentToken
        primeWindowIfNeeded { [weak self] in
            guard let self, token == self.presentToken else { return }
            content = .onboarding(controller)
            scanOnDesktop = !LockMonitor.isScreenActuallyLocked()
            FaceScanColor.noteDesktopScan(scanOnDesktop)
            phase = .onboarding
            broadcastBusy()
            windowController.show()
            updateInteractivity()
        }
    }

    /// Gracefully shrinks the onboarding panel away and hides the window; guarded by
    /// re-checking `content` so a concurrently-started scan cycle can't be interrupted.
    func dismissOnboarding() {
        guard case .onboarding = content else { return }
        presentToken &+= 1
        collapseToken &+= 1
        // Drop key/interactivity now, not inside the Task: first-run completion opens
        // Settings this same turn, and a still-key overlay would leave it inactive.
        phase = .collapsing
        broadcastBusy()
        updateInteractivity()
        let token = collapseToken
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.collapseAnimationDuration)
            guard token == self.collapseToken, case .onboarding = self.content else { return }
            self.content = .scan(.idle)
            self.phase = .closed
            self.broadcastBusy()
            self.windowController.hide()
        }
    }

    // MARK: - Resolving (shared by both modes)

    /// Resolves the current attempt. Success plays its animation and then
    /// collapses on its own; failure plays its animation and holds until
    /// either the hold expires or the user hovers to retry.
    func finish(success: Bool) {
        presentToken &+= 1   // a start that is still waiting for the next runloop must not override this result
        resolveTask?.cancel()
        scanTimeoutTask?.cancel()

        // Unlock Animation → None just skips the success/failure video; phase and
        // retry behavior are unaffected. Reads the cycle's captured style, not live settings.
        let shouldAnimate = activeUnlockStyle != .none
        content = shouldAnimate ? .scan(success ? .success : .failure) : .scan(.idle)
        phase = success ? .success : .failure
        broadcastBusy()
        updateInteractivity()

        let hold = shouldAnimate ? (success ? successHoldDuration : failureHoldDuration) : Duration.milliseconds(400)
        resolveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            if success, self.chainNextScan {
                self.handOffToNextScan()
            } else {
                await self.collapse()
            }
        }
    }

    // MARK: - Chained scans (v496)

    /// A face scan (a locked app's) wants the notch while it is still showing the previous scan's result. During the success
    /// animation the notch keeps it playing, then skips the collapse and starts the next scan; if it is already collapsing,
    /// the collapse is cut and the next scan starts at once. Does nothing in any other phase.
    func requestChainedScan() {
        // Never take over a notch the lock screen still owns (armed, or the Mac still locked): a failed or timed-out lock
        // screen scan that is collapsing must finish by itself.
        guard !isArmed, !hoverScanArmed else { return }
        switch phase {
        case .success:
            chainNextScan = true
        case .collapsing:
            guard !LockMonitor.isScreenActuallyLocked() else { return }
            handOffToNextScan()
        default:
            break
        }
    }

    /// The waiting scan gave up, so the notch collapses as usual after the success animation.
    func cancelChainedScan() {
        chainNextScan = false
    }

    /// Success (or a cut collapse) straight into the next scanning state: no collapse, no second opening.
    private func handOffToNextScan() {
        chainNextScan = false
        presentToken &+= 1
        collapseToken &+= 1   // an older collapse that wakes up later must not close the new scan
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel()
        geometry = windowController.currentGeometry
        activeUnlockStyle = FaceLockSettings.shared.effectiveUnlockAnimationStyle
        content = .scan(.idle)
        scanOnDesktop = !LockMonitor.isScreenActuallyLocked()
        FaceScanColor.noteDesktopScan(scanOnDesktop)
        phase = .scanning
        broadcastBusy()
        updateInteractivity()
        // The locked app's scan ends this itself (a result, or its own collapse); this only covers a scan that never starts.
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: (self?.scanTimeoutDuration ?? .seconds(5)) + .seconds(3))
            // A locked app's scan that is running owns the notch and ends it itself.
            guard let self, !Task.isCancelled, self.phase == .scanning,
                  !AppLockController.shared.isFaceScanActive else { return }
            await self.collapse()
        }
    }

    /// Hover-driven activation: wakes from a closed/armed state, or retries from a held
    /// failure frame. No-op during scanning/success/collapsing.
    func activate() {
        // Gated here rather than in `updateInteractivity()` so the cosmetic hover bump
        // stays unaffected — only the retry itself is removed.
        // (App Lock's hover-to-scan mode is the whole point of its hover, so it ignores that setting.)
        guard FaceLockSettings.shared.retryOnHover || hoverScanArmed else { return }
        switch phase {
        case .closed, .failure:
            guard let onActivate else {
                if phase == .failure { Task { await collapse() } }
                return
            }
            resolveTask?.cancel(); resolveTask = nil
            hoverStartedScan = hoverScanArmed
            if !isArmed {
                // Captures its own style here; the armed path doesn't need to since
                // `onActivate()` routes through `beginScanning()`, which captures.
                activeUnlockStyle = FaceLockSettings.shared.effectiveUnlockAnimationStyle
                content = .scan(.idle)
                scanOnDesktop = !LockMonitor.isScreenActuallyLocked()
                FaceScanColor.noteDesktopScan(scanOnDesktop)
                phase = .scanning
                broadcastBusy()
                updateInteractivity()
            }
            // v498: on the lock screen the notch opens the instant the cursor arrives. It used to wait until the camera was
            // set up (the scan cycle only opened it afterwards), which showed as a long delay after the hover.
            if isArmed, !hoverScanArmed { beginScanning() }
            onActivate()
        case .scanning, .success, .collapsing, .onboarding:
            break
        }
    }

    /// v498: the notch now opens before the camera is ready. Once the camera is up the scan window starts counting
    /// again, so waking the camera does not eat into the time left to find a face.
    func restartScanTimeout() {
        guard phase == .scanning else { return }
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: self?.scanTimeoutDuration ?? .seconds(5))
            guard let self, !Task.isCancelled, self.phase == .scanning else { return }
            await self.collapse()
        }
    }

    /// Collapses gracefully: animates shut, then either leaves the window
    /// at rest (closed, still on-screen, hover-reactive) if armed, or
    /// orders it out entirely if not.
    func collapse() async {
        guard phase != .closed, phase != .collapsing else { return }
        // Capture the display's real closed notch dimensions before changing phase.
        // The phase change starts the SwiftUI closing animation; measuring afterward
        // would animate toward stale geometry, then expose the real (smaller) notch
        // when the window is hidden.
        geometry = windowController.currentGeometry
        phase = .collapsing
        collapseToken &+= 1
        let token = collapseToken
        broadcastBusy()
        updateInteractivity()
        try? await Task.sleep(for: collapseAnimationDuration)
        guard phase == .collapsing, token == collapseToken else { return }

        content = .scan(.idle)
        if isArmed {
            phase = .closed
            broadcastBusy()
            updateInteractivity()
        } else {
            phase = .closed
            broadcastBusy()
            windowController.hide()
        }
    }

    /// Tears the overlay down without any resolve animation. Deliberately a no-op while
    /// success/collapsing is in flight — interrupting that made the window vanish abruptly.
    func dismissImmediately() {
        guard phase != .success, phase != .collapsing else { return }
        chainNextScan = false
        presentToken &+= 1
        collapseToken &+= 1
        hoverScanArmed = false
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        phase = .closed
        broadcastBusy()
        content = .scan(.idle)
        isPillDocked = false
        windowController.setInteractive(false)
        windowController.hide()
    }

    private func updateInteractivity() {
        // Click-through otherwise, so the overlay never intercepts anything it doesn't
        // need to. Onboarding additionally needs key so its text field can receive keystrokes.
        windowController.setInteractive(isArmed || phase == .failure || phase == .onboarding, key: phase == .onboarding)
    }

    /// Called by `NotchOverlayView` whenever the visible panel's own frame
    /// changes (step change, expand/collapse, hover bump, …) — see
    /// `FaceScanWindowController.updateMousePassthrough()`.
    func updateInteractiveContentRect(_ rect: CGRect?) {
        windowController.setInteractiveContentRect(rect)
    }
}
