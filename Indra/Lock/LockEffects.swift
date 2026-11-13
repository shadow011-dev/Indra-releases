import SwiftUI

/// Switches for the lock screen animation ideas. The numbers match the list the user got.
/// "undo N" = set that switch to false (and the code for it can then be deleted).
enum LockFX {
    static let coverBloom = false   // 1  colours wash out of the new cover into the gradient
    static let coverGlow = false    // 2  breathing light under the cover
    static let pauseSettle = true   // 3  the cover sets down when paused
    static let cardTilt = false     // 4  the card leans toward the pointer
    static let lyricDepth = true    // 6  lines curve away in depth
    static let breakDots = true     // 7  dots that fill during instrumental breaks
    static let hueDrift = true      // 8  gradient hue follows the song's progress
    static let clockSheen = true    // 9  clock tinted by the album, with a sheen
    static let bassPulse = true     // 10 the gradient brightens a little on beats
}

// MARK: - 1: cover bloom

/// When the song (and so the artwork) changes, the new cover's colour spreads outward from the cover.
struct CoverBloom: View {
    let trigger: Int
    let color: Color
    let center: CGPoint
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let diameter = max(geo.size.width, geo.size.height) * 1.6
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.3), color.opacity(0)],
                                     center: .center,
                                     startRadius: 0,
                                     endRadius: diameter / 2))
                .frame(width: diameter, height: diameter)
                .scaleEffect(0.12 + 0.88 * progress)
                .opacity(Double(1 - progress) * 0.7)
                .position(center)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            progress = 0
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                withAnimation(.easeOut(duration: 1.8)) { progress = 1 }
            }
        }
    }
}

// MARK: - 2: light under the cover

struct CoverGlow: View {
    let color: Color
    let playing: Bool
    let center: CGPoint
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = 0.5 + 0.5 * sin(t * 1.1)
            RadialGradient(colors: [color.opacity(playing ? 0.30 + 0.12 * breathe : 0.12), color.opacity(0)],
                           center: .center,
                           startRadius: 0,
                           endRadius: size * 0.95)
                .frame(width: size * 2, height: size * 2)
                .position(center)
        }
        .animation(.easeInOut(duration: 0.6), value: playing)
        .allowsHitTesting(false)
    }
}

// MARK: - 10: bass pulse

final class PulseEnvelope {
    private var value = 0.0
    private var last = 0.0

    func next(_ punch: Double, at time: Double) -> Double {
        let dt = last == 0 ? 0 : min(max(time - last, 0), 0.1)
        last = time
        value = max(min(punch * 2.4, 1), value * exp(-5 * dt))
        return value
    }
}

/// A very small brightening of the whole gradient on strong beats (at most 3%).
struct BassPulse: View {
    let levels: SmoothedLevel
    let playing: Bool
    @State private var envelope = PulseEnvelope()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            let value = envelope.next(Double(levels.readPunch()), at: context.date.timeIntervalSinceReferenceDate)
            Color.white.opacity(0.03 * value)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 4: card tilt

/// The card leans a few degrees toward the pointer, with a faint highlight following it.
struct CardTilt: ViewModifier {
    let enabled: Bool
    @State private var size = CGSize(width: 300, height: 150)
    @State private var tiltX = 0.0
    @State private var tiltY = 0.0
    @State private var sheen = UnitPoint(x: 0.5, y: 0.3)
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(enabled ? tiltX : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(enabled ? tiltY : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: tiltX)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: tiltY)
            .animation(.easeOut(duration: 0.2), value: hovering)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { size = geo.size }
                    .onChange(of: geo.size) { _, new in size = new }
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    guard size.width > 1, size.height > 1 else { return }
                    let x = min(max(point.x / size.width, 0), 1)
                    let y = min(max(point.y / size.height, 0), 1)
                    hovering = true
                    tiltY = (x * 2 - 1) * 6
                    tiltX = -(y * 2 - 1) * 5
                    sheen = UnitPoint(x: x, y: y)
                case .ended:
                    hovering = false
                    tiltX = 0
                    tiltY = 0
                }
            }
    }
}

// MARK: - 9: clock tinted by the album, with a sheen

struct SolidClock: View {
    let text: String
    let tint: Color
    var font: Font = .system(size: LockClock.timeSize, weight: .bold, design: .rounded)
    /// False for small previews: no travelling sheen.
    var animated = true

    private var ink: Color { LockFX.clockSheen ? Color.white.mix(with: tint, by: 0.28) : Color.white }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(LinearGradient(colors: [ink.opacity(0.98), ink.opacity(0.78)],
                                            startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            .overlay {
                if LockFX.clockSheen && animated {
                    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                        let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 9)
                        let p = cycle < 1.8 ? cycle / 1.8 : 2.0
                        GeometryReader { geo in
                            LinearGradient(colors: [Color.clear, Color.white.opacity(0.6), Color.clear],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                                .frame(width: geo.size.width * 0.4)
                                .offset(x: -geo.size.width * 0.4 + geo.size.width * 1.4 * CGFloat(p))
                        }
                    }
                    .mask(Text(text).font(font))
                    .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Song change without the wallpaper showing through

/// Two gradients on top of each other: the old one stays fully opaque while the new one fades in on top,
/// so there is never a moment where the lock screen wallpaper shows through.
struct CrossfadeBackdrop: View {
    let tones: [Color]
    var progress: (() -> Double)?
    /// True while the backdrop is invisible: the drift stops, nothing is redrawn.
    var paused = false
    /// False while the album photo covers the gradient: a new song then swaps the colours at once, instead of
    /// fading two full-screen gradients over each other for two seconds under the photo's own fade.
    var crossfade = true
    @State private var base: [Color]
    @State private var top: [Color]
    @State private var topOpacity = 1.0
    /// The old gradient is only drawn (and animated) while the new one fades in over it.
    @State private var fading = false
    @State private var fadeToken = 0

    init(tones: [Color], progress: (() -> Double)? = nil, paused: Bool = false, crossfade: Bool = true) {
        self.tones = tones
        self.progress = progress
        self.paused = paused
        self.crossfade = crossfade
        _base = State(initialValue: tones)
        _top = State(initialValue: tones)
    }

    var body: some View {
        ZStack {
            if fading {
                AlbumBackdrop(tones: base, progress: progress, paused: paused)
            }
            AlbumBackdrop(tones: top, progress: progress, paused: paused)
                .opacity(topOpacity)
        }
        .onChange(of: tones) { _, new in
            guard new != top else { return }
            if !crossfade {
                top = new
                base = new
                return
            }
            base = top
            top = new
            fading = true
            topOpacity = 0
            fadeToken += 1
            let token = fadeToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 2.2)) { topOpacity = 1 }
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                if token == fadeToken { fading = false }
            }
        }
    }
}
