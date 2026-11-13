import AppKit
import SwiftUI

/// Every animation value for the notch lives here, so tuning touches one file.
@MainActor
enum NotchMotion {
    /// macOS "Reduce motion" (System Settings > Accessibility > Display): springs, bounces, scaling and blur give way
    /// to short fades, everywhere the notch animates through this file.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static var fade: Animation { .easeInOut(duration: 0.18) }

    /// Shape growth. Slight overshoot on open, no bounce on close.
    static var open: Animation { reduced ? fade : .spring(response: 0.48, dampingFraction: 0.8) }
    static var close: Animation { reduced ? fade : .spring(response: 0.4, dampingFraction: 0.96) }
    /// Opening after the hover duration (Settings): the notch has already swelled while waiting, so it flows on from
    /// there with a longer, softer spring and almost no overshoot.
    static var hoverOpen: Animation { reduced ? fade : .spring(response: 0.58, dampingFraction: 0.92) }

    /// Notch resizing while open (e.g. Mirror on/off).
    static var resize: Animation { reduced ? fade : .smooth(duration: 0.5) }

    /// Notch morphing to and from the camera Mirror: a touch of life, no wobble.
    static var mirror: Animation { reduced ? fade : .spring(response: 0.52, dampingFraction: 0.86) }

    /// Page changes (player <-> calendar).
    static var page: Animation { reduced ? fade : .smooth(duration: 0.46) }

    /// Closed notch widening / narrowing for volume, brightness, battery and lock activities.
    static var hudOpen: Animation { reduced ? fade : .spring(response: 0.38, dampingFraction: 0.72) }
    /// v439: critically damped (1.0, was 0.92). A card that folds back into the closed notch must never overshoot, or the
    /// body goes narrower / shorter than the closed notch for a moment and the camera housing shows beside it.
    static var hudClose: Animation { reduced ? fade : .spring(response: 0.34, dampingFraction: 1.0) }

    /// Weather / To-Do / Calendar pages: same blur-and-scale reveal as the notch opening.
    static var reveal: Animation { reduced ? fade : .spring(response: 0.38, dampingFraction: 0.9) }

    /// Content reveal: scales up from the top while the blur clears.
    static var contentIn: Animation { reduced ? fade : .spring(response: 0.42, dampingFraction: 0.9).delay(0.06) }
    static var contentOut: Animation { reduced ? fade : .easeOut(duration: 0.16) }
    /// A page change (player / calendar / tray / clipboard / focus). The page that leaves clears away quickly and the
    /// one that arrives follows a moment later, so the two are never seen on top of each other (that double image
    /// was the abrupt, muddy part of the old crossfade, where both used one and the same spring).
    /// The notch's own size and corner curves are not touched here; only the content moves.
    static func pageTransition(move: CGSize) -> AnyTransition {
        let reveal = move.height == 0
        let arrive: Animation = reduced ? fade
            : (reveal ? .spring(response: 0.44, dampingFraction: 0.88).delay(0.07)
                      : .spring(response: 0.5, dampingFraction: 0.9).delay(0.07))
        let leave: Animation = reduced ? fade : .easeOut(duration: 0.15)
        return .asymmetric(insertion: AnyTransition(PageSlide(move: move)).animation(arrive),
                           removal: AnyTransition(PageSlide(move: move)).animation(leave))
    }

    /// Lists (to-dos, reminders): rows insert, finish and delete with a short, settled spring.
    static var list: Animation { reduced ? fade : .spring(response: 0.35, dampingFraction: 0.8) }
    static var listRow: Animation { reduced ? fade : .spring(response: 0.38, dampingFraction: 0.82) }
    static var tap: Animation { reduced ? fade : .spring(response: 0.3, dampingFraction: 0.7) }
    /// Queue / playlist changes in the player.
    static var queue: Animation { reduced ? fade : .spring(response: 0.5, dampingFraction: 0.82) }
    /// True when endless looping effects (breathing, pulsing) should stand still.
    static var stillLoops: Bool { reduced }

    /// Opacity of the open notch's content while the notch is closed (see NotchRootView).
    static let restingOpacity: Double = 0.01
    static var hiddenScale: CGFloat { reduced ? 1 : 0.90 }
    static var hiddenBlur: CGFloat { reduced ? 0 : 16 }
    /// v439: the blur on the open page's content is recomputed on every frame of every opening and closing. On the external
    /// monitor's notch (a second window, often on a 60 Hz or scaled display) that was the costliest layer of the animation and
    /// the main source of its lag, so there the page only scales and fades. The MacBook's own notch is unchanged.
    static func hiddenBlur(external: Bool) -> CGFloat { external ? 0 : hiddenBlur }

    /// v439: the external notch switching between the island and the MacBook-notch look (Settings > External Notch > Style).
    /// The old look shrinks towards the top edge and fades, the geometry changes while nothing is visible, and the new look
    /// grows out of the top edge. Nothing is ever resized in view.
    static var lookOut: Animation { reduced ? fade : .easeIn(duration: 0.17) }
    static var lookIn: Animation { reduced ? fade : .spring(response: 0.46, dampingFraction: 0.84) }
    static var lookHiddenScale: CGFloat { reduced ? 1 : 0.8 }
}
