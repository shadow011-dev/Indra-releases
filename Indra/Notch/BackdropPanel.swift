import AppKit
import SwiftUI

/// Soft frosted blur of whatever is behind the notch, strongest at the top-centre
/// and fading out progressively in every direction.
final class BackdropBlurView: NSVisualEffectView {
    private var lastMaskSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        appearance = NSAppearance(named: .darkAqua)
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1, bounds.size != lastMaskSize else { return }
        lastMaskSize = bounds.size
        maskImage = BackdropBlurView.makeMask(size: bounds.size)
    }

    private static func makeMask(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceGray(),
                    colors: [CGColor(gray: 0, alpha: 1),
                             CGColor(gray: 0, alpha: 0.9),
                             CGColor(gray: 0, alpha: 0.5),
                             CGColor(gray: 0, alpha: 0)] as CFArray,
                    locations: [0, 0.35, 0.7, 1]
                  ) else { return false }
            // Elliptical falloff centred on the top edge.
            context.translateBy(x: rect.midX, y: rect.maxY)
            context.scaleBy(x: rect.width / 2, y: rect.height)
            context.drawRadialGradient(gradient,
                                       startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: 1,
                                       options: [])
            return true
        }
    }
}

/// Click-through window that hosts the blur, one level below the notch.
final class BackdropPanel: NSPanel {
    /// Fallback: regular system blur with a soft radial mask (used only if the progressive blur is unavailable).
    private let blurView = BackdropBlurView(frame: .zero)
    /// Preferred: blurred picture of the desktop with a steady fade-out (needs Screen Recording permission).
    private let snapshotView = SnapshotBlurView(frame: .zero)

    /// Shown in Settings so a failure can be reported.
    nonisolated(unsafe) static var status = "not started"

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0
        contentView = blurView
    }

    /// Asked once per launch: a rebuilt, ad-hoc signed app loses the Screen Recording permission.

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Progressive blur around the open notch. All the numbers come from BlurTuning.swift.
    func applyStyle(notchSize: CGSize, margin: CGFloat) {
        let reach = min(BlurTuning.reach, margin)
        let radius = BlurTuning.blurAmount
        let probe = CGPoint(x: frame.midX, y: frame.maxY - 1)
        if ScreenAccess.shared.isGranted(),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main {
            if contentView !== snapshotView { contentView = snapshotView }
            BackdropPanel.status = "snapshot blur starting"
            snapshotView.refresh(screen: screen, frame: frame, notch: notchSize, corner: 38, reach: reach, radius: radius)
            return
        }
        // No permission: never show a half-working blur. Use the plain dark frosted backdrop and ask for access.
        ScreenAccess.shared.askOnce()   // v547: from a background task; the request used to wait on the main thread
        BackdropPanel.status = "Screen Recording is not allowed for this build - allow it, then reopen the notch"
        if contentView !== blurView { contentView = blurView }
    }

    /// The window stays ordered in at alpha 0, so showing it never creates a window mid-animation.
    func setVisible(_ visible: Bool, strength: CGFloat = BlurTuning.opacity) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.3 : 0.2
            self.animator().alphaValue = visible ? strength : 0
        }
    }
}
