import SwiftUI
import AppKit

// MARK: - Switches (set to false to undo that point)
nonisolated enum AnimationFlagsB {
    static let relockClose = false       // B2  re-lock: lock closes as the cover appears
    static let passwordShake = true     // B3  wrong password: field shakes + red border
    static let haptics = true           // B4  trackpad tick on success / failure
    static let softBlurIn = true        // B5  blur eases in over 0.3 s
    static let lockFloat = false         // B6  lock glyph floats gently with a color glow
    static let passwordExpand = true    // B7  password field springs out of the pill
    static let successWash = false       // B9  color ripple on notch success
    static let ringLight = true         // B13 face not seen for 3 s: white light border around the screen
    // B11 Reduce Motion is automatic and cannot be switched off.
}

// MARK: - B4
enum FaceLockHaptics {
    /// Extra taps right after the first one make the feedback feel stronger.
    @MainActor private static func burst(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        Task { @MainActor in
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(70))
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        }
    }
    @MainActor static func success() {
        guard AnimationFlagsB.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now); burst(.levelChange)
    }
    @MainActor static func failure() {
        guard AnimationFlagsB.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now); burst(.generic)
    }
}

// MARK: - B3
struct FieldShake: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if AnimationFlagsB.passwordShake && !reduceMotion {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: count) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-8, duration: 0.06)
                    LinearKeyframe(8, duration: 0.06)
                    LinearKeyframe(-6, duration: 0.06)
                    LinearKeyframe(5, duration: 0.06)
                    LinearKeyframe(0, duration: 0.06)
                }
            }
        } else { content }
    }
}

// MARK: - B6
struct LockFloat: ViewModifier {
    @AppStorage("faceLockAnimationColor") private var colorRaw: String = "blue"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if AnimationFlagsB.lockFloat && !reduceMotion {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                content
                    .offset(y: CGFloat(sin(t * 2 * Double.pi / 3.2)) * 2.5)
                    .shadow(color: AnimationTheme.color(for: colorRaw).opacity(0.55), radius: 10)
            }
        } else { content }
    }
}

// MARK: - B9
struct SuccessWash: View {
    let isSuccess: Bool
    @AppStorage("faceLockAnimationColor") private var colorRaw: String = "blue"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grow = false
    @State private var fade = false
    var body: some View {
        if AnimationFlagsB.successWash && !reduceMotion {
            Circle()
                .fill(AnimationTheme.color(for: colorRaw))
                .scaleEffect(grow ? 3 : 0.1)
                .opacity(fade ? 0 : 0.45)
                .allowsHitTesting(false)
                .opacity(isSuccess || grow ? 1 : 0)
                .onChange(of: isSuccess) { _, now in
                    guard now else { grow = false; fade = false; return }
                    grow = false; fade = false
                    withAnimation(.easeOut(duration: Motion.slow)) { grow = true }
                    withAnimation(.easeIn(duration: Motion.slow)) { fade = true }
                }
        }
    }
}
