import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController {
    private let panel = NotchPanel(contentRect: .zero,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false)
    private let state: NotchState
    /// The see-through window across the top of the screen: the focus progress line and the start wave.
    private let focusEdge: FocusEdgeController
    /// Shared with the lock screen player.
    var media: MediaController { state.media }
    var weather: WeatherController { state.weather }
    /// Audio levels shared with the lock screen visualizer.
    var levels: SmoothedLevel { state.audio.level }
    private var currentScreen: NSScreen?
    private var collapseTask: Task<Void, Never>?
    /// The pending opening while the pointer rests on the closed notch for the hover duration (Settings).
    private var hoverOpenTask: Task<Void, Never>?
    private var lastBounce = Date.distantPast
    private var fitTask: Task<Void, Never>?
    /// The card under the open notch (volume, Bluetooth, battery): its timer, and the window height it needs.
    private var stripTask: Task<Void, Never>?
    private var stripWindowExtra: CGFloat = 0
    private var screenObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var defaultsTask: Task<Void, Never>?
    private var liveMonitor: LiveActivityMonitor?
    private var taskPopups: TaskPopupScheduler?
    private var spaceObserver: NSObjectProtocol?
    private var autoIdentifyApplied: Bool?
    private var menuIsOpen = false
    private var clickMonitor: Any?
    private var appliedNotchSize: (Double, Double)?
    private var stickySpace: StickySpace?
    private var stickyApplied: Bool?
    /// While a file drag is active the notch windows leave the private Space, so they and the
    /// drop catcher share one ordinary Space and the catcher is really the front-most drop target.
    private var stickySuspended = false
    /// v498: a Space change that had to wait for the mouse button to be released.
    private var stickyRetry: Task<Void, Never>?
    /// True once the notch windows live only in the private Space (they then no longer join the desktops).
    private var stickyExclusive = false
    private var pageAnimationTask: Task<Void, Never>?
    private var contextMenu: NotchContextMenu?
    private var liveTask: Task<Void, Never>?
    private var bluetooth: BluetoothMonitor?
    /// Connecting audio devices switches the output, which changes the volume: no volume pop-up meanwhile.
    private var bluetoothQuietUntil = Date.distantPast
    private let appleHUD = AppleHUDController()
    /// v555: the bar on the LEFT edge, shown while the face scan animation owns the notch above an App Lock blur screen
    /// (made on first use). `edgeHUDEvent` is the last volume / brightness value received meanwhile.
    private var edgeHUD: AppleHUDController?
    private var edgeHUDEvent: SensoryEvent?
    private var edgeHUDShown = false
    private var edgeHUDWatch: Task<Void, Never>?
    private var edgeHUDFollowTask: Task<Void, Never>?
    /// v555: puts the notch panel back out of sight once a volume card shown over the blur screen has gone.
    private var coverPanelTask: Task<Void, Never>?
    /// v556: the short wait between the window growing and the inline volume bar starting to widen (see showLive).
    private var liveGrowTask: Task<Void, Never>?
    /// v563: the check that the inline volume bar really got its full width (see verifyInlineHUDWidth).
    private var hudVerifyTask: Task<Void, Never>?
    private let keyInterceptor = SystemKeyInterceptor()
    private var pausedAt: Date?
    private var idleGraceTask: Task<Void, Never>?
    private var sensory: SensoryMonitor?
    private var canAdjustBrightnessCache: Bool?
    private var canAdjustKeyboardCache: Bool?
    private var scrollMonitor: Any?
    private var swipeAccum: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    /// How far the fingers have travelled sideways (in either direction) during the current swipe.
    private var swipeSideways: CGFloat = 0
    private var swipeFired = false
    /// Retries the song card once if playback was not yet reported (see songChanged).
    private var songChangeTask: Task<Void, Never>?
    /// When the song changed while the notch was open (a skip from the notch itself, say), the pop-up could not show;
    /// it is shown when the notch closes. Holds the moment the song changed (nil when nothing is waiting).
    private var songCardPendingSince: Date?
    /// Keeps the calendar store warm while the notch is closed in Duo, so the first opening after a long rest runs
    /// exactly like the later ones.
    private var warmTimer: Timer?
    /// v553: offers the "update available" card again every minute while it is due but the notch was busy (main notch only).
    private var updateTimer: Timer?
    /// When the notch last closed. A long rest makes the first layout and render of the open page slow.
    private var lastCloseAt = Date.distantPast
    private var dragMonitor: Any?
    /// Invisible, ordinary window that receives file drops while the drop zones are open.
    /// (Windows in the private sticky Space are not reliable drop targets.)
    private var dropCatcherPanel: NSPanel?
    private var dropWatchdog: Task<Void, Never>?
    private var pageSelectTask: Task<Void, Never>?
    private var keyObservers = Set<AnyCancellable>()
    /// v504: the observers that had no handle (so they could never be removed); see `shutdown`.
    private var looseObservers: [NSObjectProtocol] = []

    /// v563: a notification observer that shutdown() removes. Six observers here were registered with a plain addObserver and kept
    /// for ever: three of them by every island, one more set for every time the external monitor was unplugged or woke up again.
    @discardableResult
    private func trackObserver(forName name: NSNotification.Name?, object: Any? = nil, queue: OperationQueue? = nil,
                               using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: queue, using: block)
        looseObservers.append(token)
        return token
    }
    private var isShutDown = false
    private var dragEnteredAt = Date.distantPast
    /// The zones were opened by a file drag (the notch was closed before), and the page that was showing.
    private var openedByDrag = false
    private var tabBeforeDrag: NotchTab?
    private var previewPinned = false
    /// v530: the intro animation. `introRunning` is true from the start until the notch is told to close (by the intro itself,
    /// or by anything forced); `state.introPlaying` stays on a little longer, so the closing animation keeps the intro's size.
    private var introRunning = false
    private var introTask: Task<Void, Never>?
    private var introStartTask: Task<Void, Never>?
    private var introResetTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var dragEndMonitor: Any?
    private var dragStartMonitor: Any?
    private var lastDropAt = Date.distantPast
    /// The files of the last drop: the same drop can arrive twice (window and pasteboard), a different one must not be lost.
    private var lastDropURLs: Set<URL> = []
    private var closeSoonTask: Task<Void, Never>?
    private var dragPasteboardCount = DragPasteboard.changeCount()
    /// True while the left button is down and the press began on the notch itself.
    private var pressStartedInside = false
    private var pressMonitor: Any?
    private var pressUpMonitor: Any?
    /// v439: true while the external notch is changing between the island and the notch look (see `morphLook`).
    private var lookMorphing = false
    private var lookTask: Task<Void, Never>?
    private var openWatchdog: Task<Void, Never>?
    private var lastKeyAt = Date.distantPast
    private var keyMonitor: Any?
    private var menuOpenedAt = Date.distantPast
    private var previewPinnedAt = Date.distantPast

    /// v429: true for the SECOND notch, the floating island on an external monitor. It is a complete notch of its own (it
    /// opens, closes and shows pages independently of the MacBook's) that shares the player, calendar and tray with the
    /// first, and only shows what the first one forwards to it (volume, Bluetooth, battery, pop-ups, song cards). The
    /// monitors that must exist once (keys, Bluetooth, battery, media callbacks, file-drag watching) run in the first only.
    private let isIsland: Bool
    private let openSettingsAction: () -> Void
    /// The island's controller, owned by the first controller (nil while there is no external monitor or it is switched off).
    private var island: NotchWindowController?

    private func resolveScreen() -> NSScreen? {
        isIsland ? NotchMetrics.islandScreen() : NotchMetrics.hostScreen()
    }

    init(openSettings: @escaping () -> Void, sharing primary: NotchWindowController? = nil) {
        isIsland = primary != nil
        openSettingsAction = openSettings
        let screen = primary != nil ? (NotchMetrics.islandScreen() ?? NotchMetrics.externalScreen()) : NotchMetrics.hostScreen()
        currentScreen = screen
        let initialState = NotchState(metrics: NotchMetrics.make(for: screen, island: primary != nil ? true : nil),
                                      sharing: primary?.state)
        state = initialState
        focusEdge = FocusEdgeController(state: initialState)
        buildContent(openSettings: openSettings)
        observeScreenChanges()
        installSwipeMonitor()
        if !isIsland {
            state.media.onPresenceChange = { [weak self] in
                self?.notePlaybackChange()
                self?.refreshIdle()
                self?.syncAudio()
                self?.island?.mediaPresenceChanged()
            }
            state.media.onSongChange = { [weak self] in self?.songChanged() }
        }
        observeDefaults()
        if !isIsland {
            let sensoryMonitor = SensoryMonitor { [weak self] event in self?.handleSensory(event) }
            sensoryMonitor.start()
            sensory = sensoryMonitor
            let monitor = LiveActivityMonitor { [weak self] activity in self?.showLive(activity) }
            monitor.start()
            liveMonitor = monitor
            startTaskPopups()
        }
        startKeepWarm()
        startUpdateWatch()
        observeSpaceChanges()
        applyWindowPrefs()
        if !isIsland { syncAutoIdentify() }
        stickySpace = StickySpace()
        appliedNotchSize = (Preferences.notchWidth, Preferences.notchHeight)
        state.onEditingEnded = { [weak self] in self?.editingEnded() }
        if !isIsland {
            trackObserver(forName: .indraFaceScanBusyChanged, object: nil, queue: .main) { [weak self] note in
                let busy = (note.object as? Bool) ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.faceScanBusy != busy else { return }
                    self.faceScanBusy = busy
                    if busy {
                        // A hover opening that was already counting down is dropped.
                        self.hoverOpenTask?.cancel()
                        self.hoverOpenTask = nil
                        if self.state.hoverCharging { self.state.hoverCharging = false }
                        // v555: a volume card shown over the blur screen gives the notch to the face scan animation.
                        self.endCoverHUD()
                    } else {
                        // v555: the face scan animation is gone: the bar on the left edge hands over to the normal display.
                        self.releaseEdgeHUD()
                    }
                    self.refreshIdle()
                }
            }
        }
        looseObservers.append(NotificationCenter.default.addObserver(forName: .indraAppLockCoverChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncCover()
                // The cover's window is placed a moment after it is shown: look once more when it has settled.
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.syncCover()
            }
        })
        installClickMonitor()
        installPressMonitors()
        installKeyMonitor()
        state.$isExpanded.removeDuplicates()
            .sink { [weak self] open in
                Task { @MainActor [weak self] in
                    if open { self?.startOpenWatchdog() } else { self?.openWatchdog?.cancel() }
                }
            }
            .store(in: &keyObservers)
        if !isIsland {
            observeGlassPreview()
            installDragMonitors()
            startBluetooth()
            startIntro()
            syncKeyInterceptor()
            observeHUDPreview()
        }
        // The panel may only take the keyboard on the to-do page.
        state.$tab.combineLatest(state.$isExpanded)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncKeyAllowance() }
            }
            .store(in: &keyObservers)
        // v436: each notch listens for the focus start; only the one where Start was pressed plays the animation.
        looseObservers.append(NotificationCenter.default.addObserver(forName: .indraFocusStarted, object: nil, queue: .main) { [weak self] note in
            let fromIsland = note.userInfo?["fromIsland"] as? Bool ?? false
            Task { @MainActor [weak self] in
                guard let self, self.isIsland == fromIsland else { return }
                self.focusStarted()
            }
        })
        if !isIsland {
            trackObserver(forName: .indraAirDropFinished, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.collapse() }
            }
            trackObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil,
                                                   queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncKeyInterceptor() }
            }
        }
    }

    func show() {
        guard !isShutDown else { return }
        if !isIsland { syncAudio() }
        let firstMode = resolveIdleMode()
        state.setIdle(firstMode, updateBadge: wantsUpdateBadge(for: firstMode))
        panel.setFrame(targetFrame, display: true)
        panel.orderFrontRegardless()
        focusEdge.show(on: currentScreen)
        syncStickySpace()
        if !isIsland { syncIsland() }
    }

    /// v429: the island's window leaves the screen (the external monitor was switched off or unplugged).
    private func hide() {
        collapseTask?.cancel()
        panel.orderOut(nil)
        focusEdge.panel.orderOut(nil)
    }

    /// Creates, moves or removes the island (the second notch) as the setting and the connected screens say.
    private func syncIsland() {
        guard !isIsland else { return }
        let wanted = NotchMetrics.islandScreen() != nil
        if wanted, island == nil {
            let created = NotchWindowController(openSettings: openSettingsAction, sharing: self)
            island = created
            created.show()
        } else if !wanted, let existing = island {
            existing.hide()
            // v504: dropping the reference was all that happened. The island's mouse and key monitors, its observers, its
            // timer and its private Space stayed registered for the rest of the session, one more set for every time the
            // external monitor was unplugged, switched off or woke up again (docks do that often).
            existing.shutdown()
            island = nil
        }
    }

    /// v504: ends this controller for good: every monitor, observer, timer and pending task is removed, its windows leave the
    /// screen and its private Space is given back. Used when the external monitor's island is removed. Safe to call twice.
    private func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for monitor in [clickMonitor, keyMonitor, scrollMonitor, pressMonitor, pressUpMonitor,
                        dragMonitor, dragStartMonitor, dragEndMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        clickMonitor = nil; keyMonitor = nil; scrollMonitor = nil
        pressMonitor = nil; pressUpMonitor = nil
        dragMonitor = nil; dragStartMonitor = nil; dragEndMonitor = nil
        for token in [screenObserver, defaultsObserver] { if let token { NotificationCenter.default.removeObserver(token) } }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        screenObserver = nil; defaultsObserver = nil; spaceObserver = nil
        for token in looseObservers { NotificationCenter.default.removeObserver(token) }
        looseObservers.removeAll()
        keyObservers.removeAll()
        warmTimer?.invalidate()
        warmTimer = nil
        updateTimer?.invalidate()
        updateTimer = nil
        // v523: the power / lock monitor has a stop() now (its run-loop source holds an unretained pointer to it).
        liveMonitor?.stop()
        liveMonitor = nil
        let tasks: [Task<Void, Never>?] = [collapseTask, hoverOpenTask, fitTask, stripTask, defaultsTask, liveTask,
                                            openTask, pageSelectTask, songChangeTask, previewTask, closeSoonTask,
                                            lookTask, openWatchdog, idleGraceTask, stickyRetry, pageAnimationTask,
                                            dropWatchdog, introTask, introStartTask, introResetTask,
                                            edgeHUDWatch, edgeHUDFollowTask, coverPanelTask, liveGrowTask, hudVerifyTask]
        tasks.forEach { $0?.cancel() }
        appleHUD.shutdown()
        edgeHUD?.shutdown()
        edgeHUD = nil
        // The windows leave the private Space before it is destroyed.
        if let stickySpace {
            stickySpace.remove([panel, focusEdge.panel])
            stickySpace.destroy()
        }
        stickySpace = nil
        focusEdge.shutdown()
        dropCatcherPanel?.orderOut(nil)
        dropCatcherPanel = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// Called by the first notch when playback starts, pauses or stops (the island follows its own idle look).
    fileprivate func mediaPresenceChanged() {
        notePlaybackChange()
        refreshIdle()
    }

    /// "Show now" in the percentage settings: a volume bar at 62 % plays in the closed notch.
    private func observeHUDPreview() {
        trackObserver(forName: .indraHUDPreview, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showLive(.hud(kind: .volume, value: 0.62, muted: false), duration: 2.6)
            }
        }
    }

    /// A focus session started (or resumed). The Duo page first shows the ring lighting up; then the notch folds away,
    /// and the moment it has closed the soft sound plays and the wave, in the colour of the session, leaves the notch
    /// for both ends of the screen. The line under the notch shows the time.
    private func focusStarted() {
        let wasOpen = state.isExpanded
        let tint = FocusTimer.shared.phase.tint
        collapseTask?.cancel()
        Task { @MainActor [weak self] in
            if wasOpen {
                // Hold the notch open for the ring's ignition (comet and bloom), then fold it.
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                // Paused again in that moment: nothing to fold for.
                guard FocusTimer.shared.isRunning else { return }
                self.collapse(force: true)
                // The notch needs a moment to fold shut; the sound and the wave start as it lands.
                try? await Task.sleep(nanoseconds: 320_000_000)
            }
            guard let self else { return }
            self.focusEdge.playWave(tint: tint)
            if Preferences.timerSound { SoftSound.focusStart() }
        }
    }

    // MARK: - Frames

    private func frame(for size: CGSize) -> NSRect {
        let screenFrame = (currentScreen ?? NSScreen.main)?.frame ?? .zero
        // While the open notch holds a card below it (volume, Bluetooth, battery), the window is taller by its height.
        let extra: CGFloat = (state.isExpanded && !state.isDropTargeted) ? stripWindowExtra : 0
        // v394: the island floats a little below the top edge of an external monitor (the notch is flush with it).
        let gap = state.metrics.topGap
        return NSRect(x: screenFrame.midX - size.width / 2,
                      y: screenFrame.maxY - gap - size.height - extra,
                      width: size.width,
                      height: size.height + extra)
    }

    private var closedFrame: NSRect {
        frame(for: closedWindowSize(slot: state.closedSlot, downline: state.isDownlineHUD))
    }

    /// Window size for the closed notch; larger while the downline volume / brightness overlay shows.
    private func closedWindowSize(slot: CGFloat, downline: Bool) -> CGSize {
        let base = state.metrics.closedWindowSize(slot: slot)
        guard downline else { return base }
        let hud = state.metrics.hudDownlineSize
        let card = state.metrics.bluetoothDownlineSize(slot: slot)
        let song = state.metrics.songDownlineSize(slot: slot)
        let cardWidth = max(hud.width, max(card.width, song.width))
        let cardHeight = max(hud.height, max(card.height, song.height))
        return CGSize(width: max(base.width, cardWidth + state.metrics.windowPadding),
                      height: max(base.height, cardHeight + 12))
    }
    private var expandedFrame: NSRect {
        // v530: the intro's notch is taller than any page, so its window is too.
        frame(for: state.introPlaying ? state.metrics.introWindowSize : state.metrics.expandedWindowSize)
    }
    private var mirrorFrame: NSRect { frame(for: state.metrics.mirrorWindowSize) }
    private var dropFrame: NSRect { frame(for: state.metrics.dropWindowSize) }

    /// Big enough for both the open page and the Mirror, so neither is clipped while the notch morphs between them.
    private var mirrorTransitionFrame: NSRect {
        let page = state.metrics.expandedWindowSize
        let mirror = state.metrics.mirrorWindowSize
        return frame(for: CGSize(width: max(page.width, mirror.width), height: max(page.height, mirror.height)))
    }

    /// Window frame that fits the current state.
    private var targetFrame: NSRect {
        // v364: between choosing the page and the notch starting to grow the window must stay large. A refit from
        // anywhere else (screen change, size setting) used to shrink it back to the closed size inside that gap,
        // and the notch then grew in a window that was resized under it.
        if openPending, !state.isExpanded { return expandedFrame }
        if !state.isExpanded { return closedFrame }
        if state.isDropTargeted { return dropFrame }
        // At the Duo size the camera preview fits the notch as it is: the window does not change.
        return state.showsMirror && state.tab != .duo ? mirrorFrame : expandedFrame
    }

    // MARK: - Content

    private func buildContent(openSettings: @escaping () -> Void) {
        let menuHandler = NotchContextMenu(openSettings: openSettings,
                                           onOpen: { [weak self] in
                                               self?.menuIsOpen = true
                                               self?.menuOpenedAt = Date()
                                           },
                                           onClose: { [weak self] in
                                               guard let self else { return }
                                               self.menuIsOpen = false
                                               // Stay open if the pointer is still over the notch.
                                               if !self.panel.frame.contains(NSEvent.mouseLocation) {
                                                   self.pointerExited()
                                               }
                                           })
        contextMenu = menuHandler
        let root = NotchRootView(state: state,
                                 requestExpand: { [weak self] in self?.expandFromClick() },
                                 toggleMirror: { [weak self] in self?.toggleMirror() },
                                 mirrorButton: { [weak self] in self?.mirrorButtonTapped() },
                                 selectTab: { [weak self] tab in self?.selectTab(tab) },
                                 openMonth: { [weak self] in self?.openDuoCalendar() })
        let host = FirstMouseHostingView(rootView: root.environment(\.notchIsland, isIsland))
        host.sizingOptions = []
        // Let the container receive file drops instead of the hosting view.
        host.unregisterDraggedTypes()

        let tracker = HoverTrackingView(frame: .zero)
        tracker.onEnter = { [weak self] in self?.pointerEntered() }
        tracker.onExit = { [weak self] in self?.pointerExited() }
        tracker.onMove = { [weak self] in self?.pointerMoved() }
        tracker.onDragEnter = { [weak self] in self?.dragEntered() }
        tracker.onDragExit = { [weak self] in self?.dragExited() }
        tracker.onDragMove = { [weak self] location, width in self?.dragMoved(location, viewWidth: width) }
        tracker.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
        tracker.onPromisedDrop = { [weak self] receivers, plain in self?.handlePromisedDrop(receivers, plain: plain) ?? false }
        tracker.menu = menuHandler.makeMenu()

        host.translatesAutoresizingMaskIntoConstraints = false
        tracker.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: tracker.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: tracker.trailingAnchor),
            host.topAnchor.constraint(equalTo: tracker.topAnchor),
            host.bottomAnchor.constraint(equalTo: tracker.bottomAnchor)
        ])
        panel.contentView = tracker
    }

    // MARK: - Expand / collapse

    /// On-screen rectangle of the visible notch body (screen coordinates, top aligned).
    /// `sides`: v459: also covers the round buttons the island keeps just outside its open body, so the pointer on them
    /// does not count as having left the notch.
    private func bodyRect(_ size: CGSize, inflate: CGFloat = 0, sides: Bool = false) -> NSRect {
        let screenFrame = (currentScreen ?? NSScreen.main)?.frame ?? .zero
        let gap = state.metrics.topGap
        let side = sides ? state.metrics.sideExtra : 0
        return NSRect(x: screenFrame.midX - size.width / 2 - inflate - side,
                      y: screenFrame.maxY - gap - size.height - inflate,
                      width: size.width + inflate * 2 + side * 2,
                      height: size.height + inflate + 12)
    }

    /// Hovering only opens the notch when the pointer is on the closed notch itself,
    /// not in the transparent margin of the window.
    private func pointerIsOnClosedNotch() -> Bool {
        bodyRect(state.closedBodySize, inflate: 2).contains(NSEvent.mouseLocation)
    }

    /// The pointer can enter the window's margin first and slide onto the notch afterwards.
    private func pointerMoved() {
        guard !coverHidden, !hoverBlockedByFaceScan, !state.isExpanded, !state.isDropTargeted, Preferences.expandOnHover,
              NSEvent.pressedMouseButtons == 0, pointerIsOnClosedNotch() else { return }
        pointerEntered()
    }

    /// "Expand notch on hover" is off: the pointer arriving near the closed notch only makes it give a small
    /// bounce (it stays closed; a click opens it as usual).
    private func bounceIfNeeded() {
        guard !coverHidden, !state.isExpanded, !state.isDropTargeted, NSEvent.pressedMouseButtons == 0,
              abs(panel.frame.height - closedFrame.height) < 1,
              Date().timeIntervalSince(lastBounce) > 1.0 else { return }
        lastBounce = Date()
        Haptics.hf2()   // the pointer reached the closed notch
        // Only the drawing bounces (inside the 8 pt margin the closed window already has): the window itself is
        // never resized, so opening stays exactly as it was.
        state.bounce()
    }

    private var lastHoverTap = Date.distantPast

    /// v371: THE tap of a hover opening, exactly one, sent the moment the pointer is on the notch and an opening
    /// begins (the start of the hover wait, or at once when there is none), BEFORE any opening work starts.
    ///
    /// What the tests on a real Mac showed: the motor is fine (v368 test: tap answer 0, felt), and a tap sent at this
    /// moment IS felt (v369), but the tap that v370 sent a few hundred ms later, after the opening had started, was
    /// not. Every earlier hover version (v363 to v368) also sent its tap at or after the opening began. So the
    /// rule is: the hover tap goes out when the pointer arrives, never after the opening has started. It is sent
    /// once per approach (a pointer wobbling over the edge of the window does not repeat it) and has its own short
    /// lockout (`Haptics.hover`), so no unrelated tap just before it can swallow it.
    private func hoverTap() {
        guard Date().timeIntervalSince(lastHoverTap) > 0.5 else { return }
        lastHoverTap = Date()
        Haptics.hover()
    }

    /// v479: while the face scan animation is on screen the notch does not open on hover (the scan window sits on the
    /// same spot, and hovering it is how the scan itself is retried). Only the MacBook's notch; the external island is
    /// not covered by the scan window.
    private var hoverBlockedByFaceScan: Bool { faceScanBusy && !isIsland && !state.isExpanded }

    private func pointerEntered() {
        guard !coverHidden else { return }
        if hoverBlockedByFaceScan {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            if state.hoverCharging { state.hoverCharging = false }
            return
        }
        collapseTask?.cancel()
        // The pointer is at the notch: make sure the trackpad motor is open now, so the tap that follows finds it ready.
        Haptics.prime()
        guard Preferences.expandOnHover else {
            bounceIfNeeded()
            return
        }
        // A pressed button means a drag is under way: never open the player for it.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            if dragHasFiles(), !state.isExpanded { dragEntered() }
            return
        }
        guard state.isExpanded || pointerIsOnClosedNotch() else { return }
        let opening = !state.isExpanded
        // Opening by hover waits for the hover duration: the pointer has to rest on the notch for that long
        // (leaving it, or pressing a button, cancels the opening). Already open: nothing to wait for.
        if opening {
            let delay = Preferences.hoverDelay
            if delay > 0.001 {
                guard hoverOpenTask == nil else { return }
                state.hoverChargeDuration = delay
                state.hoverCharging = true
                hoverTap()
                hoverOpenTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.hoverOpenTask = nil
                    self.state.hoverCharging = false
                    guard !self.state.isExpanded, !self.state.isDropTargeted, !self.hoverBlockedByFaceScan,
                          NSEvent.pressedMouseButtons == 0, self.pointerIsOnClosedNotch() else { return }
                    self.expand(byHover: true)
                }
                return
            }
        }
        // No hover wait: the tap first, then the opening.
        if opening, !openPending {
            hoverTap()
        }
        expand()
    }

    /// Size of the visible panel while the notch is open.
    private var openBodySize: CGSize {
        if state.introPlaying { return state.metrics.introSize }
        if state.isDropTargeted { return state.metrics.dropSize }
        let full: CGSize
        if state.showsMirror { full = state.isDuoSized ? state.metrics.duoMirrorSize : state.metrics.mirrorSize }
        else if state.isDuoLarge { full = state.metrics.duoLargeSize }
        else if state.isDuoSized { full = state.metrics.duoSize }
        else { full = state.metrics.expandedSize }
        // v459: the island has no header row, so its open body is shorter (as drawn in NotchRootView).
        return CGSize(width: full.width, height: full.height - state.islandHeaderSaving)
    }

    private func isPointerNearOpenNotch() -> Bool {
        guard state.isExpanded else { return false }
        // While a file drag has the drop zones open, the drag itself decides when the notch closes
        // (dragExited, the drop, or the watchdog). Without this, the pointer counted as "away" for any
        // press that began outside the notch, which is exactly what a file drag from Finder is.
        if state.isDropTargeted { return true }
        if NSEvent.pressedMouseButtons != 0 {
            // A press that began on the notch (dragging the seek bar, dragging a file out of the tray)
            // must not close it halfway; a press that began elsewhere does.
            return pressStartedInside
        }
        pressStartedInside = false
        let body = CGSize(width: openBodySize.width, height: openBodySize.height + state.stripHeight)
        return bodyRect(body, inflate: 24, sides: true).contains(NSEvent.mouseLocation)
    }

    private func pointerExited() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        if state.hoverCharging { state.hoverCharging = false }
        collapseTask?.cancel()
        // Opening the drop catcher or moving the windows between Spaces makes the notch window report
        // "pointer exited" while the file is still over it: that must not start a close.
        guard !menuIsOpen, !state.isEditing, !state.isDropTargeted else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Leaving the window edge is not enough: stay open while the pointer is still close
            // to the visible panel, and close once it has really moved away.
            while !Task.isCancelled {
                guard let self, self.isPointerNearOpenNotch() else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    /// True between choosing the page and the notch starting to grow (a few milliseconds).
    private var openPending = false
    private var openTask: Task<Void, Never>?

    /// Opening runs in two steps so every opening animates the same way. Step one (here, at once) enlarges the
    /// window and puts the page in place while the notch is still closed. Step two, one moment later, starts the
    /// growing. Doing all the layout work inside the first frames of the animation made some openings (the first
    /// after a rest) lose a frame at the start and look different from the rest.
    /// A click on the closed notch opens it (with the same tap as opening by hover; nothing when it is already open).
    private func expandFromClick() {
        guard !coverHidden, !state.isExpanded, !openPending else { return }
        Haptics.hf1()
        expand()
    }

    private func expand(tab: NotchTab? = nil, byHover: Bool = false) {
        collapseTask?.cancel()
        fitTask?.cancel()
        guard !coverHidden, !state.isExpanded, !openPending else { return }
        // v530: an ordinary opening right after an intro must not come up in the intro's size.
        if state.introPlaying, !introRunning {
            introResetTask?.cancel()
            state.setIntro(false)
        }
        state.openedByHover = byHover
        panel.ignoresMouseEvents = false
        panel.setFrame(expandedFrame, display: false)
        let target = tab ?? defaultTab()
        state.setDuoLayout(effectiveIdleConfig() == .duo)
        DuoVinylState.state(island: isIsland).beginOpening()
        // v480: today is back in focus BEFORE the notch grows, while nothing is visible. The reset that follows a closing
        // runs 0.55 s after it and is cancelled by an opening that comes sooner, so a day picked in the calendar was
        // still showing when the page opened and then visibly changed to today.
        state.calendar.resetToToday()
        state.prepareOpen(tab: target)
        // After a long rest the first layout and render of the open page is slow and used to land inside the first
        // frames of the animation (content arrived late, a touch of stutter). Do that work now, before the animation
        // starts, so a first opening looks like the quick ones that follow it.
        // v364: the window's new size must reach the SwiftUI view BEFORE the notch starts to grow, every time (not
        // only after a long rest). If the view is still at the old, narrow size when the growing starts, its
        // centring is recomputed inside the animation and the notch slides open from left to right.
        panel.contentView?.layoutSubtreeIfNeeded()
        if Date().timeIntervalSince(lastCloseAt) > 4 { panel.displayIfNeeded() }
        openPending = true
        openTask?.cancel()
        openTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self, !Task.isCancelled else { return }
            // Make sure the view really has the open window's width. Rarely it has not caught up yet (a busy main
            // thread): wait a frame at a time, at most a few, instead of animating across the resize.
            var tries = 0
            while tries < 6 {
                let want = self.expandedFrame
                if abs(self.panel.frame.width - want.width) > 0.5 || abs(self.panel.frame.minX - want.minX) > 0.5 {
                    self.panel.setFrame(want, display: false)
                }
                self.panel.contentView?.layoutSubtreeIfNeeded()
                let viewWidth = self.panel.contentView?.bounds.width ?? want.width
                if abs(viewWidth - self.panel.frame.width) < 0.5 { break }
                tries += 1
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
            }
            self.openPending = false
            self.state.expand(tab: target)
            DuoVinylState.state(island: self.isIsland).endOpening()
            self.pageAnimationTask?.cancel()
            self.pageAnimationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                self?.state.setAnimatesPages(true)
            }
            // Asking the players for their state is not needed while the notch grows: the answers re-draw the page,
            // and that work used to land in the middle of the animation as a small hitch. It runs once the notch
            // has settled instead.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled, self.state.isExpanded else { return }
            self.state.media.refresh()
        }
    }

    private func observeGlassPreview() {
        trackObserver(forName: .indraGlassPreview, object: nil, queue: .main) { [weak self] note in
            let editing = (note.object as? Bool) ?? false
            Task { @MainActor [weak self] in self?.setGlassPreview(editing) }
        }
    }

    /// While the glass slider is dragged, show the notch (and the Apple-style HUD when chosen).
    private func setGlassPreview(_ editing: Bool) {
        previewTask?.cancel()
        let sample = SensoryEvent(kind: .volume, value: 0.6, muted: false)
        if editing {
            previewPinned = true
            previewPinnedAt = Date()
            collapseTask?.cancel()
            if !state.isExpanded { expand() }
            if Preferences.sensoryStyle == "apple" {
                appleHUD.show(sample, on: currentScreen, accent: nil, duration: 60)
            }
        } else {
            if Preferences.sensoryStyle == "apple" {
                appleHUD.show(sample, on: currentScreen, accent: nil, duration: 0.9)
            }
            previewTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, let self else { return }
                self.previewPinned = false
                self.collapse()
            }
        }
    }

    /// Typing is only for the to-do page; on every other page the panel must not hold the keyboard.
    private func syncKeyAllowance() {
        let allowed = state.isExpanded && state.tab == .todo
        panel.allowsKey = allowed
        guard !allowed, panel.isKeyWindow else { return }
        // Settings is open: Indra is the app in front now and must stay so (the keyboard is not handed back).
        guard !AppPresence.hasWindow else { panel.makeFirstResponder(nil); panel.resignKey(); return }
        // It was key (a click, an old to-do edit): hand the keyboard back to the app the user was in.
        panel.makeFirstResponder(nil)
        panel.resignKey()
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            front.activate()
        }
    }

    private func collapse(force: Bool = false) {
        if openPending, !previewPinned, force || !introRunning {
            // Closed again before the notch had started to grow: nothing is open, only the window is large.
            openTask?.cancel()
            openPending = false
            panel.ignoresMouseEvents = true
            scheduleFit()
            introClosed()
            return
        }
        guard state.isExpanded, !previewPinned else { return }
        // v530: while the intro plays only the intro itself closes the notch (pointer, clicks and the watchdog do not).
        guard force || !introRunning else { return }
        // A stray close (hover timer, swipe, finished AirDrop) must not shut the drop zones under a file.
        guard force || !state.isDropTargeted else { return }
        stripTask?.cancel()
        stripWindowExtra = 0
        state.collapse()
        introClosed()
        lastCloseAt = Date()
        showPendingSongCard()
        syncKeyAllowance()
        // The window stays large until the close animation ends; it must not react to the pointer
        // meanwhile, or moving the cursor near the notch would reopen it.
        panel.ignoresMouseEvents = true
        scheduleFit()
    }

    /// The header's camera button. First press: the preview opens and the camera starts at once.
    /// While the preview is open, pressing it again closes it and goes back to the player
    /// (the player + calendar page with the Duo size).
    private func mirrorButtonTapped() {
        guard state.isExpanded, !state.mirrorClosing, !introRunning else { return }
        if state.showsMirror {
            if !state.duoLayout, state.tab != .player { state.select(.player) }
            closeMirror()
        } else if state.duoLayout, state.tab != .duo {
            // Duo's camera is the Duo-sized page on top of the player + calendar page: from the Zen space,
            // weather, to-do or the tray it slides in from there.
            Haptics.hf1()
            enterMirror(move: CGSize(width: 0, height: 1))
            state.mirror.start()
        } else {
            Haptics.hf1()
            toggleMirror()
            state.mirror.start()
        }
    }

    private func toggleMirror() {
        guard state.isExpanded else { return }
        if state.showsMirror {
            closeMirror()
            return
        }
        Haptics.hf1()
        state.setPageMove(CGSize(width: 0, height: 1))
        state.setAnimatesPages(true)
        fitTask?.cancel()
        if state.tab != .duo { panel.setFrame(mirrorTransitionFrame, display: true) }
        state.setMirror(true)
        scheduleFit()
    }

    /// The camera circle disappears first, then the notch shrinks.
    private func closeMirror() {
        guard !state.mirrorClosing else { return }
        Haptics.hf1()
        state.setMirrorClosing(true)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self else { return }
            // The notch may have closed in the meantime: do not grow the window of a closed notch.
            guard self.state.isExpanded, self.state.showsMirror else {
                self.state.setMirrorClosing(false)
                return
            }
            self.state.setPageMove(CGSize(width: 0, height: -1))
            self.state.setAnimatesPages(true)
            self.fitTask?.cancel()
            if self.state.tab != .duo { self.panel.setFrame(self.mirrorTransitionFrame, display: true) }
            self.state.setMirror(false)
            self.state.setMirrorClosing(false)
            self.scheduleFit()
        }
    }

    /// The camera fades out, then the chosen page replaces it and the camera box closes in a single state change,
    /// so the notch only ever animates from the camera size straight to the new page's size.
    private func leaveMirror(to tab: NotchTab, move: CGSize) {
        guard !state.mirrorClosing else { return }
        Haptics.hf1()
        state.setMirrorClosing(true)
        pageSelectTask?.cancel()
        pageSelectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.state.isExpanded, self.state.showsMirror else {
                self.state.setMirrorClosing(false)
                return
            }
            self.fitTask?.cancel()
            self.state.setPageMove(move)
            self.state.setAnimatesPages(true)
            if self.state.tab != .duo { self.panel.setFrame(self.mirrorTransitionFrame, display: true) }
            self.state.select(tab)
            self.state.setMirror(false)
            self.state.setMirrorClosing(false)
            self.scheduleFit()
        }
    }

    /// v443: Duo's month name was clicked: the notch becomes the month calendar of a notch without Duo (its size, its page),
    /// with the same soft reveal the weather and to-do pages use (the page blurs and grows out of the top edge while the
    /// notch glides to the new size).
    private func openDuoCalendar() {
        guard state.isExpanded, state.duoLayout, state.tab == .duo, !state.showsMirror, !state.isDropTargeted else { return }
        changePage(to: .calendar, move: CGSize(width: 1, height: 0))
    }

    /// v443: from the Duo calendar page back to the Duo page: today is in focus again, as every Duo opening has it.
    private func leaveDuoCalendar(to tab: NotchTab) {
        state.calendar.resetToToday()
        changePage(to: tab, move: CGSize(width: -1, height: 0))
    }

    private func selectTab(_ tab: NotchTab) {
        guard !introRunning else { return }
        if state.duoLayout, state.tab == .calendar, !state.showsMirror {
            if tab == .duo || tab == .player {
                leaveDuoCalendar(to: .duo)
            } else {
                changePage(to: tab, move: tab == .tray ? CGSize(width: -1, height: 0) : CGSize(width: 0, height: 1))
            }
            return
        }
        // The tray sits to the right of the player: going there slides left, coming back slides right.
        let move: CGSize
        if tab == .tray {
            move = CGSize(width: -1, height: 0)
        } else if state.tab == .tray {
            move = CGSize(width: 1, height: 0)
        } else {
            move = CGSize(width: 0, height: 1)
        }
        changePage(to: tab, move: move)
    }

    /// Vertical pages, in order. Swiping down / up walks this list and wraps around.
    /// To add a page later, append it here.
    private var verticalPages: [NotchTab] {
        // Duo already shows the calendar, so no separate calendar page sits behind it.
        if state.duoLayout { return [.duo] }
        var pages: [NotchTab] = [.player]
        if Preferences.showDate || Preferences.showCalendar { pages.append(.calendar) }
        return pages
    }

    private func cyclePage(step: Int) {
        let pages = verticalPages
        guard pages.count > 1 else { return }
        let current = pages.firstIndex(of: state.tab) ?? (step > 0 ? -1 : 0)
        let next = ((current + step) % pages.count + pages.count) % pages.count
        Haptics.hf1()
        changePage(to: pages[next], move: CGSize(width: 0, height: CGFloat(step)))
    }

    /// Any Duo page -> Duo's camera page (opened with the header's camera button), sliding in from the given side.
    private func enterMirror(move: CGSize) {
        guard state.isExpanded else { return }
        Haptics.hf1()
        pageSelectTask?.cancel()
        fitTask?.cancel()
        state.setPageMove(move)
        state.setAnimatesPages(true)
        state.select(.duo)
        state.setMirror(true)
        scheduleFit()
    }

    /// The direction is published first so both the outgoing and incoming page see it.
    private func changePage(to requested: NotchTab, move: CGSize) {
        // While the tray lives on Duo's Zen page, asking for the tray means that page.
        let tab = state.resolvedTab(requested)
        if state.showsMirror {
            // Camera open (in Duo too) and another page is chosen: the camera fades, then the page and the notch
            // size change in ONE step. Closing the camera first and selecting the page 20 ms later let the notch
            // drop to the narrow camera size and spring back to Duo (the notch glitch with the tray).
            if state.tab == tab { closeMirror() } else { leaveMirror(to: tab, move: move) }
            return
        }
        guard state.tab != tab else { return }
        Haptics.hf1()   // the page really changes: one tap, whichever way it was asked for (a second one is merged)
        state.setPageMove(move)
        state.setAnimatesPages(true)
        pageSelectTask?.cancel()
        pageSelectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            self?.state.select(tab)
        }
    }

    /// Resize the window to fit the state only after the animation has finished.
    private func scheduleFit() {
        fitTask?.cancel()
        fitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, let self else { return }
            self.panel.setFrame(self.targetFrame, display: true)
            // Closed: go back to the default page while nothing is visible.
            if !self.state.isExpanded {
                self.state.resetPage()
                self.panel.ignoresMouseEvents = false
            }
        }
    }

    // MARK: - File drops

    /// True only for a drag that started after the last mouse-down (the drag pasteboard keeps old content).
    private func dragHasFiles() -> Bool {
        let board = NSPasteboard(name: .drag)
        // v563: the count is synchronised first (macOS 27 otherwise keeps the old one during a Finder drag).
        guard DragPasteboard.changeCount() != dragPasteboardCount else { return false }
        // v490: only the declared types are looked at; the sender is never asked for a file.
        return DropFiles.hasFiles(in: board)
    }

    /// Backup for drags whose enter event never reaches the window: watch the drag globally
    /// and open the drop zones as soon as a file is dragged to the notch.
    private func installDragMonitors() {
        dragStartMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dragPasteboardCount = DragPasteboard.changeCount()
            }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                // v563: macOS 27 starts Mission Control when a file drag lingers in the menu bar strip: while the drop zones are
                // open, the pointer is kept just below that strip.
                if self.state.isDropTargeted { self.holdPointerBelowMenuBar(mouse) }
                if self.state.isDropTargeted {
                    // Dragged away from the notch again.
                    if !self.bodyRect(CGSize(width: self.state.metrics.dropSize.width, height: max(self.state.metrics.dropSize.height, 150)), inflate: 20).contains(mouse) {
                        self.dragExited(force: true)
                    } else {
                        // The window under the drag does not always report where it is: follow the mouse
                        // ourselves so the zone under the file always gets its border.
                        self.updateDropZoneFromMouse()
                    }
                } else if !self.state.isExpanded,
                          // A wide, tall area: the drop zones open well before the cursor reaches the
                          // top screen edge, where macOS would open Mission Control.
                          self.bodyRect(CGSize(width: 380, height: 150)).contains(mouse),
                          self.dragHasFiles() {
                    self.dragEntered()
                    self.holdPointerBelowMenuBar(mouse)
                }
            }
        }
        dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isDropTargeted else { return }
                // A drop on the notch is handled by the window itself; closing it right now
                // would make the panel ignore the drop. Only clean up if nothing arrives.
                let upLocation = NSEvent.mouseLocation
                // v500: whatever happens to this drop, a file that macOS moves to the Desktop is put back.
                DesktopCopyGuard.watch(sources: DropFiles.declaredFileURLs(in: NSPasteboard(name: .drag)), since: self.dragEnteredAt)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard let self, self.state.isDropTargeted, !self.promisedDropPending else { return }
                    // No window received the drop: take the files from the drag pasteboard.
                    if self.deliverPasteboardDrop(at: upLocation) { return }
                    self.dragExited(force: true)
                }
            }
        }
    }

    /// v563: on macOS 27 a file drag that stays in the menu bar strip for a tenth of a second or so starts Mission Control (the
    /// setting "Drag windows to top of screen" does not cover files), even above the open drop zones. While a file is being
    /// dragged over them the pointer therefore stops 6 points below the menu bar. It needs no permission, only acts while the
    /// mouse button is down, and ends with the drag. Earlier macOS versions are not touched.
    private func holdPointerBelowMenuBar(_ mouse: NSPoint) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              NSEvent.pressedMouseButtons & 1 != 0,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let primary = NSScreen.screens.first else { return }
        let floorY = screen.visibleFrame.maxY - 6
        guard mouse.y > floorY else { return }
        // Quartz counts from the top left of the main display, AppKit from its bottom left.
        CGWarpMouseCursorPosition(CGPoint(x: mouse.x, y: primary.frame.maxY - floorY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func updateDropZoneFromMouse() {
        guard state.isDropTargeted else { return }
        let frame = dropFrame
        let mouse = NSEvent.mouseLocation
        dragMoved(NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY), viewWidth: frame.width)
    }

    /// Takes the dragged files straight from the system drag pasteboard and drops them into the
    /// zone under `location`. Used when no window received the drop.
    @discardableResult
    private func deliverPasteboardDrop(at location: NSPoint) -> Bool {
        guard state.isDropTargeted, !promisedDropPending, dragHasFiles() else { return false }
        let area = bodyRect(CGSize(width: state.metrics.dropSize.width,
                                   height: max(state.metrics.dropSize.height, 150)),
                            inflate: 30)
        guard area.contains(location) else { return false }
        // v485: real files as they are; promised files are received into Indra's own folder (never the Desktop).
        let board = NSPasteboard(name: .drag)
        // v490: promises first (see DropFiles); their file URLs are never requested.
        let receivers = DropFiles.promiseReceivers(in: board)
        var urls = DropFiles.plainFileURLs(in: board)
        if urls.isEmpty, receivers.isEmpty { urls = DropFiles.legacyFileURLs(in: board) }
        if urls.isEmpty, receivers.isEmpty { urls = DropFiles.imageFiles(in: board) }
        guard !urls.isEmpty || !receivers.isEmpty else { return false }
        Trace.log("DROP: no window took the drop, files taken from the drag pasteboard (\(urls.count) files, \(receivers.count) promised)")
        let frame = dropFrame
        dragMoved(NSPoint(x: location.x - frame.minX, y: location.y - frame.minY), viewWidth: frame.width)
        if !receivers.isEmpty { return handlePromisedDrop(receivers, plain: urls) }
        return handleDrop(urls)
    }

    /// v485: true while promised files of a drop are still being received. The backup paths that clean up after a drag
    /// (button released, watchdog) leave the drop alone for that time.
    private var promisedDropPending = false

    /// A drop of promised files (Mail, Safari, Photos ...): they are received into Indra's own temporary folder, then
    /// handled exactly like a normal drop on the zone that was under them when they were dropped.
    private func handlePromisedDrop(_ receivers: [NSFilePromiseReceiver], plain: [URL] = []) -> Bool {
        guard !promisedDropPending else { return true }
        let zone = state.activeDropZone ?? .tray
        promisedDropPending = true
        DropFiles.receive(receivers) { [weak self] urls in
            guard let self else { return }
            self.promisedDropPending = false
            let all = plain + urls
            if all.isEmpty {
                // Nothing arrived: just close the drop buttons again.
                if self.state.isDropTargeted { self.dragExited(force: true) }
                return
            }
            _ = self.handleDrop(all, zone: zone)
        }
        return true
    }

    private func showDropCatcher() {
        let catcher: NSPanel
        if let existing = dropCatcherPanel {
            catcher = existing
        } else {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: false)
            created.isReleasedWhenClosed = false
            created.isOpaque = false
            created.backgroundColor = NSColor(white: 0, alpha: 0.01)
            created.hasShadow = false
            created.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            created.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let tracker = HoverTrackingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            tracker.onDragEnter = { [weak self] in self?.dragEntered() }
            tracker.onDragExit = { [weak self] in self?.dragExited() }
            tracker.onDragMove = { [weak self] location, width in self?.dragMoved(location, viewWidth: width) }
            tracker.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
            tracker.onPromisedDrop = { [weak self] receivers, plain in self?.handlePromisedDrop(receivers, plain: plain) ?? false }
            created.contentView = tracker
            dropCatcherPanel = created
            catcher = created
        }
        catcher.setFrame(dropFrame, display: false)
        catcher.orderFrontRegardless()

        // Safety net: whatever happens to the drag, the invisible window must not stay and block clicks.
        dropWatchdog?.cancel()
        dropWatchdog = Task { [weak self] in
            var sawDown = NSEvent.pressedMouseButtons & 1 != 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.state.isDropTargeted else {
                    self.hideDropCatcher()
                    return
                }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    sawDown = true
                    continue
                }
                // The button is up: the drag is over. Give a window a moment to take the drop,
                // otherwise take the files from the drag pasteboard ourselves.
                let releasedAt = NSEvent.mouseLocation
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                if self.promisedDropPending { return }
                if self.state.isDropTargeted, sawDown, self.deliverPasteboardDrop(at: releasedAt) { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                if self.promisedDropPending { return }
                if self.state.isDropTargeted { self.dragExited(force: true) }
                self.hideDropCatcher()
                return
            }
        }
    }

    private func hideDropCatcher() {
        dropCatcherPanel?.orderOut(nil)
        if stickySuspended {
            stickySuspended = false
            syncStickySpace()
            panel.orderFrontRegardless()
        }
    }

    private func dragEntered() {
        guard !state.isDropTargeted, !FileSharing.isDraggingFromTray, !introRunning else { return }
        collapseTask?.cancel()
        fitTask?.cancel()
        panel.ignoresMouseEvents = false
        // v498: the notch windows no longer leave the private Space here. They used to be moved out of it (and back after
        // the drop) in the middle of the drag. A window-server Space change while a drag is in flight makes the drag lose
        // its destination (the "exit although the pointer never moved" below), so the drop then fell through to the
        // Desktop (the copy there), and it also ran right while Blip was being launched, which is the one moment the
        // whole Mac was seen to freeze. The drop catcher is its own ordinary window and receives the drop on its own.
        // v544: from the first moment of a file drag, the private trackpad driver is left alone (the tap below and the ones while
        // the file moves over the buttons are the system's own pattern) and the steps are written to the freeze trail.
        TrackpadActuator.shared.stayQuiet(for: 60, why: "file drag")
        FreezeTrail.mark("drag entered the notch")
        Haptics.hf1()   // a file drag opens the drop buttons
        dragEnteredAt = Date()
        openedByDrag = !state.isExpanded
        tabBeforeDrag = state.isExpanded ? state.tab : nil
        stripTask?.cancel()
        state.setStrip(nil)
        stripWindowExtra = 0
        panel.setFrame(dropFrame, display: true)
        showDropCatcher()
        state.setMirror(false)
        state.activeDropZone = nil
        state.isDropTargeted = true
        updateDropZoneFromMouse()
        if state.isExpanded {
            state.select(.tray)
        } else {
            state.setDuoLayout(effectiveIdleConfig() == .duo)
            state.expand(tab: .tray)
        }
        collapseTask?.cancel()
    }

    /// `force` is for the cases that really mean the drag is over or has left (global mouse position, button up).
    /// An "exit" reported by a window is not trusted: when the drop catcher opens under the pointer, or the
    /// windows change Space, the window that had the drag reports an exit although the pointer never moved.
    /// Believing it closed the notch and reopened it a moment later, which showed as flickering.
    private func dragExited(force: Bool = false) {
        if !force {
            if Date().timeIntervalSince(dragEnteredAt) < 0.7 { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                let area = bodyRect(CGSize(width: state.metrics.dropSize.width,
                                           height: max(state.metrics.dropSize.height, 150)),
                                    inflate: 40)
                if area.contains(NSEvent.mouseLocation) { return }
            }
        }
        dropWatchdog?.cancel()
        hideDropCatcher()
        let closeAtOnce = openedByDrag
        let previous = tabBeforeDrag
        openedByDrag = false
        tabBeforeDrag = nil
        state.activeDropZone = nil
        if closeAtOnce {
            // The drag opened the notch and was dragged away again: close it straight from the drop
            // zones, instead of letting it grow to a full page first.
            collapse(force: true)
            state.isDropTargeted = false
            return
        }
        state.isDropTargeted = false
        // Drag cancelled over an open notch: go back to the page that was showing before.
        if let previous, state.tab == .tray || state.tab == state.resolvedTab(.tray),
           previous != .tray, previous != state.resolvedTab(.tray) {
            changePage(to: previous, move: CGSize(width: 1, height: 0))
        }
        pointerExited()
    }

    /// Maps the drag position to the zone under it (zones share the width equally).
    private func dragMoved(_ location: NSPoint, viewWidth: CGFloat) {
        let zones = state.dropZones
        guard state.isDropTargeted, !zones.isEmpty else { return }
        let bodyWidth = state.metrics.dropSize.width
        let innerLeft = (viewWidth - bodyWidth) / 2 + 36
        let innerWidth = bodyWidth - 72
        // The zones are separated by gaps: split at the middle of each gap.
        let spacing = DropZonesView.spacing
        let count = CGFloat(zones.count)
        let zoneWidth = max((innerWidth - spacing * (count - 1)) / count, 1)
        let raw = Int(floor((location.x - innerLeft + spacing / 2) / (zoneWidth + spacing)))
        let zone = zones[min(max(raw, 0), zones.count - 1)]
        if state.activeDropZone != zone {
            state.activeDropZone = zone
            Haptics.hf1(lockout: 0.03)   // the dragged files reach another button
        }
    }

    private func handleDrop(_ urls: [URL], zone forcedZone: DropZone? = nil) -> Bool {
        // Only the same files arriving twice within a second are ignored. A second, different batch dropped right
        // after the first used to be swallowed here (reported as accepted, but never sent or added).
        let dropped = Set(urls.map { $0.standardizedFileURL })
        TrackpadActuator.shared.stayQuiet(for: 180, why: "file drop")
        FreezeTrail.mark("drop: \(urls.count) file(s) on \((forcedZone ?? state.activeDropZone ?? .tray).rawValue)")
        if Date().timeIntervalSince(lastDropAt) < 1, dropped == lastDropURLs { return true }
        lastDropAt = Date()
        lastDropURLs = dropped
        // v498: if macOS also handed this drop to the Desktop, the stray copy there goes to the Trash (see DesktopCopyGuard).
        DesktopCopyGuard.watch(sources: urls, since: dragEnteredAt)
        closeSoonTask?.cancel()
        openedByDrag = false
        tabBeforeDrag = nil
        let zone = forcedZone ?? state.activeDropZone ?? .tray
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.hideDropCatcher()
        }
        // AirDrop / Blip: the sharing window opens at once and the notch closes straight from the drop buttons,
        // without first growing into the tray page (that was a visible detour, and it delayed the popup).
        if (zone == .airDrop || zone == .blip), !urls.isEmpty, !FileSharing.isDraggingFromTray {
            if zone == .airDrop { FileSharing.airDrop(urls) } else { FileSharing.blip(urls) }
            collapse(force: true)
            state.isDropTargeted = false
            state.activeDropZone = nil
            scheduleFit()
            return true
        }
        state.isDropTargeted = false
        state.activeDropZone = nil
        scheduleFit()
        guard !urls.isEmpty else {
            pointerExited()
            return false
        }
        if FileSharing.isDraggingFromTray {
            // A tray file dropped back on the notch.
            pointerExited()
            return false
        }
        switch zone {
        case .tray:
            state.tray.add(urls)
            state.select(.tray)
            // The window shrinks from the wide drop size to the page size, so the pointer can end up outside
            // it without any exit event: start the normal "close when the pointer is away" watch.
            pointerExited()
        case .airDrop:
            FileSharing.airDrop(urls)
            closeSoon()
        case .blip:
            FileSharing.blip(urls)
            closeSoon()
        }
        return true
    }

    /// The files are on their way to another app: the notch has nothing more to show.
    private func closeSoon() {
        closeSoonTask?.cancel()
        closeSoonTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    // MARK: - Idle activity

    /// The chosen Idle Activity (or, with "Most recent", whatever suits the moment).
    private func effectiveIdleConfig() -> IdleMode {
        let hasTrack = state.media.track != nil
        if Preferences.idleMostRecent(island: isIsland) { return hasTrack ? .playing : .calendar }
        return IdleMode(rawValue: Preferences.idleActivity(island: isIsland)) ?? .playing
    }

    /// What the closed notch shows: the now-playing activity (artwork + visualizer) while something plays,
    /// unless Idle Activity is set to None. After playback stops it stays for 5 seconds, then hides.
    /// v468: true while the face scan animation owns the notch area. The live activity (artwork and visualizer beside the
    /// notch) waits until that animation is gone, then slides in.
    private var faceScanBusy = false

    /// v477: true while an App Lock blur cover is on screen. Indra's notch then draws nothing and ignores the pointer:
    /// no hover opening, no closed notch, no live activity, no strip. The face scan animation (its own window) is
    /// the only thing that may appear at the notch.
    private var coverHidden = false

    /// Hidden only when the cover is on THIS notch's screen (a cover on the MacBook does not hide the external island).
    private func syncCover() {
        setCoverHidden(AppLockController.shared.isCoverShown(on: currentScreen))
    }

    private func setCoverHidden(_ hidden: Bool) {
        guard hidden != coverHidden else { return }
        coverHidden = hidden
        if hidden {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            if state.hoverCharging { state.hoverCharging = false }
            if openPending || state.isExpanded { collapse(force: true) }
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        } else {
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        }
        refreshIdle()
    }

    private func resolveIdleMode() -> IdleMode {
        if faceScanBusy && !isIsland { return .none }
        if coverHidden { return .none }
        if effectiveIdleConfig() == .none { return .none }
        guard let track = state.media.track else { return .none }
        if track.isPlaying { return .playing }
        if let pausedAt, Date().timeIntervalSince(pausedAt) < 5 { return .playing }
        return .none
    }

    /// Tracks when playback stopped, and re-checks the closed notch once the 5 seconds are over.
    private func notePlaybackChange() {
        guard let track = state.media.track else {
            pausedAt = nil
            idleGraceTask?.cancel()
            return
        }
        if track.isPlaying {
            pausedAt = nil
            idleGraceTask?.cancel()
        } else if pausedAt == nil {
            pausedAt = Date()
            idleGraceTask?.cancel()
            idleGraceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_100_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshIdle()
            }
        }
    }

    /// The page the notch opens on: the tray when it has files, otherwise by Idle Activity.
    private func defaultTab() -> NotchTab {
        if Preferences.trayFirst && !state.tray.items.isEmpty { return .tray }
        let calendarEnabled = Preferences.showDate || Preferences.showCalendar
        switch effectiveIdleConfig() {
        case .calendar: return calendarEnabled ? .calendar : .player
        case .duo: return .duo
        default: return .player
        }
    }

    private func refreshIdle() {
        let mode = resolveIdleMode()
        let badge = wantsUpdateBadge(for: mode)
        guard mode != state.idleMode || badge != state.updateBadge else { return }
        applyClosedChange(targetSlot: state.slot(idle: mode, live: state.liveActivity, badge: badge)) {
            state.setIdle(mode, updateBadge: badge)
        }
    }

    /// Width added at each side of the closed notch for a given idle mode and live activity.
    private func slot(idle: IdleMode, live: LiveActivity?) -> CGFloat {
        state.slot(idle: idle, live: live)
    }

    // MARK: - Update notice (v553)

    /// The update symbol shows while a new version is ready and the closed notch is idle: nothing playing, no blur cover, no
    /// face scan. (Other things on the notch, like a volume bar, simply draw over it while they last.)
    private func wantsUpdateBadge(for mode: IdleMode) -> Bool {
        mode == .none && !coverHidden && !faceScanBusy && UpdateManager.shared.availableVersion != nil
    }

    /// Both notches follow the update state (the symbol); the main notch also offers the card.
    private func startUpdateWatch() {
        looseObservers.append(NotificationCenter.default.addObserver(forName: .indraUpdateStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutDown else { return }
                self.refreshIdle()
                self.offerUpdateNotice()
            }
        })
        guard !isIsland else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.offerUpdateNotice() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// "Update available (version N)" below the closed notch for 4 seconds, at most twice a day (UpdateNoticeLog). It waits while
    /// anything else is on the notch (the check comes round again every minute); the external island shows it too (showLive).
    private func offerUpdateNotice() {
        guard !isIsland, !isShutDown, let version = UpdateManager.shared.availableVersion,
              UpdateNoticeLog.isDue(version: version) else { return }
        guard !coverHidden, !faceScanBusy, !introRunning, !openPending,
              !state.isExpanded, state.liveActivity == nil, state.expandedStrip == nil,
              !state.isDropTargeted, !state.isEditing,
              !LockMonitor.isScreenLockedCached() else { return }
        // With nothing beside the notch to hold the card's row, the update symbol is that row.
        guard state.updateBadge || state.idleMode != .none else { return }
        UpdateNoticeLog.record(version: version)
        showLive(.update(version: version), duration: 4)
    }

    /// Shows a battery / lock / volume / brightness activity (only while the notch is closed).
    private func showLive(_ activity: LiveActivity, duration: Double = 3) {
        // v429: the island shows the same activities (its own song cards come from its own song-change handling).
        if let island {
            if case .song = activity {} else { island.showLive(activity, duration: duration) }
        }
        // v560: no volume / brightness display while the face scan animation is on screen (see handleSensory).
        if case .hud = activity, faceScanBusy, !isIsland { return }
        // v477: nothing shows at this notch while a blur cover is up on its screen.
        // v555: except the volume / brightness card, once the face scan animation has collapsed (while it plays, the bar is on
        // the left edge instead, see handleSensory).
        if coverHidden {
            guard !isIsland, !faceScanBusy, case .hud = activity else { return }
            coverPanelTask?.cancel()
            panel.alphaValue = 1
        }
        // With the notch open, the card hangs below it instead (see showStrip).
        if state.isExpanded {
            showStrip(activity, duration: duration)
            return
        }
        IndraLog.crumb("Notch showed \(activity.logName)")
        var downline = false
        if case .hud = activity, state.sensoryLayout == "downline" { downline = true }
        if case .task = activity { downline = true }
        // The song-change card hangs below the notch, under its artwork and visualizer.
        if case .song = activity { downline = true }
        if case .update = activity { downline = true }
        // A connected device with a name gets its name in a strip below the notch (previews and unnamed devices do not).
        if case .bluetooth(let name, _, _) = activity, !name.isEmpty { downline = true }
        // v556: the inline volume / brightness bar widens the notch. The window grows first and the notch starts to widen one
        // moment later, when the window has its new size: the first frames of the widening used to be drawn into the old, narrower
        // window and showed the bar cut off half way. (Nothing waits: a short task starts the rest.)
        if !downline, case .hud = activity, !openPending {
            let wanted = frame(for: closedWindowSize(slot: slot(idle: state.idleMode, live: activity), downline: false))
            if wanted.width > panel.frame.width + 0.5 {
                fitTask?.cancel()
                panel.setFrame(wanted, display: false)
                panel.contentView?.layoutSubtreeIfNeeded()
                liveGrowTask?.cancel()
                liveGrowTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    guard !Task.isCancelled, let self, !self.isShutDown else { return }
                    if self.state.isExpanded {
                        self.showStrip(activity, duration: duration)
                    } else {
                        self.startLive(activity, duration: duration, downline: false)
                    }
                }
                return
            }
        }
        startLive(activity, duration: duration, downline: downline)
    }

    /// v563: about a second after the inline volume / brightness bar began to widen the notch (its spring has long finished), the
    /// widening is checked: the window must be as wide as the notch body, and the body is put at its final width without
    /// animation. The bar was seen stuck half way along its slider, with the black body not reaching its full width; the body is
    /// an animated size, and an animation that is stopped half way (a window change or the slide of the desktops during it) never
    /// ends by itself. A width that is already right does not move.
    private func verifyInlineHUDWidth() {
        guard !isShutDown, !state.isExpanded, !openPending, !state.closedShrinking,
              case .hud? = state.liveActivity, !state.isDownlineHUD else { return }
        let wanted = closedFrame
        if panel.frame.width < wanted.width - 0.5 {
            Trace.log("HUDWIDTH: the window was \(Int(panel.frame.width)) wide but the notch needs \(Int(wanted.width)): widened")
            fitTask?.cancel()
            panel.setFrame(wanted, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        state.nudgeClosed()
    }

    private func startLive(_ activity: LiveActivity, duration: TimeInterval, downline: Bool) {
        liveGrowTask?.cancel()
        if case .hud = activity, !downline {
            hudVerifyTask?.cancel()
            hudVerifyTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled, let self else { return }
                self.verifyInlineHUDWidth()
            }
        }
        applyClosedChange(targetSlot: slot(idle: state.idleMode, live: activity), downline: downline) {
            state.setLive(activity)
        }
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.applyClosedChange(targetSlot: self.slot(idle: self.state.idleMode, live: nil)) {
                self.state.setLive(nil)
            }
            if self.coverHidden { self.hideCoverPanelSoon() }
        }
    }

    // MARK: - Keep warm

    private func startKeepWarm() {
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.keepWarm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        warmTimer = timer
    }

    /// While the notch is closed in Duo, the day's events are read every half minute. After a long rest the first
    /// read from the calendar store is slow; doing it here, out of sight, keeps it out of the opening animation.
    private func keepWarm() {
        guard !state.isExpanded, effectiveIdleConfig() == .duo else { return }
        state.calendar.refresh()
    }

    // MARK: - Song change card

    /// A different song started: when the closed notch has nothing else to show, its title and artist appear in a
    /// card below it for a few seconds. It waits a moment first, because players often announce the title and the
    /// artist in two steps, and shows whatever is playing by then.
    private func songChanged() {
        island?.songChanged()
        guard Preferences.songChangeCard else { return }
        songChangeTask?.cancel()
        // The notch is open: the card has no room now. It appears as soon as the notch has closed.
        if state.isExpanded {
            songCardPendingSince = Date()
            return
        }
        songCardPendingSince = nil
        // Shown at once with whatever is known right now. A player that announces the title and the artist in two
        // steps simply triggers this again, and the card swaps to the newer text in place. Two quick skips in a row
        // always end on the latest song.
        if showSongCard() { return }
        // Playback may not have been reported as started yet: look once more very shortly.
        songChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            _ = self?.showSongCard()
        }
    }

    /// The notch has just closed: a song change that happened while it was open gets its card now, once the closing
    /// animation has settled (and only if it is not long ago).
    private func showPendingSongCard() {
        guard let since = songCardPendingSince else { return }
        songCardPendingSince = nil
        guard Date().timeIntervalSince(since) < 120 else { return }
        songChangeTask?.cancel()
        songChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.showSongCard() {
                // Playback may not have been reported yet: one more look very shortly.
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                _ = self.showSongCard()
            }
        }
    }

    /// Returns false only when the card could not be shown because the song is not reported as playing yet.
    @discardableResult
    private func showSongCard() -> Bool {
        guard Preferences.songChangeCard,
              !state.isExpanded,
              state.liveActivity == nil || state.isSongDownline,   // a newer song replaces the card
              state.expandedStrip == nil,
              !state.isDropTargeted,
              let track = state.media.track else { return true }
        guard track.isPlaying else { return false }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        showLive(.song(title: title, artist: artist), duration: 3.6)
        return true
    }

    /// Volume / brightness, Bluetooth and battery while the notch is OPEN (any page, Duo too): the notch body grows
    /// downward and the card appears in that space. Never while files are being dragged into the notch.
    private func showStrip(_ activity: LiveActivity, duration: Double) {
        guard !coverHidden, !state.isDropTargeted, !openedByDrag else { return }
        let height = NotchState.stripHeight(for: activity, island: isIsland)
        guard height > 0 else { return }
        IndraLog.crumb("Notch showed \(activity.logName) below the open notch")
        stripTask?.cancel()
        fitTask?.cancel()
        // The window grows first, so the body never grows outside it.
        stripWindowExtra = max(height, stripWindowExtra)
        panel.setFrame(targetFrame, display: true)
        state.setStrip(activity)
        stripTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state.setStrip(nil)
            // The window shrinks only after the body has.
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self.stripWindowExtra = 0
            if self.state.isExpanded { self.panel.setFrame(self.targetFrame, display: true) }
        }
    }

    /// Widen the window before the body grows, shrink it only after the body has shrunk.
    private func applyClosedChange(targetSlot: CGFloat, downline: Bool = false, _ change: () -> Void) {
        // v366: also while an opening is pending (the window is already at its open size, the notch has not started to
        // grow yet). A live activity or idle change landing in that gap used to resize the window back to the
        // closed size under the opening notch: the opening then ran in a window that changed size during it.
        if state.isExpanded || openPending {
            // The window is refitted when the notch closes.
            change()
            return
        }
        let widening = targetSlot > state.closedSlot
        // While the downline overlay is leaving, the big window stays until the shrink finishes.
        let leavingDownline = state.isDownlineHUD && !downline
        // v556: also when the window is narrower than the closed notch will be, whatever the state says. The state can already
        // hold the wide slot while the window has not grown (a shrink-fit that ran in between, a repeated key), and the inline
        // volume bar was then cut off at the window's old edge, about half way along the slider.
        let tooNarrow = frame(for: closedWindowSize(slot: targetSlot, downline: downline)).width > panel.frame.width + 0.5
        let enlarges = downline || ((widening || tooNarrow) && !leavingDownline)
        if enlarges {
            // v420: not display: true. That redraws the whole window synchronously right here, on the main thread, and
            // while the desktops are sliding that wait is what made a volume / brightness pop-up lag. The new area is
            // transparent until the notch grows into it, so nothing is lost by letting it draw with the next frame.
            // v429: only when the size really changes (a held volume key repeats this many times a second).
            let wanted = frame(for: closedWindowSize(slot: targetSlot, downline: downline))
            // v479: a shrink-fit that is still waiting must not touch the window under the notch that is about to grow.
            fitTask?.cancel()
            if panel.frame != wanted {
                panel.setFrame(wanted, display: false)
                // Lay the content out for the new size right now (no drawing). After a long rest the hosting view
                // otherwise kept its old, smaller size for the first frames, and the widening bar and its percentage
                // were clipped at the old edge.
                panel.contentView?.layoutSubtreeIfNeeded()
            }
        }
        change()
        if !enlarges { scheduleFit() }
    }

    // MARK: - To-do and reminder pop-ups

    /// To-dos and reminders popping up in the notch, as chosen in To Do settings. They wait while anything else is
    /// on screen (volume bar, Bluetooth card, files being dropped) and try again a few seconds later.
    private func startTaskPopups() {
        let scheduler = TaskPopupScheduler { [weak self] activity, seconds, force in
            guard let self else { return false }
            if !force, self.state.liveActivity != nil || self.state.expandedStrip != nil
                || self.state.isDropTargeted || self.state.isEditing {
                return false
            }
            self.showLive(activity, duration: seconds)
            return true
        }
        scheduler.start()
        taskPopups = scheduler
    }

    // MARK: - Intro

    /// The first time Indra is ever opened (and any time from General > Behavior > Intro animation > Show) the notch opens
    /// in the shape of the normal notch and plays the intro video with the thunder, then closes.
    private func startIntro() {
        state.onIntroEnded = { [weak self] in self?.introVideoEnded() }
        looseObservers.append(NotificationCenter.default.addObserver(forName: .indraWelcomePreview, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playIntro() }
        })
        // v540: plays on the first launch and again after every update (a new build number), so the key holds the build
        // it last played for (the old yes/no key "indraWelcomePlayed" is no longer read).
        let key = "indraWelcomePlayedBuild"
        let build = IndraLog.appBuild
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        // First launch: tried again a few times if something (a blur cover, a drag) is in the way at that moment.
        introStartTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.playIntro() {
                    UserDefaults.standard.set(build, forKey: key)
                    return
                }
            }
        }
    }

    @discardableResult
    private func playIntro() -> Bool {
        guard !isIsland, !coverHidden, !state.isExpanded, !openPending, !introRunning, !state.isDropTargeted else { return false }
        collapseTask?.cancel()
        introResetTask?.cancel()
        introRunning = true
        state.setIntro(true)
        expand(tab: .player)
        guard state.isExpanded || openPending else {
            introRunning = false
            state.setIntro(false)
            return false
        }
        IndraLog.crumb("Intro animation started")
        Trace.log("Intro: notch opening")
        // Whatever happens to the video, the notch is closed again after a few seconds.
        introTask?.cancel()
        introTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishIntro()
        }
        return true
    }

    /// The video melts into "Indra / CREATED BY SHADOW" (about 2.7 s), which stays a moment, then the notch closes.
    private func introVideoEnded() {
        guard introRunning else { return }
        introTask?.cancel()
        introTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishIntro()
        }
    }

    private func finishIntro() {
        guard introRunning else { return }
        collapse(force: true)
        // Whatever kept the notch from closing, the intro is over: the usual rules take over again.
        introClosed()
    }

    /// The intro is over (or the notch was closed under it): its thunder stops, and its size is given back once the closing
    /// animation has run.
    private func introClosed() {
        guard introRunning else { return }
        introRunning = false
        introTask?.cancel()
        introTask = nil
        IntroSound.stop()
        Trace.log("Intro: closed")
        introResetTask?.cancel()
        introResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self else { return }
            self.state.setIntro(false)
        }
    }

    // MARK: - Bluetooth

    /// Bluetooth devices connecting or disconnecting show over whatever the closed notch displays.
    private func startBluetooth() {
        let monitor = BluetoothMonitor { [weak self] kind, name, connected in
            self?.bluetoothQuietUntil = Date().addingTimeInterval(9)
            // On the lock screen the notch is not drawn: the lock screen window shows the same card.
            NotificationCenter.default.post(name: .indraLockBluetooth, object: nil,
                                            userInfo: ["kind": kind, "name": name, "connected": connected])
            self?.showLive(.bluetooth(name: name, kind: kind, connected: connected), duration: 6.2)
        }
        monitor.start()
        bluetooth = monitor
        trackObserver(forName: .indraBluetoothPreview, object: nil, queue: .main) { [weak self] note in
            let kind = BluetoothKind(rawValue: (note.userInfo?["kind"] as? String) ?? "") ?? .earbuds
            let connected = (note.userInfo?["connected"] as? Bool) ?? true
            Task { @MainActor [weak self] in
                self?.bluetoothQuietUntil = Date().addingTimeInterval(9)
                self?.showLive(.bluetooth(name: "", kind: kind, connected: connected), duration: 6.2)
            }
        }
    }

    // MARK: - Volume / brightness overlays

    /// Replaces the macOS pop-up: starts catching the volume / brightness keys when allowed.
    private func syncKeyInterceptor() {
        let wanted = Preferences.sensoryVolume || Preferences.sensoryBrightness || Preferences.sensoryKeyboard
        if wanted, !SensoryDiagnostics.isSandboxed {
            // v501: the swallow decision is made on the key tap's own thread, so it must come from plain values captured
            // here on the main thread (never from a system call made inside the tap).
            let volumeOn = Preferences.sensoryVolume && sensory != nil
            // Whether brightness / backlight can be changed at all is asked once (each ask is a round trip to a system daemon),
            // not on every preference write.
            if Preferences.sensoryBrightness, canAdjustBrightnessCache == nil { canAdjustBrightnessCache = sensory?.canAdjustBrightness ?? false }
            if Preferences.sensoryKeyboard, canAdjustKeyboardCache == nil { canAdjustKeyboardCache = sensory?.canAdjustKeyboard ?? false }
            let brightnessOn = Preferences.sensoryBrightness && (canAdjustBrightnessCache ?? false)
            let keyboardOn = Preferences.sensoryKeyboard && (canAdjustKeyboardCache ?? false)
            keyInterceptor.shouldSwallow = { key in
                switch key {
                case .soundUp, .soundDown, .mute: return volumeOn
                case .brightnessUp, .brightnessDown: return brightnessOn
                case .keyboardUp, .keyboardDown: return keyboardOn
                }
            }
            keyInterceptor.onKey = { [weak self] key, flags in
                self?.handleSystemKey(key, flags: flags) ?? false
            }
            keyInterceptor.start()
        } else {
            keyInterceptor.stop()
        }
    }

    /// Returns true when Indra handled the key (macOS then shows no pop-up of its own).
    private func handleSystemKey(_ key: SystemKey, flags: NSEvent.ModifierFlags) -> Bool {
        if LockMonitor.isScreenLockedCached() { Trace.log("LOCKHUD: key \(key) caught on the lock screen: Indra's overlay only, no macOS pop-up") }
        // Shift + Option = fine steps, like macOS.
        let step: Float = (flags.contains(.shift) && flags.contains(.option)) ? 1.0 / 64.0 : 1.0 / 16.0
        switch key {
        case .soundUp, .soundDown, .mute:
            guard Preferences.sensoryVolume, let sensory else { return false }
            if key == .mute {
                sensory.toggleMute()
            } else {
                sensory.adjustVolume(by: key == .soundUp ? step : -step)
            }
            return true
        case .brightnessUp, .brightnessDown:
            guard Preferences.sensoryBrightness, let sensory, sensory.canAdjustBrightness else { return false }
            sensory.adjustBrightness(by: key == .brightnessUp ? step : -step)
            return true
        case .keyboardUp, .keyboardDown:
            guard Preferences.sensoryKeyboard, let sensory, sensory.canAdjustKeyboard else { return false }
            sensory.adjustKeyboard(by: key == .keyboardUp ? step : -step)
            return true
        }
    }

    private func handleSensory(_ event: SensoryEvent) {
        guard Date() >= bluetoothQuietUntil else { return }
        switch event.kind {
        case .volume: guard Preferences.sensoryVolume else { return }
        case .brightness: guard Preferences.sensoryBrightness else { return }
        case .keyboard: guard Preferences.sensoryKeyboard else { return }
        }
        // On the lock screen the HUD is drawn by the lock screen window (default, always on).
        NotificationCenter.default.post(name: .indraSensoryEvent, object: nil, userInfo: ["event": event])
        // v555: on an App Lock blur screen the notch belongs to the face scan animation while it plays: the volume / brightness
        // bar stays on the left edge until that animation has collapsed, and the normal display follows then.
        // v560: no volume / brightness display of any kind appears while the face scan animation is on screen, up to the last
        // moment of its collapse (that is what `faceScanBusy` covers). Whether the blur cover is still up does not matter: on a
        // successful scan the cover goes first and the notch is still collapsing. Without a blur screen nothing is shown at all
        // meanwhile; the last value is shown normally once the animation is gone.
        if !isIsland, faceScanBusy || edgeHUDEvent != nil {
            holdEdgeHUD(event, showBar: isCoverUp || edgeHUDShown)
            return
        }
        showSensory(event)
    }

    private func showSensory(_ event: SensoryEvent) {
        if Preferences.sensoryStyle == "apple" {
            // The album accent colour is for the notch-style overlay only.
            appleHUD.show(event, on: currentScreen, accent: nil, duration: Preferences.sensoryDuration)
        } else {
            showLive(.hud(kind: event.kind, value: event.value, muted: event.muted),
                     duration: Preferences.sensoryDuration)
        }
    }

    // MARK: - Volume / brightness while the face scan animation plays over an App Lock blur screen (v555)

    /// An App Lock blur cover is up on this notch's screen.
    private var isCoverUp: Bool {
        coverHidden || AppLockController.shared.isCoverShown(on: currentScreen)
    }

    /// Remembers the last volume / brightness value received while the face scan animation is on screen. On a blur screen it also
    /// shows (or updates) the bar on the left edge and keeps it there until the animation has collapsed. A small in-process check,
    /// four times a second and only while this is held, ends it if the "collapsed" message were ever missed.
    private func holdEdgeHUD(_ event: SensoryEvent, showBar: Bool) {
        edgeHUDFollowTask?.cancel()
        edgeHUDFollowTask = nil
        edgeHUDEvent = event
        if showBar {
            if edgeHUD == nil { edgeHUD = AppleHUDController(edge: .left) }
            edgeHUD?.show(event, on: currentScreen, accent: nil, duration: 3_600)
            edgeHUDShown = true
        }
        guard edgeHUDWatch == nil else { return }
        edgeHUDWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.faceScanBusy {
                    self.releaseEdgeHUD()
                    return
                }
            }
        }
    }

    /// The bar leaves the left edge and, a moment later (the notch has settled), the normal display shows the last value.
    private func releaseEdgeHUD() {
        edgeHUDWatch?.cancel()
        edgeHUDWatch = nil
        guard let event = edgeHUDEvent else { return }
        edgeHUDEvent = nil
        if edgeHUDShown {
            edgeHUDShown = false
            edgeHUD?.hide()
        }
        edgeHUDFollowTask?.cancel()
        edgeHUDFollowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self, !self.faceScanBusy, !self.isShutDown else { return }
            self.showSensory(event)
        }
    }

    /// v560: a volume / brightness display that is already on screen when the face scan animation starts steps aside at once
    /// (the card at the notch, over a blur screen or not, and the bar of the Apple style on the right edge).
    private func endCoverHUD() {
        appleHUD.hide()
        guard case .hud? = state.liveActivity else { return }
        liveTask?.cancel()
        applyClosedChange(targetSlot: slot(idle: state.idleMode, live: nil)) {
            state.setLive(nil)
        }
        if coverHidden { hideCoverPanelSoon() }
    }

    private func hideCoverPanelSoon() {
        coverPanelTask?.cancel()
        coverPanelTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.coverHidden, self.state.liveActivity == nil else { return }
            self.panel.alphaValue = 0
        }
    }

    private func observeDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Any write to UserDefaults posts this (tray, to-do, Spotify history, system keys),
            // often in bursts. Run the syncs once, shortly after the burst ends.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.defaultsTask?.cancel()
                self.defaultsTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.refreshIdle()
                    self.applyWindowPrefs()
                    if !self.isIsland {
                        self.syncAutoIdentify()
                        self.syncAudio()
                    }
                    self.syncNotchSize()
                    self.syncHostScreen()
                    if !self.isIsland {
                        self.sensory?.refreshSettings()
                        self.syncKeyInterceptor()
                    }
                }
            }
        }
    }

    /// Starts / stops automatic background song identification when the setting changes.
    /// Applies the notch width / height chosen in Settings.
    private func syncNotchSize() {
        let size = (Preferences.notchWidth, Preferences.notchHeight)
        if let applied = appliedNotchSize, applied == size { return }
        appliedNotchSize = size
        state.metrics = NotchMetrics.make(for: currentScreen, island: isIsland ? true : nil)
        panel.setFrame(targetFrame, display: true)
        focusEdge.reposition(on: currentScreen)
    }

    /// v394: "External monitor" was switched on or off in Settings: the notch moves to the external monitor (as a
    /// floating island) or back to the MacBook's own notch. Does nothing while nothing changed.
    private func syncHostScreen() {
        if !isIsland { syncIsland() }
        guard !lookMorphing else { return }
        let wanted = resolveScreen()
        if isIsland, wanted == nil { return }
        let wantsIsland = isIsland || NotchMetrics.usesIsland(on: wanted)
        let wantsNotchLook = wantsIsland && Preferences.islandNotchLook
        let sameDisplay = NotchMetrics.displayID(wanted) == NotchMetrics.displayID(currentScreen)
        // v439: only the look changed (island <-> notch) on the same monitor: that is a morph, not a jump.
        if wantsIsland, state.metrics.island, sameDisplay, wantsNotchLook != state.metrics.notchLook {
            morphLook(on: wanted)
            return
        }
        guard wantsIsland != state.metrics.island
                || wantsNotchLook != state.metrics.notchLook
                || !sameDisplay else { return }
        applyHostScreen(wanted)
    }

    /// Swaps the geometry for the screen (size, position, the focus line). No animation: whatever is on screen is not
    /// moved in view; `morphLook` hides the notch around it.
    private func applyHostScreen(_ wanted: NSScreen?) {
        currentScreen = wanted
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.metrics = NotchMetrics.make(for: wanted, island: isIsland ? true : nil)
        }
        panel.setFrame(targetFrame, display: true)
        focusEdge.reposition(on: wanted)
    }

    /// v439: the external notch switching between the island (floating pill, 8 pt below the edge) and the MacBook-notch look
    /// (flush with the edge, another size, another outline). Before, the window, the size and the outline all changed in
    /// one frame, and the old animation state of the body was then dragged to the new size. Now the old look shrinks into
    /// the top edge and fades (0.17 s), the geometry is swapped while nothing can be seen and the animation state is
    /// reset, and the new look grows out of the top edge with a soft spring. When the notch is open or showing a card
    /// there is nothing quiet to morph, so it switches at once as before.
    private func morphLook(on wanted: NSScreen?) {
        guard !state.isExpanded, !openPending, state.liveActivity == nil, state.expandedStrip == nil,
              !state.isDropTargeted, panel.isVisible else {
            applyHostScreen(wanted)
            return
        }
        lookMorphing = true
        lookTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.state.setLookHidden(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.applyHostScreen(wanted)
            // Whatever the size change started while it was invisible is ended, so the new look appears at its real size.
            self.state.settle()
            try? await Task.sleep(nanoseconds: 70_000_000)
            self.state.setLookHidden(false)
            // The spring needs about half a second; until then another change of the look waits.
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.lookMorphing = false
            self.syncHostScreen()
        }
    }

    // MARK: - Typing in the notch (to-do list)

    /// A click anywhere outside the notch ends typing, so the notch can close again.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                if self.state.isEditing {
                    self.panel.makeFirstResponder(nil)
                    self.state.setEditing(false)
                }
                // A click anywhere else closes the notch too (the pointer is not on it).
                if self.state.isExpanded, !self.menuIsOpen, !self.state.isDropTargeted,
                   !self.bodyRect(self.openBodySize, inflate: 24, sides: true).contains(NSEvent.mouseLocation) {
                    self.collapse()
                }
            }
        }
    }

    // MARK: - Stuck-open guard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.panel { self.lastKeyAt = Date() }
            }
            return event
        }
    }

    /// Runs only while the notch is open and closes it whenever the pointer is away, whatever page it is on and
    /// whichever event was missed (window resized under the pointer, lost focus callback, stuck flags, ...).
    /// It looks only at where the pointer is, so nothing else can keep the notch open.
    private func startOpenWatchdog() {
        openWatchdog?.cancel()
        openWatchdog = Task { @MainActor [weak self] in
            var awaySince: Date?
            var dropIdleSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled, self.state.isExpanded else { return }
                let now = Date()
                let pressed = NSEvent.pressedMouseButtons != 0
                if !pressed { self.pressStartedInside = false }

                // Flags that can stay set for ever.
                if self.menuIsOpen, now.timeIntervalSince(self.menuOpenedAt) > 120 { self.menuIsOpen = false }
                if self.previewPinned, now.timeIntervalSince(self.previewPinnedAt) > 60 { self.previewPinned = false }

                // A file drag that ended without any window noticing.
                if self.state.isDropTargeted {
                    awaySince = nil
                    if pressed {
                        dropIdleSince = nil
                    } else {
                        dropIdleSince = dropIdleSince ?? now
                        if now.timeIntervalSince(dropIdleSince ?? now) > 2.5 {
                            dropIdleSince = nil
                            self.dragExited(force: true)
                        }
                    }
                    continue
                }
                dropIdleSince = nil

                // v530: the intro closes itself.
                if self.introRunning { awaySince = nil; continue }
                let inside = self.bodyRect(self.openBodySize, inflate: 24, sides: true).contains(NSEvent.mouseLocation)
                if inside || self.previewPinned || self.menuIsOpen || (pressed && self.pressStartedInside) {
                    awaySince = nil
                    continue
                }
                awaySince = awaySince ?? now
                // Typing (to-do) keeps the notch open only while keys are really being pressed.
                if self.state.isEditing, now.timeIntervalSince(self.lastKeyAt) < 2.5 { continue }
                if now.timeIntervalSince(awaySince ?? now) > 0.8 {
                    awaySince = nil
                    self.panel.makeFirstResponder(nil)
                    self.state.setEditing(false)
                    self.collapse()
                }
            }
        }
    }

    /// Remembers whether the current mouse press began on the notch.
    private func installPressMonitors() {
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown {
                    self.dragPasteboardCount = DragPasteboard.changeCount()
                }
                self.pressStartedInside = event.type == .leftMouseDown && event.window === self.panel
            }
            return event
        }
        pressUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressStartedInside = false }
        }
    }

    private func editingEnded() {
        // Close as usual once typing is over and the pointer is no longer on the notch.
        if !panel.frame.contains(NSEvent.mouseLocation) {
            pointerExited()
        }
    }

    /// Real audio levels are only measured while music plays and a visualizer is chosen.
    private func syncAudio() {
        // v433: the island may have its own visualizer style, so the levels are measured when either one needs them.
        let styleOn = Preferences.visualizerStyle != "none" || (island != nil && Preferences.visualizerStyle(island: true) != "none")
        let wanted = styleOn && state.media.track?.isPlaying == true
        state.audio.setActive(wanted)
    }

    private func syncAutoIdentify() {
        let on = Preferences.autoIdentify
        guard autoIdentifyApplied != on else { return }
        autoIdentifyApplied = on
        state.identifier.setAutomatic(on)
    }

    /// Moves the notch windows into / out of the private top-level Space (see StickySpace).
    private func syncStickySpace() {
        guard let stickySpace else { return }
        // v498: never move windows between Spaces while a mouse button is down (a drag or a click is in flight): the
        // window server can be left waiting on the drag. It is simply done a moment after the button is released.
        if NSEvent.pressedMouseButtons != 0 {
            stickyRetry?.cancel()
            stickyRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.syncStickySpace()
            }
            return
        }
        // v546: nor while a file is being handed to Blip / AirDrop (the other app comes to the front in that moment): later.
        if FileSharing.isHandingOff {
            stickyRetry?.cancel()
            stickyRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.syncStickySpace()
            }
            return
        }
        let wanted = Preferences.stickyDesktops && !Preferences.hideInFullscreen && !stickySuspended
        guard stickyApplied != wanted else { return }
        stickyApplied = wanted
        let windows: [NSWindow] = [panel, focusEdge.panel]
        if wanted {
            stickySpace.add(windows)
            // Leave the desktops completely, otherwise the notch slides with the wallpaper.
            if stickySpace.makeExclusive(windows) {
                stickyExclusive = true
                applyCollectionBehavior()
                if !stickySpace.makeExclusive(windows) {
                    stickyExclusive = false
                    applyCollectionBehavior()
                }
            }
        } else {
            stickySpace.remove(windows)
            stickyExclusive = false
            applyCollectionBehavior()
        }
    }

    private func applyCollectionBehavior() {
        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if !stickyExclusive { behavior.insert(.canJoinAllSpaces) }
        if !Preferences.hideInFullscreen { behavior.insert(.fullScreenAuxiliary) }
        for window in [panel as NSWindow, focusEdge.panel] where window.collectionBehavior != behavior {
            window.collectionBehavior = behavior
        }
    }

    /// Hide in Fullscreen / Hide from Screen Capture.
    private func applyWindowPrefs() {
        let sharing: NSWindow.SharingType = Preferences.hideFromCapture ? .none : .readOnly
        applyCollectionBehavior()
        for window in [panel as NSWindow, focusEdge.panel] where window.sharingType != sharing {
            window.sharingType = sharing
        }
        syncStickySpace()
    }

    // MARK: - Desktops (Spaces)

    /// The windows already join every Space; this just makes sure they are front-most after a switch.
    private func observeSpaceChanges() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // v429: no forced front-ordering and no synchronous redraw here any more. They ran (three times) in the middle
                // of the desktop slide, which is when the window server is busiest, and a volume / brightness card showing at
                // that moment stalled and then jumped. The window lives in its own Space and stays on top by itself; it is only
                // brought back if it somehow is not on screen.
                if !self.panel.isVisible { self.panel.orderFrontRegardless() }
                // v420: a pop-up that ended while the desktops were sliding could leave the window at the pop-up's big size
                // (its refit was swallowed by the transition). With the notch closed and nothing showing, refit it now.
                if !self.state.isExpanded, !self.openPending, self.state.liveActivity == nil { self.scheduleFit() }
                // Once the desktops have stopped sliding, an animation they froze is ended for good.
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.state.settle()
            }
        }
        SpaceChangeGuard.register(panel)
        SpaceChangeGuard.register(focusEdge.panel)
    }

    // MARK: - Screens

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenParametersChanged()
            }
        }
    }

    private func screenParametersChanged() {
        if !isIsland { syncIsland() }
        guard let screen = resolveScreen() else { return }
        currentScreen = screen
        state.metrics = NotchMetrics.make(for: currentScreen, island: isIsland ? true : nil)
        panel.setFrame(targetFrame, display: true)
        // v366: the focus-session line under the notch lives on the same screen; after a display was plugged in or
        // removed, a resolution change or a wake it stayed at the old screen's position (syncNotchSize did this, this
        // path did not).
        focusEdge.reposition(on: currentScreen)
    }

    // MARK: - Swipe gestures

    private func installSwipeMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScroll(event)
            }
            return event
        }
    }

    /// Two-finger swipes over the open notch.
    ///
    /// Player: left = next track, right = previous track.
    /// Calendar: right = to-do, left = weather. From those pages the opposite swipe comes back.
    /// Duo (the calendar is already on it): over the player half left / right change the song (as on the player
    /// page); swipe down opens the Zen space (focus session / clipboard manager). The Zen space is the hub:
    /// left = weather, right = to-do, down = back to player + calendar, up = close the notch. From the weather a
    /// swipe right comes back to the Zen space, from the to-do list a swipe left does. Weather and to-do scroll
    /// their own lists vertically. The clipboard page's row of cards scrolls sideways once it holds more than
    /// fit (then sideways swipes belong to the cards), so up and down work there as on any Zen page. The camera is opened with the header button, as in the normal notch; on its
    /// page (Duo size) a swipe down goes back and a swipe up closes the notch.
    /// Weather / to-do: vertical swipes scroll their lists.
    /// Over the calendar half of Duo a swipe never closes the notch (swipe up does nothing there).
    /// Player / calendar: swipe down = next page (player <-> calendar loop), swipe up = close the notch.
    private func handleScroll(_ event: NSEvent) {
        guard event.window === panel,
              state.isExpanded,
              !introRunning,
              !state.isDropTargeted,
              event.hasPreciseScrollingDeltas else { return }
        if event.phase.contains(.began) {
            swipeAccum = 0
            swipeAccumY = 0
            swipeSideways = 0
            swipeFired = false
        }
        guard event.momentumPhase.isEmpty, !swipeFired else { return }

        // Normalise to physical finger direction: x > 0 = right, y > 0 = down.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = sign * event.scrollingDeltaX
        let dy = sign * event.scrollingDeltaY
        swipeSideways += abs(dx)

        if state.showsMirror {
            // Duo's camera page: down goes back to the player + calendar page, up closes the notch.
            guard state.tab == .duo, abs(dy) >= abs(dx) else { return }
            swipeAccumY += dy
            if swipeAccumY > 40 {
                swipeFired = true
                closeMirror()
            } else if swipeAccumY < -40 {
                swipeFired = true
                if state.isExpanded { Haptics.hf1() }   // closed by a swipe
                collapse()
            }
            return
        }

        // Pages with lists (calendar, to-do, weather, Zen) need a clearly sideways swipe to change page, so a
        // slightly diagonal swipe on a list only scrolls it. The player and Duo's player half stay as they were.
        let sidewaysBias: CGFloat = (state.tab == .player || state.tab == .duo) ? 1 : 1.6
        if abs(dx) > abs(dy) * sidewaysBias {
            // The Duo page: over the player half swipes change the song; over the calendar half they scroll
            // the day strip. (Weather and to-do are reached from the Zen space there.)
            guard state.tab != .tray else { return }
            // v443: the month calendar opened from Duo has no pages beside it.
            if state.tab == .calendar, state.duoLayout { return }
            // The tray on Duo's Zen page scrolls sideways itself once it holds more files than fit.
            if state.tab == .zen, state.trayInZen, state.tray.items.count > 3 { return }
            // The same for the clipboard's row of cards.
            if state.tab == .zen, state.zenMode == "clipboard", state.clipboard.overflows { return }
            if state.tab == .duo, !isOverDuoPlayer() { return }
            swipeAccum += dx
            guard abs(swipeAccum) > 60 else { return }
            swipeFired = true
            horizontalSwipe(toRight: swipeAccum > 0)
        } else {
            // Weather, to-do and the tray scroll vertically on their own.
            guard state.tab == .player || state.tab == .duo || state.tab == .calendar || state.tab == .zen else { return }
            // Duo's calendar half: no swipe ever closes the notch from there, however long or often you swipe. The
            // day strip and the event list scroll on it, and the small up-and-down wobble of a sideways swipe used
            // to add up to an "up" swipe. Only a clearly downward swipe (not a mostly sideways one) goes on to Zen.
            if state.tab == .duo, state.duoLayout, !isOverDuoPlayer() {
                swipeAccumY += dy
                guard swipeAccumY > 40, swipeAccumY > swipeSideways else { return }
                swipeFired = true
                Haptics.hf1()
                changePage(to: .zen, move: CGSize(width: 0, height: 1))
                return
            }
            swipeAccumY += dy
            if state.tab == .calendar, state.duoLayout {
                // v443: the month calendar opened from Duo: a vertical swipe goes back to the Duo page (it never closes the notch).
                guard abs(swipeAccumY) > 40 else { return }
                swipeFired = true
                Haptics.hf1()
                leaveDuoCalendar(to: .duo)
                return
            }
            if swipeAccumY > 40 {
                swipeFired = true
                if state.tab == .zen {
                    // Back to the player + calendar page.
                    Haptics.hf1()
                    changePage(to: .duo, move: CGSize(width: 0, height: -1))
                } else if state.tab == .duo && state.duoLayout {
                    // Down from the player + calendar page: the Zen space.
                    Haptics.hf1()
                    changePage(to: .zen, move: CGSize(width: 0, height: 1))
                } else {
                    cyclePage(step: 1)
                }
            } else if swipeAccumY < -40 {
                swipeFired = true
                collapse()
            }
        }
    }

    /// True while the pointer is on the player half of the Duo page.
    private func isOverDuoPlayer() -> Bool {
        let rect = bodyRect(state.metrics.duoSize)
        return NSEvent.mouseLocation.x < rect.minX + rect.width * NotchMetrics.duoPlayerFraction
    }

    private func horizontalSwipe(toRight: Bool) {
        switch state.tab {
        case .player:
            Haptics.hf1()   // song change
            if toRight {
                state.media.previousTrack()
            } else {
                state.media.nextTrack()
            }
        case .duo:
            // Same as the player page: left = next song, right = previous song.
            Haptics.hf1()   // song change
            if toRight {
                state.media.previousTrack()
            } else {
                state.media.nextTrack()
            }
        case .calendar:
            if toRight, Preferences.taskPageEnabled {
                Haptics.hf1()
                changePage(to: .todo, move: CGSize(width: 1, height: 0))
            } else if !toRight, Preferences.weatherEnabled {
                Haptics.hf1()
                changePage(to: .weather, move: CGSize(width: -1, height: 0))
            }
        case .zen:
            if toRight, Preferences.taskPageEnabled {
                Haptics.hf1()
                changePage(to: .todo, move: CGSize(width: 1, height: 0))
            } else if !toRight, Preferences.weatherEnabled {
                Haptics.hf1()
                changePage(to: .weather, move: CGSize(width: -1, height: 0))
            }
        case .weather:
            if toRight {
                if state.duoLayout {
                    Haptics.hf1()
                    changePage(to: .zen, move: CGSize(width: 1, height: 0))
                } else {
                    Haptics.hf1()
                    changePage(to: .calendar, move: CGSize(width: 1, height: 0))
                }
            }
        case .todo:
            if !toRight {
                if state.duoLayout {
                    Haptics.hf1()
                    changePage(to: .zen, move: CGSize(width: -1, height: 0))
                } else {
                    Haptics.hf1()
                    changePage(to: .calendar, move: CGSize(width: -1, height: 0))
                }
            }
        default:
            break
        }
    }
}
