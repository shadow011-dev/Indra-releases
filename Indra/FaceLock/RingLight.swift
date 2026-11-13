import SwiftUI
import AppKit

/// B13: a bright white border around the screen that lights the face when it has not been seen for a while.
@MainActor
final class RingLight {
    static let shared = RingLight()
    private var panel: NSPanel?
    private var watchdog: Timer?
    private var shownAt = Date()
    private var ringScreen: NSScreen?

    /// v543: true while the edge light window exists (the glare check of the face scan reads this).
    var isLit: Bool { panel != nil }

    func show(rampSeconds: TimeInterval = 6) {
        // Only ever lit while a locked app's blur cover is really on screen and its face scan is running.
        guard AnimationFlagsB.ringLight, panel == nil else { return }
        // v543: the light belongs to the blur cover. It was drawn on the notch screen whenever a scan was running, even when the
        // cover was not on screen yet (or on another screen, or already gone): a bright edge with no blur behind it. It now needs
        // the cover to be visible and scanning, and it is drawn on the cover's own screen.
        guard AppLockController.shared.isCoverScanning, let screen = AppLockController.shared.scanningCoverScreen else {
            Trace.log("RINGLIGHT: not shown (no visible, scanning blur cover)")
            return
        }
        ringScreen = screen
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: RingLightView(start: Date(), duration: max(1, rampSeconds)))
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        shownAt = Date()
        // Safety net: if scanning is no longer happening, the light must not stay on.
        let wd = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let limit = TimeInterval(FaceLockSettings.shared.faceDetectionSeconds) + 4
                // v543: the cover must still be on screen, on the screen the light is on: if it is not, the light goes at once.
                let coverGone = !AppLockController.shared.isCoverShown(on: self.ringScreen)
                if Date().timeIntervalSince(self.shownAt) > limit
                    || NotchOverlayController.shared.phase != .scanning
                    || !AppLockController.shared.isCoverScanning
                    || coverGone {
                    self.hide(immediately: coverGone)
                }
            }
        }
        RunLoop.main.add(wd, forMode: .common)   // keeps firing during menus and drags
        watchdog = wd
    }

    func hide(immediately: Bool = false) {
        watchdog?.invalidate()
        watchdog = nil
        guard let p = panel else { return }
        panel = nil
        ringScreen = nil
        if immediately {
            p.alphaValue = 0
            p.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

struct RingLightView: View {
    let start: Date
    let duration: TimeInterval

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    var body: some View {
        // Starts as a normal-width border, then grows wider and brighter until the scan ends.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let raw = min(1, max(0, context.date.timeIntervalSince(start) / duration))
            let t = CGFloat(raw * raw * (3 - 2 * raw))   // smooth ease in and out
            let fadeIn = min(1, max(0, context.date.timeIntervalSince(start) / 1.4))
            let smoothIn = Double(fadeIn * fadeIn * (3 - 2 * fadeIn))
            // One smooth glow: full white at the screen edge, fading evenly inward, with no visible ring.
            let inset = lerp(60, 260, t)
            ZStack {
                Rectangle().fill(Color.white)
                Rectangle().fill(Color.black)
                    .padding(inset)
                    .blur(radius: inset * 0.45)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .ignoresSafeArea()
            // v543: tops out at 0.8 (was 1.0): a fully white screen edge put saturated highlights on the face (glasses, forehead).
            .opacity(smoothIn * (0.35 + 0.45 * Double(t)))
        }
    }
}

struct RingLightTrigger: ViewModifier {
    let isScanning: Bool
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { update(isScanning) }
            .onChange(of: isScanning) { _, now in update(now) }
            .onDisappear { update(false) }
    }

    private func update(_ scanning: Bool) {
        task?.cancel()
        task = nil
        guard scanning, AnimationFlagsB.ringLight else {
            RingLight.shared.hide()
            return
        }
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            RingLight.shared.show(rampSeconds: TimeInterval(FaceLockSettings.shared.faceDetectionSeconds))
        }
    }
}
