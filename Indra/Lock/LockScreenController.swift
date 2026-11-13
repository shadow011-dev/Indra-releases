import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

/// Shows the music player over the macOS lock screen while a song is playing.
/// The window lives in the same private top-level Space as the notch (see StickySpace).
@MainActor
final class LockScreenController {
    private let media: MediaController
    private let model = LockScreenModel()
    private let panel: LockPanel
    private var lockSpace: LockSpace?
    private var space: StickySpace?
    private var inSpace = false
    private var locked = false
    private var previewUntil = Date.distantPast
    private var lastPlaying = Date.distantPast
    private var visible = false
    private var hideGrace: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    private var modeObserver: AnyCancellable?
    private var colourObserver: AnyCancellable?
    private var awakeAssertion = IOPMAssertionID(0)
    private var holdingAwake = false
    /// While this is held macOS does not "nap" Indra (see `updateNap`).
    private var napActivity: NSObjectProtocol?
    private var timer: Timer?
    private var ticks = 0
    private var hudHide: Task<Void, Never>?
    private var hudOpen: Task<Void, Never>?
    private var btHide: Task<Void, Never>?
    private var btOpen: Task<Void, Never>?
    private var batHide: Task<Void, Never>?
    private var batOpen: Task<Void, Never>?
    /// True from the first HUD / Bluetooth event until its fold-away has finished.
    private var hudActive: Bool { model.hud != nil || model.bluetooth != nil || model.battery != nil }
    private var scrollMonitors: [Any] = []
    private var swipeAccum: CGFloat = 0
    private var swipeFired = false
    private var swipeResync: Task<Void, Never>?

    /// False when the window-server functions needed to draw over the lock screen are missing.
    static var layerAvailable = false
    private var observers: [NSObjectProtocol] = []

    init(media: MediaController, levels: SmoothedLevel) {
        self.media = media
        panel = LockPanel()
        panel.alphaValue = 0
        panel.contentView = FirstMouseHostingView(rootView: LockScreenView(media: media, levels: levels, model: model))
        lockSpace = LockSpace()
        if lockSpace == nil { space = StickySpace() }
        LockScreenController.layerAvailable = lockSpace != nil || space != nil

        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setLocked(true) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setLocked(false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(force: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .indraLockPreview,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.preview() }
        })
        // Volume / brightness changes: while the screen is locked they are drawn here (nothing else is).
        observers.append(NotificationCenter.default.addObserver(forName: .indraSensoryEvent,
                                                                object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? SensoryEvent else { return }
            Task { @MainActor [weak self] in self?.showHUD(event) }
        })
        // Bluetooth devices connecting / disconnecting: the notch itself is not drawn on the lock screen, so the
        // same card is shown here.
        observers.append(NotificationCenter.default.addObserver(forName: .indraLockBluetooth,
                                                                object: nil, queue: .main) { [weak self] note in
            let kind = (note.userInfo?["kind"] as? BluetoothKind) ?? .earbuds
            let name = (note.userInfo?["name"] as? String) ?? ""
            let connected = (note.userInfo?["connected"] as? Bool) ?? true
            Task { @MainActor [weak self] in self?.showBluetooth(kind: kind, name: name, connected: connected) }
        })
        // Charger plugged in / pulled out, low battery: the same card on the lock screen.
        observers.append(NotificationCenter.default.addObserver(forName: .indraLockBattery,
                                                                object: nil, queue: .main) { [weak self] note in
            let percent = (note.userInfo?["percent"] as? Int) ?? 0
            let charging = (note.userInfo?["charging"] as? Bool) ?? false
            let pluggedIn = (note.userInfo?["pluggedIn"] as? Bool) ?? false
            Task { @MainActor [weak self] in self?.showBattery(percent: percent, charging: charging, pluggedIn: pluggedIn) }
        })
        installSwipeMonitors()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screenChanged() }
        })
        // Backup in case a lock / unlock notification is missed, and keeps the window on top while locked.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        attach()
        modeObserver = model.$mode.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAwake() }
        }
        // v468: while the vinyl (with or without lyrics) is open, the face animation takes the album's colour.
        // v477: together with the album's gradient (the notch waveform's colours), for the "Album gradient" setting.
        colourObserver = model.$mode.combineLatest(model.$shown, model.$accent, media.$artwork)
            .map { [weak self] mode, shown, accent, _ -> (NSColor?, [NSColor]?) in
                guard shown, mode != .compact, let accent else { return (nil, nil) }
                let stops = self?.media.accentGradient?.compactMap { NSColor($0).usingColorSpace(.sRGB) }
                return (accent, stops)
            }
            .removeDuplicates { old, new in
                old.0?.hashValue == new.0?.hashValue
                    && (old.1 ?? []).map(\.hashValue) == (new.1 ?? []).map(\.hashValue)
            }
            .sink { accent, stops in
                Task { @MainActor in FaceScanColor.setAlbum(accent, gradient: stops) }
            }
        cancellable = media.$track
            .map { ($0 != nil && $0?.source != .identified, $0?.isPlaying ?? false) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.update()
                    self?.updateAwake()
                    self?.updateNap()
                }
            }
        updateNap()
    }

    /// The root of the lock screen's slowness: Indra has no visible window while the Mac is locked, and for such an app
    /// macOS applies "App Nap". Timers are stretched by seconds, network replies are handled late and the process runs
    /// at the lowest priority. Everything the lock screen waits for (the lyrics lookup, the animated cover's search and
    /// stream, the blurred photo) then arrives late, or the lyrics lookup times out and the song shows as "no lyrics".
    /// While the lock screen player is switched on and there is music (or the screen is locked) the app declares that it
    /// is doing work the user is waiting for. The Mac can still go to sleep normally.
    private func updateNap() {
        // v525: also held while locked when a volume / brightness overlay is switched on: with the player off nothing else
        // kept Indra awake, and the lock screen overlay then arrived seconds late or not at all.
        let overlays = Preferences.sensoryVolume || Preferences.sensoryBrightness || Preferences.sensoryKeyboard
        let want = (Preferences.lockPlayer && (locked || media.track != nil)) || (locked && overlays)
        if want, napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                                reason: "Indra lock screen player")
        } else if !want, let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    /// The window is put into the top-level Space once, at launch, and stays there (invisible, click-through)
    /// instead of being created when the screen locks: windows that appear after the lock are not drawn.
    private func attach() {
        guard let screen = NotchMetrics.notchScreen() ?? NSScreen.main else { return }
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        place()
    }

    /// A display was plugged in or the resolution changed: the window must cover the new screen.
    private func screenChanged() {
        guard let screen = NotchMetrics.notchScreen() ?? NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
        place()
    }

    /// Puts the window into the lock screen Space (again), and raises that Space.
    private func place() {
        if let lockSpace {
            lockSpace.refresh()
            lockSpace.delegate(panel)
            inSpace = true
        } else if let space {
            space.refresh()
            space.add([panel])
            _ = space.makeExclusive([panel])
            inSpace = true
        }
    }

    private func tick() {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isLocked = (dict?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        if isLocked != locked {
            setLocked(isLocked)
            return
        }
        noteActivity()
        updateAwake()
        // v501 failsafe (whole-screen input freeze): this window covers the ENTIRE screen at the top window level. While
        // it accepts mouse events nothing under it can be clicked. Whenever the Mac is not locked (and no preview runs) it
        // must be click-through and invisible, whatever state a missed notification or an interrupted fade left behind.
        if !locked, Date() >= previewUntil {
            if visible {
                update(force: true)   // hides it the normal way (and resets the view)
            }
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            if !visible, !hudActive, panel.alphaValue > 0 { panel.alphaValue = 0 }
        }
        // Music paused or stopped for a while: take the card away.
        if locked, visible, !shouldShow {
            update()
            return
        }
        guard locked, visible || hudActive else { return }
        ticks += 1
        if panel.alphaValue < 1 { panel.alphaValue = 1 }
        panel.orderFrontRegardless()
        // v501: was every 2 s. Each place() is three private window-server calls (set level, show, move window); doing
        // them repeatedly while the lock screen is also redrawing was wasted load on the window server.
        if ticks % 6 == 0 {
            place()
        }
    }

    private func setLocked(_ value: Bool) {
        if value != locked { LockSounds.play(locking: value) }   // v517
        locked = value
        updateNap()
        if !value {
            clearHUD()
            clearBluetooth()
            clearBattery()
        }
        update(force: true)
        if value {
            // The lock screen can finish appearing after the notification; bring the window up again.
            Task { @MainActor [weak self] in
                for delay: UInt64 in [400_000_000, 600_000_000, 1_500_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    // v419: not after the Mac has been unlocked again in the meantime.
                    guard let self, self.locked else { return }
                    self.update(force: true)
                }
            }
        }
    }

    // MARK: - Volume / brightness over the lock screen

    /// The HUD is part of the lock screen window (the only window that can be drawn there). It does not need
    /// the player: with nothing playing the window shows just the HUD and goes clear again afterwards.
    private func showHUD(_ event: SensoryEvent) {
        guard locked, LockScreenController.layerAvailable,
              let screen = NotchMetrics.notchScreen() ?? NSScreen.main else {
            Trace.log("LOCKHUD: an overlay event arrived but was not shown (locked: \(locked), layer: \(LockScreenController.layerAvailable))")
            return
        }
        Trace.log("LOCKHUD: showing the \(event.kind) overlay on the lock screen")
        let wasActive = hudActive
        clearBluetooth()
        clearBattery()
        hudHide?.cancel()
        model.hud = LockHUD(kind: event.kind, value: event.value, muted: event.muted)
        if !wasActive {
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            place()
            panel.alphaValue = 1
            // One beat as the bare notch, then it grows (so the growth is animated).
            hudOpen?.cancel()
            hudOpen = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard !Task.isCancelled, let self, self.hudActive else { return }
                self.model.hudVisible = true
            }
        } else if !model.hudVisible {
            model.hudVisible = true
        }
        let seconds = max(Preferences.sensoryDuration, 0.8)
        hudHide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.model.hudVisible = false
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self.model.hud = nil
            if !self.visible && !self.hudActive { self.panel.alphaValue = 0 }
        }
    }

    // MARK: - Bluetooth over the lock screen

    /// A device connected or disconnected while the screen is locked: the notch's Bluetooth card (picture, dot and the
    /// device's name) grows out of the notch, stays a few seconds and folds back. It does not need the player.
    private func showBluetooth(kind: BluetoothKind, name: String, connected: Bool) {
        guard locked, LockScreenController.layerAvailable,
              let screen = NotchMetrics.notchScreen() ?? NSScreen.main else { return }
        let wasActive = hudActive
        clearHUD()
        clearBattery()
        btHide?.cancel()
        btOpen?.cancel()
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            model.bluetoothVisible = false
            model.bluetooth = LockBluetooth(kind: kind, name: name, connected: connected)
        }
        if !wasActive {
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            place()
            panel.alphaValue = 1
        }
        btOpen = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, let self, self.model.bluetooth != nil else { return }
            self.model.bluetoothVisible = true
        }
        btHide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.model.bluetoothVisible = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.model.bluetooth = nil
            if !self.visible && !self.hudActive { self.panel.alphaValue = 0 }
        }
    }

    private func clearBluetooth() {
        btHide?.cancel()
        btOpen?.cancel()
        btHide = nil
        btOpen = nil
        guard model.bluetooth != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.bluetoothVisible = false
            model.bluetooth = nil
        }
    }

    // MARK: - Battery over the lock screen

    /// The charger was plugged in or pulled out (or the battery got low) while the screen is locked: the notch's
    /// battery card grows out of the notch, stays a few seconds and folds back. It does not need the player.
    private func showBattery(percent: Int, charging: Bool, pluggedIn: Bool) {
        guard locked, LockScreenController.layerAvailable,
              let screen = NotchMetrics.notchScreen() ?? NSScreen.main else { return }
        let wasActive = hudActive
        clearHUD()
        clearBluetooth()
        batHide?.cancel()
        batOpen?.cancel()
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            model.batteryVisible = false
            model.battery = LockBattery(percent: percent, charging: charging, pluggedIn: pluggedIn)
        }
        if !wasActive {
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            place()
            panel.alphaValue = 1
        }
        batOpen = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, let self, self.model.battery != nil else { return }
            self.model.batteryVisible = true
        }
        batHide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.model.batteryVisible = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.model.battery = nil
            if !self.visible && !self.hudActive { self.panel.alphaValue = 0 }
        }
    }

    private func clearBattery() {
        batHide?.cancel()
        batOpen?.cancel()
        batHide = nil
        batOpen = nil
        guard model.battery != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.batteryVisible = false
            model.battery = nil
        }
    }

    // MARK: - Swipes (same as the notch's player)

    /// Two-finger swipe left = next song, right = previous song. It works over the card and the vinyl whatever the
    /// view, and also anywhere on the screen while the small card is up (the window is clear outside the card).
    /// Over the lyrics the swipe keeps its own meaning (move through the song), so it is left alone there.
    private func installSwipeMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleSwipe(event, local: true) }
            return event
        }) {
            scrollMonitors.append(local)
        }
        // Events the lock screen keeps for itself never reach the local monitor; the global one sees those.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleSwipe(event, local: false) }
        }) {
            scrollMonitors.append(global)
        }
    }

    private func handleSwipe(_ event: NSEvent, local: Bool) {
        guard visible, media.track != nil, event.hasPreciseScrollingDeltas else { return }
        if local, event.window !== panel { return }
        if model.mode == .lyrics, LockGesture.overLyrics { return }
        if event.phase.contains(.began) {
            swipeAccum = 0
            swipeFired = false
        }
        guard event.momentumPhase.isEmpty, !swipeFired else { return }
        // Physical finger direction: x > 0 = right.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = sign * event.scrollingDeltaX
        let dy = sign * event.scrollingDeltaY
        guard abs(dx) > abs(dy) else { return }
        swipeAccum += dx
        guard abs(swipeAccum) > 60 else { return }
        swipeFired = true
        Haptics.hf1(scope: .lock)   // song change
        SeekDrag.active = false
        if swipeAccum > 0 {
            media.previousTrack()
        } else {
            media.nextTrack()
        }
        resyncAfterSwipe()
    }

    /// The player reports the new song's position late (or not at all) while the screen is locked, which left the
    /// progress bar and the stylus where they were. Ask it again shortly after the change.
    private func resyncAfterSwipe() {
        swipeResync?.cancel()
        swipeResync = Task { @MainActor [weak self] in
            for delay: UInt64 in [700_000_000, 1_500_000_000, 3_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.media.refresh()
            }
        }
    }

    private func clearHUD() {
        hudHide?.cancel()
        hudOpen?.cancel()
        hudHide = nil
        hudOpen = nil
        guard model.hud != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.hudVisible = false
            model.hud = nil
        }
    }

    private func preview() {
        previewUntil = Date().addingTimeInterval(10)
        update(force: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_300_000_000)
            self?.update()
        }
    }

    private func noteActivity() {
        if media.track?.isPlaying == true { lastPlaying = Date() }
    }

    private var shouldShow: Bool {
        guard let track = media.track, track.source != .identified else { return false }
        if Date() < previewUntil { return true }
        guard locked, Preferences.lockPlayer else { return false }
        if track.isPlaying { return true }
        // Opened up (artwork / lyrics): stay while paused. The small card goes 20 s after the music stops.
        if model.mode != .compact { return true }
        return Date().timeIntervalSince(lastPlaying) < 20
    }

    private func update(force: Bool = false) {
        noteActivity()
        let wanted = shouldShow
        if wanted {
            hideGrace?.cancel()
            hideGrace = nil
            show(force: force)
        } else if visible {
            if media.track == nil && locked && Date() >= previewUntil {
                // Between two songs the player briefly reports nothing: wait before closing anything.
                guard hideGrace == nil else { return }
                hideGrace = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.hideGrace = nil
                    if !self.shouldShow { self.hide() }
                }
            } else {
                hideGrace?.cancel()
                hideGrace = nil
                hide()
            }
        }
    }

    private func show(force: Bool) {
        guard let screen = NotchMetrics.notchScreen() ?? NSScreen.main else { return }
        if !visible { model.mode = .compact }
        panel.setFrame(screen.frame, display: true)
        // v501: only takes the mouse while the screen is really locked. A preview on the desktop used to cover the whole
        // screen with a window that swallowed every click for ten seconds.
        panel.ignoresMouseEvents = !locked
        panel.orderFrontRegardless()
        if !inSpace || force { place() }
        guard !visible else { return }
        visible = true
        panel.alphaValue = 1
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { model.shown = true }
    }

    /// The display is kept awake only while the vinyl (artwork / lyrics view) is open AND the music is playing.
    /// The small card alone, or a paused vinyl, leaves normal display sleep untouched.
    private func updateAwake() {
        let want = visible && model.mode != .compact && (media.track?.isPlaying ?? false)
        if want == holdingAwake { return }
        if want {
            var identifier = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Indra lock screen player" as CFString,
                                                     &identifier)
            if result == kIOReturnSuccess {
                awakeAssertion = identifier
                holdingAwake = true
            }
        } else {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = IOPMAssertionID(0)
            holdingAwake = false
        }
    }

    private func hide() {
        visible = false
        updateAwake()
        panel.ignoresMouseEvents = true
        if !locked {
            // Unlocking: macOS is already fading its own screen, so just fade the whole window out quickly
            // with the window server (no SwiftUI animation of the big gradient).
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in self?.finishHide(animated: false) }
            })
            return
        }
        withAnimation(.smooth(duration: 0.3)) { model.shown = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            self?.finishHide(animated: true)
        }
    }

    /// Resets the view to the small card with the window invisible, so the gradient stops drawing while hidden.
    private func finishHide(animated: Bool) {
        guard !visible else { return }
        // A volume / brightness HUD may still be on its way out: the window stays until it is gone.
        if !hudActive { panel.alphaValue = 0 }
        if animated {
            model.mode = .compact
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.shown = false
                model.mode = .compact
            }
        }
    }
}

extension Notification.Name {
    static let indraLockPreview = Notification.Name("indraLockPreview")
    /// Posted with a SensoryEvent in userInfo["event"] whenever the volume or brightness overlay is due.
    static let indraSensoryEvent = Notification.Name("indraSensoryEvent")
    /// Posted with kind (BluetoothKind), name (String) and connected (Bool) whenever a Bluetooth device connects or disconnects.
    static let indraLockBluetooth = Notification.Name("indraLockBluetooth")
    /// Posted with percent (Int), charging (Bool) and pluggedIn (Bool) whenever the battery card is due.
    static let indraLockBattery = Notification.Name("indraLockBattery")
}

/// True while the pointer is over the lock screen lyrics (their own swipes move through the song).
enum LockGesture {
    static var overLyrics = false
}

/// Never takes the keyboard, so typing the password on the lock screen is never interrupted.
final class LockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
