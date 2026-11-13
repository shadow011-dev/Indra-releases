import SwiftUI

// MARK: - Switches
// Set one to false to switch that piece off; the app then behaves exactly as it did before it.
nonisolated enum AnimationFlags {
    static let failureShake = false          // 1  failed scan: shake + red pulse
    static let scanningGlow = false          // 2  scanning: breathing glow ring + sweeping scan line
    static let successDissolve = true       // 3  success: lock opens, blur dissolves over 0.35 s
    static let blurScreenEntrance = true    // 4  blur screen: fade/spring in, staggered buttons
    static let consistentTiming = true      // 5  one shared set of durations
}

// MARK: - Shared durations (point 5)
nonisolated enum Motion {
    static let fast: Double = 0.22
    static let base: Double = 0.45
    static let slow: Double = 0.65
}

// MARK: - Theme color from the chosen animation color
enum AnimationTheme {
    static func color(for raw: String) -> Color {
        switch raw {
        case "purple": return Color(nsColor: .systemPurple)
        case "pink": return Color(nsColor: .systemPink)
        case "red": return Color(nsColor: .systemRed)
        case "orange": return Color(nsColor: .systemOrange)
        case "yellow": return Color(nsColor: .systemYellow)
        case "green": return Color(nsColor: .systemGreen)
        case "graphite": return Color(nsColor: .systemGray)
        case "custom": return CustomColor.color
        default: return Color(nsColor: .systemBlue)
        }
    }
}

// MARK: - 1  Failed scan: quick shake + short red pulse
struct FailureShake: ViewModifier {
    let isFailing: Bool
    @State private var offsetX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: AnimationFlags.failureShake ? offsetX : 0)
            .onChange(of: isFailing) { _, failing in
                guard failing, AnimationFlags.failureShake else { return }
                Task { @MainActor in
                    for x in [CGFloat(-8), 8, -6, 5, -3, 0] {
                        withAnimation(.easeInOut(duration: 0.06)) { offsetX = x }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
            }
    }
}

struct FailureFlash: View {
    let isFailing: Bool
    @State private var opacity: Double = 0

    var body: some View {
        Color.red
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: isFailing) { _, failing in
                guard failing, AnimationFlags.failureShake else { return }
                withAnimation(.easeOut(duration: 0.12)) { opacity = 0.45 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeInOut(duration: Motion.base)) { opacity = 0 }
                }
            }
    }
}

// MARK: - 2  Scanning: breathing glow ring in the chosen color + a scan line sweeping across
struct ScanningGlow: View {
    let isActive: Bool
    @AppStorage("faceLockAnimationColor") private var colorRaw: String = "blue"

    var body: some View {
        if AnimationFlags.scanningGlow && isActive {
            let tint = AnimationTheme.color(for: colorRaw)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(t * 2 * Double.pi / 1.8)
                let progress = t.truncatingRemainder(dividingBy: 2.2) / 2.2
                GeometryReader { geo in
                    ZStack(alignment: .top) {
                        Rectangle()
                            .strokeBorder(tint.opacity(0.22 + 0.4 * pulse), lineWidth: 3)
                            .blur(radius: 5)
                        LinearGradient(
                            colors: [tint.opacity(0), tint.opacity(0.5), tint.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: 2)
                        .offset(y: geo.size.height * progress)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 4  Blur screen: staggered spring entrance
struct StaggeredEntrance: ViewModifier {
    let appeared: Bool
    var delay: Double = 0
    var startScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if AnimationFlags.blurScreenEntrance && !reduceMotion {
            content
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 120)
                .scaleEffect(appeared ? 1 : startScale)
                .animation(.spring(response: Motion.slow, dampingFraction: 0.78).delay(delay), value: appeared)
        } else {
            content
        }
    }
}
