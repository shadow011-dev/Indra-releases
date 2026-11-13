//
//  FaceScanWindowController.swift
//  Indra Face Lock
//
//  Owns the notch overlay window's lifecycle: creation, positioning, show/hide,
//  and SkyLight lock-screen delegation. Knows nothing about face recognition,
//  animation phases, or video playback — NotchOverlayController drives this.
//

import AppKit

@MainActor
final class FaceScanWindowController {
    private var window: FaceScanWindow?
    private var isSkyLightDelegated = false
    /// v483: the same private top-level Space Indra's notch lives in, so the face scan stays at the notch while the
    /// desktops slide, exactly like Indra's notch (see StickySpace).
    private var stickySpace: StickySpace?
    private var isSticky = false

    /// What the overlay controller asked for via `setInteractive(_:)`.
    private var wantsInteractive = false
    /// The visible panel's frame inside the window, in the hosting view's
    /// top-down coordinates — reported by `NotchOverlayView`.
    private var interactiveContentRect: CGRect?
    /// Re-checks the cursor while `wantsInteractive`; see `updateMousePassthrough()`.
    private var cursorPollTimer: Timer?
    /// v481: global / local mouse-moved monitors, so the cursor reaching the notch is noticed on the very event instead of
    /// at the next poll tick, and without waiting for a window that was still click-through to receive a hover.
    private var mouseMonitors: [Any] = []
    private var cursorWasOverPanel = false

    /// v481: fired once each time the cursor moves onto the visible panel on the desktop. This is what makes a desktop
    /// hover start the scan as fast as on the lock screen, where the window always takes mouse events.
    var onCursorEnteredPanel: (@MainActor () -> Void)?

    /// Slack around the visible panel before clicks pass through — keeps a
    /// click on the very edge of the shape (or mid hover-bump) from missing.
    private static let interactiveRectOutset: CGFloat = 6

    /// The SwiftUI content to host — set once by NotchOverlayController.
    var contentView: NSView? {
        didSet { window?.contentView = contentView }
    }

    /// Fired on display changes so the overlay controller can re-read `currentGeometry` —
    /// plugging in a notched display can change the panel's shape, not just its width.
    var onScreenParametersChanged: (@MainActor () -> Void)?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            // v501: not inside the unlock transition itself. The window server is swapping the whole session at that moment,
            // and this hand-off is five private Space calls plus an order-out / order-front of a top-level window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    guard !LockMonitor.isScreenActuallyLocked() else { return }
                    self?.handOffToDesktop()
                }
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Creates the window (once), positions and orders it front. If the screen is
    /// actually locked, also delegates it into the SkyLight space — see NotchSkyLight.swift.
    func show() {
        let window = windowIfNeeded()
        reposition(window)
        window.orderFrontRegardless()

        if LockMonitor.isScreenActuallyLocked(), let skyLight = NotchSkyLight.shared {
            syncStickySpace(wanted: false)   // the lock screen has its own space
            skyLight.delegate(window)
            isSkyLightDelegated = true
        } else {
            syncStickySpace(wanted: true)
        }
        updateCursorPolling()
    }

    /// Follows Indra's own "Stay on every desktop" / "Hide in Fullscreen" settings, like the notch does.
    /// v485: this now re-asserts the private Space EVERY time the window is shown. Before, it returned early once `isSticky`
    /// was set, but ordering the window out and front again (every scan ends with `hide()`) puts it back on the desktop it
    /// is shown on, so from the second scan on the face animation slid away with the wallpaper while Indra's notch (whose
    /// window is never ordered out) stayed put.
    private func syncStickySpace(wanted: Bool) {
        guard let window else { return }
        let want = wanted && Preferences.stickyDesktops && !Preferences.hideInFullscreen
        if want {
            guard window.windowNumber > 0 else { return }
            if stickySpace == nil { stickySpace = StickySpace() }
            guard let space = stickySpace else { return }
            space.add([window])
            guard space.makeExclusive([window]) else {
                // Could not leave the desktops: behave like a normal "all desktops" window.
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                isSticky = false
                return
            }
            let target: NSWindow.CollectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
            if window.collectionBehavior != target {
                window.collectionBehavior = target
                // Changing the behaviour can put the window back on the desktops: take it out again and verify.
                if !space.makeExclusive([window]) {
                    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                    isSticky = false
                    return
                }
            }
            space.refresh()
            isSticky = true
        } else if isSticky {
            stickySpace?.remove([window])
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            isSticky = false
        }
    }

    /// Forces layout/composite now instead of waiting for the next display cycle —
    /// see `NotchOverlayController.primeWindowIfNeeded`.
    func displaySynchronously() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func hide() {
        guard let window else { return }
        if isSkyLightDelegated, let skyLight = NotchSkyLight.shared {
            skyLight.undelegate(window)
            isSkyLightDelegated = false
        }
        window.orderOut(nil)
        // v485: an ordered-out window is no longer trusted to be in the private Space (see syncStickySpace).
        isSticky = false
        updateCursorPolling()
    }

    /// Screen just unlocked: the SkyLight (lock-screen) layer is about to disappear, so move the
    /// window onto the normal desktop and let any in-flight animation finish there.
    func handOffToDesktop() {
        guard let window, window.isVisible, isSkyLightDelegated else { return }
        if let skyLight = NotchSkyLight.shared { skyLight.undelegate(window) }
        isSkyLightDelegated = false
        // Removed from the SkyLight space it belongs to no desktop space until re-ordered in.
        window.orderOut(nil)
        window.orderFrontRegardless()
        syncStickySpace(wanted: true)
        updateCursorPolling()
    }

    /// `key: true` additionally makes the panel key — needed only for onboarding's
    /// password field to receive keystrokes.
    func setInteractive(_ interactive: Bool, key: Bool = false) {
        wantsInteractive = interactive
        window?.acceptsKey = interactive
        updateCursorPolling()
        guard interactive, key, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Forwarded from `NotchOverlayView` every time the visible panel's frame changes.
    func setInteractiveContentRect(_ rect: CGRect?) {
        interactiveContentRect = rect
        // v555: this is called on EVERY frame of an expansion / collapse (the panel's frame animates). Each call asked the window
        // server about the mouse flag, on top of the 60 Hz check below, which already reads the new rect on its next tick. Only
        // when that check is not running (nothing interactive) is it done here, once.
        if cursorPollTimer == nil { updateMousePassthrough() }
    }

    var currentGeometry: NotchGeometry {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen) ?? NotchGeometry.forMainScreen()
    }

    // MARK: - Click-through outside the visible panel

    /// The window's fixed frame is sized for the largest thing it ever shows
    /// (e.g. onboarding's `.enroll` step, plus shadow margin), and `ignoresMouseEvents`
    /// applies to that whole frame — macOS picks which window gets a click from
    /// its frame, not from what's drawn, so a transparent margin still swallows
    /// clicks. Instead of leaving the flag off for as long as the overlay is
    /// interactive, it's only off while the cursor is actually over the panel.
    private func updateMousePassthrough() {
        guard let window else { return }
        guard wantsInteractive else {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }   // v555: only when it changes
            cursorWasOverPanel = false
            return
        }
        // Lock screen keeps the original whole-window behaviour: nothing there sits
        // under the notch to click, and hover-to-retry must not regress.
        // v498: but the cursor arriving on the panel is now also noticed here, by position, 60 times a second. Before, the
        // lock screen relied only on SwiftUI's hover callback, which an app that is not active receives late.
        if isSkyLightDelegated, let hostView = window.contentView {
            if window.ignoresMouseEvents { window.ignoresMouseEvents = false }   // v555: only when it changes
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let local = hostView.convert(windowPoint, from: nil)
            let topDown = CGPoint(x: local.x, y: hostView.isFlipped ? local.y : hostView.bounds.height - local.y)
            let rect = interactiveContentRect ?? CGRect(x: hostView.bounds.midX - 90, y: 0, width: 180, height: 44)
            let isOver = rect.insetBy(dx: -Self.interactiveRectOutset, dy: -Self.interactiveRectOutset).contains(topDown)
            if isOver, !cursorWasOverPanel {
                cursorWasOverPanel = true
                onCursorEnteredPanel?()
            } else if !isOver {
                cursorWasOverPanel = false
            }
            return
        }
        guard !isSkyLightDelegated, let rect = interactiveContentRect, let hostView = window.contentView else {
            if window.ignoresMouseEvents { window.ignoresMouseEvents = false }   // v555: only when it changes
            cursorWasOverPanel = false
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = hostView.convert(windowPoint, from: nil)
        // `rect` is top-down (SwiftUI); normalise the AppKit point to match.
        let topDown = CGPoint(x: local.x, y: hostView.isFlipped ? local.y : hostView.bounds.height - local.y)
        let isOverPanel = rect.insetBy(dx: -Self.interactiveRectOutset, dy: -Self.interactiveRectOutset).contains(topDown)
        if window.ignoresMouseEvents == isOverPanel {
            window.ignoresMouseEvents = !isOverPanel
        }
        // v481: the cursor arriving on the panel starts the scan / retry right away (same speed as the lock screen).
        if isOverPanel, !cursorWasOverPanel {
            cursorWasOverPanel = true
            onCursorEnteredPanel?()
        } else if !isOverPanel {
            cursorWasOverPanel = false
        }
    }

    /// Polls rather than using mouse-moved events: a window ignoring mouse events
    /// receives none, and a global event monitor doesn't fire for movement over
    /// this app's own windows.
    private func updateCursorPolling() {
        let shouldPoll = wantsInteractive && (window?.isVisible ?? false)
        if shouldPoll, cursorPollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassthrough() }
            }
            RunLoop.main.add(timer, forMode: .common)
            cursorPollTimer = timer
        } else if !shouldPoll {
            cursorPollTimer?.invalidate()
            cursorPollTimer = nil
        }
        updateMouseMonitors(active: shouldPoll)
        updateMousePassthrough()
    }

    /// v481: reacts on the mouse-moved event itself. Global monitor: movement over other apps' windows (this window is
    /// click-through while the cursor is elsewhere). Local monitor: movement over this app's own windows.
    private func updateMouseMonitors(active: Bool) {
        if active, mouseMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassthrough() }
            }) { mouseMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
                MainActor.assumeIsolated { self?.updateMousePassthrough() }
                return event
            }) { mouseMonitors.append(local) }
        } else if !active, !mouseMonitors.isEmpty {
            mouseMonitors.forEach { NSEvent.removeMonitor($0) }
            mouseMonitors.removeAll()
            cursorWasOverPanel = false
        }
    }

    private func windowIfNeeded() -> FaceScanWindow {
        if let window { return window }
        // Never resized afterward (see FaceScanWindow.swift), so a style change
        // mid-session keeps whatever margin it was created with.
        let size = NotchGeometry.windowSize(for: currentGeometry.style)
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let newWindow = FaceScanWindow(contentRect: rect)
        // The panel's own SwiftUI animation has already reached its closed notch
        // size before this window is ordered out. Do not add AppKit's separate
        // blur/fade transition at that point — revealing the hardware notch must
        // be instantaneous.
        newWindow.animationBehavior = .none
        newWindow.contentView = contentView
        window = newWindow
        return newWindow
    }

    private func reposition(_ window: FaceScanWindow) {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let screenFrame = screen.frame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        ))
    }

    @objc private func screenParametersChanged() {
        onScreenParametersChanged?()
        guard let window, window.isVisible else { return }
        reposition(window)
        if !isSkyLightDelegated { syncStickySpace(wanted: true) }
    }
}
