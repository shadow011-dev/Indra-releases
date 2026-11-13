//
//  NotchGeometry.swift
//  Indra Face Lock
//
//  Pure geometry — no AppKit window knowledge.
//

import AppKit
import CoreGraphics
import SwiftUI   // v495: FaceScanMotion below returns SwiftUI's Animation (v494 did not build without this)

struct NotchGeometry {
    /// Physical notch's own dimensions, or `pillClosedSize`.
    let closedSize: CGSize
    /// True if this screen has a real physical notch (vs. the pill fallback).
    let isPhysicalNotch: Bool

    var style: NotchPanelStyle { isPhysicalNotch ? .notch : .pill }

    /// Fixed footprint of expanded scan-mode content in notch style. Sized for the
    /// square (432x432) scan animation plus breathing room. Pill has its own `pillOpenSize`.
    static let notchOpenSize = CGSize(width: 254, height: 231)

    /// Corner radii for the notch silhouette. The top radius doubles as the
    /// width of the outward flare on each side (see FaceScanNotchShape).
    static let closedTopRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 12
    static let openTopRadius: CGFloat = 16
    static let openBottomRadius: CGFloat = 60

    /// A shape drawn in a rect of width `w` has a visible body of `w - 2 * topRadius`;
    /// zero in pill style, which has no flare.
    static func flareAllowance(topRadius: CGFloat, style: NotchPanelStyle) -> CGFloat {
        style == .notch ? topRadius * 2 : 0
    }

    // MARK: - Pill style (non-notched displays) — EDIT HERE
    //
    // The dynamic-island fallback. Collapsed it's a capsule; expanded it's a
    // floating rounded rectangle sized by `pillOpenSize` in scan mode, or
    // whatever step onboarding is on.

    /// Deliberately narrower than every expanded footprint so growth reads as visible.
    static let pillClosedSize = CGSize(width: 80, height: 24)

    /// Independent of `notchOpenSize`; larger by default since the pill has no camera housing.
    static let pillOpenSize = CGSize(width: 180, height: 180)

    /// Never zero — the whole point of the pill is that it's detached from the edge.
    static let pillTopGap: CGFloat = 3

    /// Uniform on all four corners (unlike the notch); matches `openBottomRadius`.
    static let pillOpenCornerRadius: CGFloat = 48

    /// Blur applied to the whole panel while off-screen, resolving to zero as it slides into place.
    static let pillEnterBlur: CGFloat = 0

    /// Comfortably more than `pillEnterBlur` — a Gaussian blur spreads past its nominal
    /// radius, and without this margin the parked pill smears a faint band at the screen top.
    static let pillOffscreenSlack: CGFloat = 20

    /// Pill's equivalent of `notchContentPadding*` below, independent so it can be tuned separately.
    static let pillContentPaddingTop: CGFloat = 32
    static let pillContentPaddingLeading: CGFloat = 32
    static let pillContentPaddingTrailing: CGFloat = 32
    static let pillContentPaddingBottom: CGFloat = 32

    // MARK: - Panel open/close springs — EDIT HERE
    //
    // v481: the open / close springs are no longer defined here. The face scan notch uses `NotchMotion.open` and
    // `NotchMotion.close` (Indra's own notch), so changing them there changes both notches.
    /// Roughly how long the close spring takes to land; only used to time the closed black layer's return.
    /// Must stay below `NotchOverlayController.collapseAnimationDuration`.
    static let closeEaseDuration: Double = 0.45 / collapseSpeedFactor

    /// v494: the face scan notch folds back 10% faster than before (the collapse spring, the content fade, the black layer's
    /// return and the wait before the window is hidden all shorten by this factor). 1.0 = the old speed. Only the face scan
    /// notch uses it; Indra's own notch keeps `NotchMotion.close`.
    static let collapseSpeedFactor: Double = 1.10

    // MARK: - Pill enter/exit choreography — EDIT HERE
    //
    // Style `.pill` only. Slide and expansion run on independent timelines:
    // enter slides first then grows; exit shrinks first then slides away.

    /// Ease-out rather than a spring — a straight-line move, not a bouncy resize.
    static let pillSlideDuration: Double = AnimationFlags.consistentTiming ? Motion.base : 0.25
    /// Expansion starts this long after the slide begins.
    static let pillEnterExpansionDelay: Double = 0.16
    /// Slide starts this long after the shrink begins.
    static let pillExitSlideDelay: Double = 0.18 / collapseSpeedFactor

    // MARK: - Minimal unlock style — EDIT HERE
    //
    // `UnlockAnimationStyle.minimal`: the silhouette widens only, revealing a lock
    // icon on one side and the unlock video on the other. See MinimalUnlockView.

    /// Total notch body width is `geometry.closedSize.width + 2 * this`. Window is
    /// ~534pt wide (v486: `minimalWindowContentWidth`, see `windowSize(for:)`), so much past 100 will start to clip.
    static let minimalNotchFlankWidth: CGFloat = 80
    static var minimalFlankWidthCurrent: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "minimalCapsuleFlank") as? Double) ?? Double(minimalNotchFlankWidth))
    }

    /// Taller than `pillClosedSize.height` for legibility; radius stays `height / 2`
    /// so it remains a true capsule while stretching.
    static let minimalPillOpenWidth: CGFloat = 150
    static let minimalPillOpenHeight: CGFloat = 40

    /// Extra height added only in notch style — the physical notch's height can't
    /// change, so this appears as real, visible black below it.
    static let minimalNotchHeightBump: CGFloat = 12
    static var minimalHeightBumpCurrent: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "minimalCapsuleHeightBump") as? Double) ?? Double(minimalNotchHeightBump))
    }

    /// Minimal animation on a physical notch floats below it. The gap between the notch's lower edge and
    /// the capsule's top edge, as a multiple of the capsule's own width. 1.0 = one full capsule width.
    static let minimalDetachedGapInWidths: CGFloat = 0.15

    /// Window height reserved for the detached capsule: notch + gap + capsule, with room to spare.
    /// Grows with `minimalDetachedGapInWidths`. The overlay window is created once and never resized.
    static var minimalDetachedReserveHeight: CGFloat {
        40 + minimalDetachedGapInWidths * 330 + 60
    }

    /// More rounded than the resting silhouette's radii (8/12), same ratio the
    /// full-expand style uses (16/60).
    static let minimalNotchTopRadius: CGFloat = 12
    static let minimalNotchBottomRadius: CGFloat = 22

    /// In notch style the flare already occupies `topRadius` of this margin.
    static let minimalContentEdgeInset: CGFloat = 4

    /// Point size of the lock glyph, pill style (and the shared fallback).
    static let minimalLockIconSize: CGFloat = 14
    /// The video is square and aspect-fit, so its rendered size is really
    /// `min(this, panelHeight - 2 * minimalMediaVerticalInset)`.
    static let minimalMediaWidth: CGFloat = 34
    /// Without this the square aspect-fits to the full panel height and touches both edges.
    static let minimalMediaVerticalInset: CGFloat = 8

    /// Notch-style counterparts of the three above, bumped up to match `minimalNotchHeightBump`.
    static let minimalNotchLockIconSize: CGFloat = 17
    static let minimalNotchMediaWidth: CGFloat = 44
    /// v485: smaller inset (was 11), so the scan video is drawn larger inside the widened notch.
    static let minimalNotchMediaVerticalInset: CGFloat = 8

    /// v485: how much further than Indra's own live-activity width the inline (Minimal) face scan slides out, in total
    /// (half of this on each side). The slide was too short: the lock and the video sat tight against the notch.
    /// v486: still too short, so more than doubled (44 to 100: 50 pt more on each side of the notch).
    static let minimalExtraWidth: CGFloat = 100

    /// v496: the final size of the Minimal pill, chosen with the (now removed) v491 sliders: how much shorter (-) or longer (+)
    /// than designed, and how much taller, in points.
    static let minimalLengthAdjust: CGFloat = -60
    static let minimalHeightAdjust: CGFloat = 20
    /// How far (pt) the lock and the video travel while they glide out of the notch as it widens (v486: 34 to 60, so
    /// they cross the longer slide instead of appearing near the notch).
    static let minimalRevealTravel: CGFloat = 60
    /// v486: the fixed window must be wide enough for the widened inline body (closed notch + both slots + 100 pt) or its
    /// shadow and edges would be clipped.
    static let minimalWindowContentWidth: CGFloat = 620

    /// So the lock glyph can be nudged to land with the video's own resolve beat.
    static let minimalLockUnlockDelay: Double = 0
    static let minimalLockAnimationDuration: Double = AnimationFlags.consistentTiming ? Motion.base : 0.4

    // MARK: - Scan "breathing" pulse — EDIT HERE
    //
    // While `.scanning`, content ping-pongs between full size/opacity and
    // `scanPulseScale`/`scanPulseOpacity` so the panel reads as searching, not frozen.
    // See `NotchOverlayView.startScanPulse()`.

    /// Scale at the dimmed end of the ping-pong. 1.0 disables the size part.
    static let scanPulseScale: CGFloat = 0.97
    /// Opacity at the dimmed end. 1.0 disables the fade part.
    static let scanPulseOpacity: Double = 0.65
    /// One half-cycle — full → dimmed, or dimmed → full.
    static let scanPulseHalfCycleDuration: Double = 0.4
    /// Pause at each end before reversing. 0 makes it a continuous breathe.
    static let scanPulseHoldDuration: Double = 0.05
    /// Deliberately quicker than a half-cycle so content is back at full while the
    /// success/failure animation is still early in its playback.
    static let scanPulseSettleDuration: Double = AnimationFlags.consistentTiming ? Motion.fast : 0.2

    /// Wait before the first pulse cycle so breathing starts only once the panel has
    /// finished expanding. Hand-tuned approximation — springs have no hard end time.
    static let scanPulseStartDelay: Double = 0.6

    /// Notch-style padding around scan-mode content. Pill has its own independent set below.
    static let notchContentPaddingTop: CGFloat = 26
    static let notchContentPaddingLeading: CGFloat = 40
    static let notchContentPaddingTrailing: CGFloat = 40
    static let notchContentPaddingBottom: CGFloat = 30

    /// Cosmetic size bump applied on hover in NotchOverlayView. Included here so the
    /// fixed window has margin for it instead of clipping.
    static let hoverBump: CGFloat = 6

    // MARK: - Window size, per style — EDIT HERE
    //
    // Created once and never resized afterward (see FaceScanWindow.swift). Each style is
    // floored to its own scan-mode footprint and gets its own shadow margin, tuned independently.

    /// Extra margin so SwiftUI's `.shadow()` isn't clipped (the window itself has
    /// `hasShadow = false` — the shadow is drawn in-content).
    static let notchShadowPadding: CGFloat = 24
    static let pillShadowPadding: CGFloat = 24

    static func windowSize(for style: NotchPanelStyle) -> CGSize {
        switch style {
        case .notch:
            let contentWidth = max(notchOpenSize.width, OnboardingMetrics.maxPanelWidth, minimalWindowContentWidth)
            let contentHeight = max(notchOpenSize.height, OnboardingMetrics.maxPanelHeight(for: .notch), minimalDetachedReserveHeight)
            return CGSize(
                width: contentWidth + notchShadowPadding * 2 + hoverBump,
                height: contentHeight + notchShadowPadding + hoverBump
            )
        case .pill:
            let contentWidth = max(pillOpenSize.width, OnboardingMetrics.maxPanelWidth)
            let contentHeight = max(pillOpenSize.height, OnboardingMetrics.maxPanelHeight(for: .pill))
            return CGSize(
                width: contentWidth + pillShadowPadding * 2 + hoverBump,
                // `pillTopGap` since the detached pill's panel is pushed down by that much.
                height: contentHeight + pillShadowPadding + hoverBump + pillTopGap
            )
        }
    }

    static func forMainScreen() -> NotchGeometry {
        guard let screen = NSScreen.main else {
            return NotchGeometry(closedSize: pillClosedSize, isPhysicalNotch: false)
        }
        return forScreen(screen)
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        guard screen.safeAreaInsets.top > 0 else {
            return NotchGeometry(closedSize: pillClosedSize, isPhysicalNotch: false)
        }

        // Width derived from the menu-bar areas flanking the notch — nil/empty on
        // displays without one, hence the safeAreaInsets check above.
        let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0
        // These are all AppKit point values. Do not impose a model-derived minimum:
        // the camera housing on a 13-inch MacBook Air is legitimately narrower than
        // the 200-point housing on several MacBook Pro models.
        let width = screen.frame.width - leftPadding - rightPadding
        let height = screen.safeAreaInsets.top

        return NotchGeometry(closedSize: CGSize(width: width, height: height), isPhysicalNotch: true)
    }

    /// Picks the screen the overlay should show on. If a display is pinned
    /// (`FaceLockSettings.preferredDisplayID`), it's used only if still connected — no
    /// fallback. Otherwise: the physical notch if any display has one, else the primary screen.
    @MainActor
    static func preferredScreen() -> NSScreen? {
        if let targetID = FaceLockSettings.shared.preferredDisplayID {
            return NSScreen.screens.first { $0.stableDisplayID == targetID }
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

extension NSScreen {
    /// Stable enough to persist a user's display choice across launches — the only
    /// per-display identity AppKit exposes.
    var stableDisplayID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return String(number)
    }

    /// True for the Mac's own display (vs. an external monitor) — used to pin the Face
    /// Unlock panel there while the built-in camera is selected.
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(number) != 0
    }
}


/// v494: the face scan notch's own closing motion. It is `NotchMotion.close` and `NotchMotion.contentOut` made
/// `NotchGeometry.collapseSpeedFactor` times faster (10%), so only this notch changes speed when it collapses.
@MainActor
enum FaceScanMotion {
    private static let factor = NotchGeometry.collapseSpeedFactor

    /// The shape folding back into the closed notch (same damping as `NotchMotion.close`, a shorter response).
    static var close: Animation {
        NotchMotion.reduced
            ? .easeInOut(duration: 0.18 / factor)
            : .spring(response: 0.4 / factor, dampingFraction: 0.96)
    }

    /// The lock and the video leaving the inline (Minimal) scan.
    static var contentOut: Animation {
        NotchMotion.reduced
            ? .easeInOut(duration: 0.18 / factor)
            : .easeOut(duration: 0.16 / factor)
    }
}
