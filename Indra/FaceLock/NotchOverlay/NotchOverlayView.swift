//
//  NotchOverlayView.swift
//  Indra Face Lock
//
//  SwiftUI root hosted inside the fixed-size FaceScanWindow — only content moves/resizes.
//  Two silhouettes per screen (see NotchPanelStyle): `.notch` sits on the physical
//  cutout; `.pill` is a detached island that slides on/off screen (and docks in place
//  on the lock screen instead of sliding).
//
//  Enter/exit choreography (pill only, see `scheduleChoreography()`) staggers slide vs.
//  expansion using real `Task.sleep` delays on separate `@State` mirrors, not two
//  `.animation(value:)` modifiers — those don't stagger reliably, since SwiftUI can't
//  cleanly split which properties belong to which modifier when both fire in one transaction.
//

import SwiftUI
import AppKit

/// The visible panel's current frame, relative to the fixed window's full
/// bounds — see the `.background(GeometryReader...)` in `body` and
/// `FaceScanWindowController.updateMousePassthrough()`.
private struct InteractivePanelFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct NotchOverlayView: View {
    let controller: NotchOverlayController

    @State private var isHovering = false

    /// Visual mirrors of the controller's target state — see the file header for why
    /// these are separate `@State` rather than computed directly.
    @State private var visualIsExpanded = false
    @State private var visualIsPositioned = false
    /// The in-flight trailing half of an enter/exit choreography, if any.
    @State private var choreographyTask: Task<Void, Never>?

    /// Mirrors "phase is `.success`", not the phase itself, so the flip can be delayed
    /// (`minimalLockUnlockDelay`) and held open across the collapse.
    @State private var isMinimalLockOpen = false
    /// The pending delayed unlock, if any.
    @State private var lockUnlockTask: Task<Void, Never>?

    /// Only ever mutated inside an explicit `withAnimation`, so it never jumps.
    @State private var isScanPulseDimmed = false
    /// The running ping-pong loop while `.scanning`, if any.
    @State private var scanPulseTask: Task<Void, Never>?

    private var style: NotchPanelStyle {
        controller.geometry.style
    }

    /// `scheduleChoreography()` compares this against `visualIsExpanded` to decide what needs to move.
    private var targetIsExpanded: Bool {
        switch controller.phase {
        case .closed, .collapsing: return false
        case .scanning, .success, .failure, .onboarding: return true
        }
    }

    /// Notch style is always positioned (the physical notch never travels). Expanded
    /// always implies positioned regardless of the docked flag, so a mid-success
    /// `disarm()` (which undocks) doesn't yank the panel away mid-animation.
    private var targetIsPositioned: Bool {
        if targetIsExpanded { return true }
        if style == .notch { return true }
        return controller.isPillDocked
    }

    /// While onboarding is active, the panel body tracks its step size instead of the
    /// fixed scan-mode footprint — this is what makes the panel grow/shrink per step.
    private var onboardingController: OnboardingController? {
        if case .onboarding(let controller) = controller.content { return controller }
        return nil
    }

    /// Onboarding always uses the full panel, and `.none` keeps the full expansion too
    /// (it only drops the video) — so this is specifically `.minimal` scan content.
    private var isMinimalScan: Bool {
        onboardingController == nil && controller.activeUnlockStyle == .minimal
    }

    private var scanOpenSize: CGSize {
        guard style == .notch else { return NotchGeometry.pillOpenSize }
        // v555: the Tile scan is exactly as wide as the volume / brightness card that hangs below Indra's notch (its outer width
        // includes the two ears, which the shape adds here as `flareAllowance`). It was a few points narrower.
        let metrics = NotchMetrics.make(for: NotchMetrics.notchScreen() ?? NSScreen.main, island: false)
        let width = max(NotchGeometry.notchOpenSize.width, metrics.hudDownlineSize.width - NotchGeometry.openTopRadius * 2)
        return CGSize(width: width, height: NotchGeometry.notchOpenSize.height)
    }

    /// In notch style the width grows to add flanking black beside the physical cutout;
    /// the height grows since the cutout itself can't, so the bump appears below it.
    @AppStorage(Preferences.liquidGlassKey) private var liquidGlass = false
    @AppStorage(Preferences.translucentNotchKey) private var translucentNotch = true
    @AppStorage(Preferences.glassDarknessKey) private var glassDarkness = 0.55
    private var minimalOpenBodySize: CGSize {
        switch style {
        case .notch:
            // The size of Indra's own collapsed notch while it shows a live activity, a song change or the volume /
            // brightness HUD: the notch widened by the activity slot on each side, same height.
            let metrics = NotchMetrics.make(for: NotchMetrics.notchScreen() ?? NSScreen.main, island: false)
            let closed = controller.geometry.closedSize
            // v485: plus `minimalExtraWidth`, so the slide out of the notch is longer.
            return CGSize(width: closed.width + metrics.compactSlot * 2 + 16 + NotchGeometry.minimalExtraWidth
                            + NotchGeometry.minimalLengthAdjust,
                          height: closed.height + NotchGeometry.minimalHeightAdjust)
        case .pill:
            return CGSize(
                width: NotchGeometry.minimalPillOpenWidth + NotchGeometry.minimalLengthAdjust,
                height: NotchGeometry.minimalPillOpenHeight + NotchGeometry.minimalHeightAdjust
            )
        }
    }

    private var openBodySize: CGSize {
        if let onboardingController { return onboardingController.panelSize }
        return isMinimalScan ? minimalOpenBodySize : scanOpenSize
    }

    /// Minimal scan on a physical notch: the capsule is detached from the notch and floats below it.
    /// Other animations, and displays without a notch, are unchanged.
    private var isDetachedMinimal: Bool {
        // The Minimal capsule always opens inside the notch (the "below notch" placement was removed).
        false
    }

    /// The silhouette actually drawn: a plain capsule when detached.
    private var drawStyle: NotchPanelStyle {
        isDetachedMinimal ? .pill : style
    }

    /// Top edge of the detached capsule: the notch's lower edge plus a gap of
    /// `minimalDetachedGapInWidths` capsule widths.
    private var detachedMinimalTopOffset: CGFloat {
        controller.geometry.closedSize.height
            + minimalOpenBodySize.width * NotchGeometry.minimalDetachedGapInWidths
    }

    private var closedBodySize: CGSize {
        // Detached minimal tucks a small capsule inside the notch while closed (see `verticalOffset`).
        isDetachedMinimal ? NotchGeometry.pillClosedSize : controller.geometry.closedSize
    }

    private var topRadius: CGFloat {
        if visualIsExpanded {
            if isMinimalScan {
                // Pill stays a true capsule as it stretches — radius tracks the animating height.
                return drawStyle == .notch
                    ? NotchGeometry.minimalNotchTopRadius
                    : minimalOpenBodySize.height / 2
            }
            return style == .notch ? NotchGeometry.openTopRadius : NotchGeometry.pillOpenCornerRadius
        }
        // Half the height is exactly a capsule end, in pill style.
        return drawStyle == .notch ? NotchGeometry.closedTopRadius : closedBodySize.height / 2
    }

    private var bottomRadius: CGFloat {
        if visualIsExpanded {
            if isMinimalScan {
                return drawStyle == .notch
                    ? NotchGeometry.minimalNotchBottomRadius
                    : minimalOpenBodySize.height / 2
            }
            guard style == .notch else {
                // Uniform corners in pill style — no flare to balance, unlike the notch.
                return NotchGeometry.pillOpenCornerRadius
            }
            return onboardingController?.panelBottomRadius ?? NotchGeometry.openBottomRadius
        }
        return drawStyle == .notch ? NotchGeometry.closedBottomRadius : closedBodySize.height / 2
    }

    /// Widened by `flareAllowance` in notch style so the closed state lands exactly on
    /// the physical notch width instead of coming up short by the flare.
    private var currentSize: CGSize {
        let body = visualIsExpanded ? openBodySize : closedBodySize
        // The resting silhouette must resolve to the measured hardware size.
        // Keeping the hover bump while closing made the overlay finish wider and
        // taller than the real notch immediately before the window disappeared.
        let bump: CGFloat = visualIsExpanded && isHovering ? NotchGeometry.hoverBump : 0
        return CGSize(
            width: body.width + NotchGeometry.flareAllowance(topRadius: topRadius, style: drawStyle) + bump,
            height: body.height + bump
        )
    }

    /// Top-aligned inside the fixed window frame, so sliding is purely a matter of
    /// where the top edge sits.
    private var verticalOffset: CGFloat {
        if isDetachedMinimal {
            // Tucked inside the notch while closed, then drops below it. Rides the expansion
            // animation, so it keeps the same timing as the old in-place minimal animation.
            return visualIsExpanded ? detachedMinimalTopOffset : 0
        }
        guard style == .pill else { return 0 }
        guard visualIsPositioned else {
            return -(closedBodySize.height + NotchGeometry.pillOffscreenSlack)
        }
        return NotchGeometry.pillTopGap
    }

    /// So it resolves into focus as it slides down, rather than snapping in.
    private var panelBlur: CGFloat {
        drawStyle == .pill && !visualIsPositioned ? NotchGeometry.pillEnterBlur : 0
    }

    private var scanContentPaddingTop: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingTop : NotchGeometry.notchContentPaddingTop
    }

    private var scanContentPaddingLeading: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingLeading : NotchGeometry.notchContentPaddingLeading
    }

    private var scanContentPaddingTrailing: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingTrailing : NotchGeometry.notchContentPaddingTrailing
    }

    private var scanContentPaddingBottom: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingBottom : NotchGeometry.notchContentPaddingBottom
    }

    /// Direction-only — any enter-side delay is a real `Task.sleep` before this is
    /// applied (see `scheduleChoreography()`), not baked into the curve.
    /// v481: the very same springs as Indra's own notch (`NotchMotion.open` / `.close`; v494: the closing one is 10% faster, see
    /// `FaceScanMotion`), for every face scan however it
    /// was started (lock screen, app lock, hover, button, retry, onboarding), so both notches expand and collapse alike.
    private func expansionAnimation(entering: Bool) -> Animation {
        entering ? NotchMotion.open : FaceScanMotion.close
    }

    /// A straight-line off-screen/on-screen move, not a bouncy resize.
    private var slideAnimation: Animation {
        .easeOut(duration: NotchGeometry.pillSlideDuration)
    }

    // MARK: - Scan pulse

    /// Success and failure both leave `.scanning`, ending the pulse so the resolve
    /// animation plays against steady content.
    private var isScanning: Bool {
        controller.phase == .scanning
    }

    private var scanPulseScale: CGFloat {
        isScanPulseDimmed ? NotchGeometry.scanPulseScale : 1
    }

    private var scanPulseOpacity: Double {
        isScanPulseDimmed ? NotchGeometry.scanPulseOpacity : 1
    }

    /// The breathing pulse is applied to the video only, never the lock icon or the
    /// whole panel — hence passing it into `MinimalUnlockView` rather than wrapping `Group`.
    @ViewBuilder
    private var scanContent: some View {
        if isMinimalScan {
            MinimalUnlockView(
                media: controller.media,
                isUnlocked: isMinimalLockOpen,
                // The notch's flare eats `topRadius` before any real black starts.
                edgeInset: NotchGeometry.minimalContentEdgeInset
                    + (style == .notch ? (isDetachedMinimal ? NotchGeometry.minimalNotchTopRadius : topRadius) : 0),
                lockIconSize: style == .notch
                    ? NotchGeometry.minimalNotchLockIconSize : NotchGeometry.minimalLockIconSize,
                mediaWidth: style == .notch
                    ? NotchGeometry.minimalNotchMediaWidth : NotchGeometry.minimalMediaWidth,
                mediaVerticalInset: style == .notch
                    ? NotchGeometry.minimalNotchMediaVerticalInset
                    : NotchGeometry.minimalMediaVerticalInset,
                pulseScale: scanPulseScale,
                pulseOpacity: scanPulseOpacity,
                revealed: visualIsExpanded,
                travel: NotchGeometry.minimalRevealTravel
            )
        } else {
            ScanAnimationView(media: controller.media)
                .padding(.leading, scanContentPaddingLeading)
                .padding(.trailing, scanContentPaddingTrailing)
                .padding(.top, scanContentPaddingTop)
                .padding(.bottom, scanContentPaddingBottom)
                .scaleEffect(scanPulseScale)
                .opacity(scanPulseOpacity)
        }
    }

    /// v479: the solid black that lets the CLOSED panel merge with the hardware notch. It used to fade with the same slow
    /// spring as the size, so the glass / translucent body stayed black for most of the opening and turned black again
    /// early in the closing. Now it clears within a moment of the opening starting and only returns at the very end of
    /// the closing, so the glass is visible for the whole movement.
    private var closedBlackLayer: some View {
        let fade = 0.14
        return Color.black
            .opacity(visualIsExpanded ? 0 : 1)
            .animation(
                visualIsExpanded
                    ? Animation.easeOut(duration: fade)
                    : Animation.easeIn(duration: fade).delay(max(0, NotchGeometry.closeEaseDuration - fade)),
                value: visualIsExpanded
            )
    }

    /// Black on the lock screen. On the desktop the body follows the notch's own Appearance settings (liquid glass,
    /// or translucent with the chosen darkness), and is black while closed so it blends with the hardware notch.
    @ViewBuilder
    private var scanBackground: some View {
        if !controller.scanOnDesktop {
            Color.black
        } else if #available(macOS 26.0, *), liquidGlass {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: FaceScanNotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: drawStyle))
                Color.black.opacity(glassDarkness)
                closedBlackLayer
            }
        } else if translucentNotch {
            ZStack {
                FrostedBackground()
                Color.black.opacity(glassDarkness * 0.9)
                closedBlackLayer
            }
        } else {
            Color.black
        }
    }

    var body: some View {
        ZStack {
            Group {
                if let onboardingController {
                    // Onboarding's step views fill `panelSize` themselves — no shared padding here.
                    OnboardingNotchView(controller: onboardingController)
                } else {
                    scanContent
                }
            }
            // Content dissolves (blur + fade) as the panel shrinks, rather than being
            // abruptly clipped by the collapsing shape. Rides the animation already
            // active on `visualIsExpanded` — no separate `.animation` needed.
            // No blur here: animating a blur over video content on every frame made the opening stutter and
            // showed the content blurry at the start. Fade + scale alone dissolves it cleanly.
            // v485: the inline (Minimal) scan reveals its lock and video itself (they glide out of the notch one after the
            // other, see MinimalUnlockView), so the whole group is not scaled / faded here.
            .opacity(isMinimalScan || visualIsExpanded ? 1 : 0)
            .scaleEffect(isMinimalScan || visualIsExpanded ? 1 : 0.3)
            .environment(\.notchPanelStyle, style)
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(scanBackground)
        .modifier(RingLightTrigger(isScanning: controller.phase == .scanning))
        .overlay(ScanningGlow(isActive: controller.phase == .scanning))
        .overlay(FailureFlash(isFailing: controller.phase == .failure))
        .overlay(SuccessWash(isSuccess: controller.phase == .success))
        .clipShape(FaceScanNotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: drawStyle))
        .modifier(FailureShake(isFailing: controller.phase == .failure))
        // Reports this panel's own current frame, relative to the fixed
        // window's full bounds (`Self.interactiveCoordinateSpace`, declared
        // below on the outermost frame) — restricts the window's click
        // capture to the shape actually on screen instead of its whole
        // fixed max-envelope frame. See `FaceScanWindowController.updateMousePassthrough()`.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InteractivePanelFramePreferenceKey.self,
                    value: proxy.frame(in: .named(Self.interactiveCoordinateSpace))
                )
            }
        )
        // Shadow only while expanded — otherwise it left a faint dim halo around the
        // real notch even while "closed" in armed mode. Radius is fixed rather than
        // growing on hover since a larger radius needs more window margin than is reserved.
        .shadow(color: .black.opacity(visualIsExpanded ? (isHovering ? 0.55 : 0.3) : 0), radius: 9)
        // Drives the per-step resize while onboarding is active — `visualIsExpanded`
        // alone only fires on entering/leaving the expanded state.
        .animation(expansionAnimation(entering: true), value: onboardingController?.panelSize)
        .blur(radius: panelBlur)
        // Applied after the shadow so both travel together, before `.onHover`.
        .offset(y: verticalOffset)
        .onHover { hovering in
            // v487: the 0.18 s hover bump used to be a `.animation(value: isHovering)` on the whole panel. A scan that is
            // started BY hovering the notch (App Lock's "scan only on hover") changes `isHovering` in the very same moment
            // the panel starts to expand, so that short ease-out replaced the opening spring and the notch snapped open far
            // faster than on the lock screen. The short ease now only runs while the panel is already open (the bump); a
            // hover that starts the expansion leaves the opening spring alone.
            if visualIsExpanded {
                withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
            } else {
                isHovering = hovering
            }
            if hovering {
                performHapticFeedback(.generic)
                controller.activate()
            }
        }
        .onAppear {
            // Sync without animating — nothing to animate from on first appearance.
            visualIsExpanded = targetIsExpanded
            visualIsPositioned = targetIsPositioned
            updateScanPulse()
            updateMinimalLock()
        }
        .onDisappear {
            scanPulseTask?.cancel()
            scanPulseTask = nil
            lockUnlockTask?.cancel()
            lockUnlockTask = nil
        }
        .onChange(of: controller.phase) { _, newPhase in
            scheduleChoreography()
            updateScanPulse()
            updateMinimalLock()
            if newPhase == .success {
                performHapticFeedback(.levelChange)
            }
        }
        .onChange(of: controller.isPillDocked) { _, _ in scheduleChoreography() }
        .frame(
            width: NotchGeometry.windowSize(for: style).width,
            height: NotchGeometry.windowSize(for: style).height,
            alignment: .top
        )
        // Anchored on this outermost, full-window-sized frame so the panel's
        // reported frame above is directly comparable to the hosting view's
        // own bounds — see `FaceScanWindowController.updateMousePassthrough()`.
        .coordinateSpace(name: Self.interactiveCoordinateSpace)
        .onPreferenceChange(InteractivePanelFramePreferenceKey.self) { rect in
            controller.updateInteractiveContentRect(rect)
        }
    }

    private static let interactiveCoordinateSpace = "NotchOverlayRoot"

    /// Staggers the two when both need to change (see file header for why this uses
    /// real `Task.sleep` delays rather than `Animation.delay()`).
    private func scheduleChoreography() {
        let wantExpanded = targetIsExpanded
        let wantPositioned = targetIsPositioned
        choreographyTask?.cancel()
        choreographyTask = nil

        let expandedChanging = wantExpanded != visualIsExpanded
        let positionedChanging = wantPositioned != visualIsPositioned
        guard expandedChanging || positionedChanging else { return }

        guard expandedChanging && positionedChanging else {
            // Only one property is moving — no partner to stagger against.
            if expandedChanging {
                withAnimation(expansionAnimation(entering: wantExpanded)) { visualIsExpanded = wantExpanded }
            } else {
                withAnimation(slideAnimation) { visualIsPositioned = wantPositioned }
            }
            return
        }

        if wantExpanded {
            // Entering: slide leads immediately, expansion trails after a real delay.
            withAnimation(slideAnimation) { visualIsPositioned = wantPositioned }
            let delay = NotchGeometry.pillEnterExpansionDelay
            let animation = expansionAnimation(entering: true)
            choreographyTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(animation) { self.visualIsExpanded = wantExpanded }
            }
        } else {
            // Exiting: shrink leads immediately, slide trails after a real delay.
            withAnimation(expansionAnimation(entering: false)) { visualIsExpanded = wantExpanded }
            let delay = NotchGeometry.pillExitSlideDelay
            let animation = slideAnimation
            choreographyTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(animation) { self.visualIsPositioned = wantPositioned }
            }
        }
    }

    // MARK: - FaceLockHaptics

    /// `defaultPerformer` isn't tied to this view/window, so this is safe to call even
    /// while this panel isn't key (hover on the lock screen never makes it key).
    private func performHapticFeedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard FaceLockSettings.shared.hapticFeedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    // MARK: - Scan pulse

    private func updateScanPulse() {
        if isScanning {
            startScanPulse()
        } else {
            stopScanPulse()
        }
    }

    // MARK: - Minimal lock glyph

    /// The animation lives on the glyph itself, so setting the state plainly here is
    /// already animated.
    private func updateMinimalLock() {
        let shouldOpen: Bool
        switch controller.phase {
        case .success:
            shouldOpen = true
        case .collapsing:
            // Hold whatever it currently is — re-locking now would read as undoing the unlock.
            return
        case .closed, .scanning, .failure, .onboarding:
            shouldOpen = false
        }

        lockUnlockTask?.cancel()
        lockUnlockTask = nil
        guard shouldOpen != isMinimalLockOpen else { return }

        // Only the unlock is delayable; re-locking happens while invisible anyway.
        let delay = NotchGeometry.minimalLockUnlockDelay
        guard shouldOpen, delay > 0 else {
            isMinimalLockOpen = shouldOpen
            return
        }
        lockUnlockTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.isMinimalLockOpen = true
        }
    }

    /// Each half-cycle is its own finite `withAnimation` rather than one
    /// `.repeatForever(autoreverses:)` — a repeatForever owns the property for its
    /// whole lifetime and snaps on removal, whereas discrete half-cycles let
    /// `stopScanPulse()` retarget mid-flight and interpolate from the rendered value.
    private func startScanPulse() {
        // Already breathing (or waiting to start) — don't stack a second loop on top.
        guard scanPulseTask == nil else { return }

        // Pill doesn't start expanding until `pillEnterExpansionDelay` elapses, so
        // that's added on top here too.
        let entryDelay = (style == .pill ? NotchGeometry.pillEnterExpansionDelay : 0)
            + NotchGeometry.scanPulseStartDelay
        let half = NotchGeometry.scanPulseHalfCycleDuration
        let hold = NotchGeometry.scanPulseHoldDuration
        scanPulseTask = Task {
            try? await Task.sleep(for: .seconds(entryDelay))
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: half)) { self.isScanPulseDimmed = true }
                try? await Task.sleep(for: .seconds(half + hold))
                guard !Task.isCancelled else { break }

                withAnimation(.easeInOut(duration: half)) { self.isScanPulseDimmed = false }
                try? await Task.sleep(for: .seconds(half + hold))
            }
        }
    }

    /// Retargets to `false` so SwiftUI animates from the current rendered value back to
    /// full without a jump; the guard leaves an already-settled/returning panel alone.
    private func stopScanPulse() {
        scanPulseTask?.cancel()
        scanPulseTask = nil
        guard isScanPulseDimmed else { return }
        withAnimation(.easeOut(duration: NotchGeometry.scanPulseSettleDuration)) {
            isScanPulseDimmed = false
        }
    }
}
