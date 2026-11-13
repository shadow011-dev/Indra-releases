import AVFAudio
import SwiftUI

/// Smoothed loudness of the system audio (fast attack, slow decay). Thread-safe.
final class SmoothedLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    private var live = false
    private var slow: Float = 0
    private var punch: Float = 0
    private var lastUpdate = Date.distantPast

    /// True while audio buffers are still arriving (the capture can stall, for example on the lock screen).
    func isFresh(within seconds: TimeInterval = 1.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastUpdate) < seconds
    }

    func update(peak: Float) {
        lock.lock()
        lastUpdate = Date()
        value = max(peak, value * 0.8)
        // Beat detector: how far the loudness jumped above its slow average.
        slow = slow * 0.96 + peak * 0.04
        punch = max(max(peak - slow, 0), punch * 0.75)
        lock.unlock()
    }

    /// Short-lived spike on beats / loud hits (0...1).
    func readPunch() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return punch
    }

    func setLive(_ isLive: Bool) {
        lock.lock()
        live = isLive
        if !isLive {
            value = 0
            slow = 0
            punch = 0
        }
        lock.unlock()
    }

    /// `live` is true while real audio is being measured.
    func read() -> (level: Float, live: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (value, live)
    }
}

/// Drives the visualizers while music plays. It no longer records system audio (that needs the
/// "Screen & System Audio Recording" permission and makes macOS show its screen-sharing indicator),
/// so the visualizers use their own gentle, lively animation.
@MainActor
final class AudioLevelMonitor {
    let level = SmoothedLevel()

    func setActive(_ on: Bool) {
        level.setLive(false)
    }
}

/// Eases the visualizer between "playing" and "stopped" so waves relax instead of snapping.
final class VisualizerEnvelope {
    private(set) var value = 0.0
    private var lastTime = 0.0

    func advance(to time: Double, target: Double) -> Double {
        // v483: a view that is rebuilt while the music plays (the notch is rebuilt after every desktop change) starts at its
        // target instead of easing up from zero, which made the waveform and the circle collapse and flicker.
        if lastTime == 0 { value = target }
        let dt = lastTime == 0 ? 0 : min(max(time - lastTime, 0), 0.1)
        lastTime = time
        let rate = target > value ? 7.0 : 1.8
        value += (target - value) * (1 - exp(-rate * dt))
        if target == 0, value < 0.002 { value = 0 }
        return value
    }
}

/// None / waveform / vibrating circle, chosen in Settings.
struct VisualizerView: View {
    let level: SmoothedLevel
    let playing: Bool
    /// False while the view is not visible: the animation pauses.
    let active: Bool
    var compact = false
    var tint: Color = Color.white
    /// v440: the album's own colours, left to right. When set, the waveform's bars and the circle's lines are drawn in
    /// this gradient instead of one colour.
    var gradient: [Color]? = nil
    @AppStorage(Preferences.visualizerStyleKey) private var mainStyle = "waveform"
    @AppStorage(Preferences.islandVisualizerStyleKey) private var islandStyle = ""
    @Environment(\.notchIsland) private var island
    @State private var envelope = VisualizerEnvelope()
    /// Keeps the animation running for a moment after playback stops, while the waves relax.
    @State private var lingering = false
    @State private var lingerToken = 0

    private var style: String { Preferences.pick(mainStyle, islandStyle, island: island) }

    var body: some View {
        Group {
            switch style {
            case "none":
                EmptyView()
            case "circle":
                circle
            default:
                waveform
            }
        }
        .onChange(of: playing) { _, isPlaying in
            guard !isPlaying else { return }
            lingering = true
            // v419: an older pause's timer must not end the linger of a newer pause early.
            lingerToken += 1
            let mine = lingerToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                if mine == lingerToken { lingering = false }
            }
        }
    }

    // v507: the compact waveform snaps its bars to whole points, so 24 frames a second show every change it can make.
    private var interval: Double { compact ? 1.0 / 24.0 : 1.0 / 30.0 }
    private var paused: Bool { !(active && (playing || lingering)) }

    // MARK: - Waveform

    /// v454: the closed notch's waveform, measured from the reference recording (at 2x): five bars, each 2 pt wide with
    /// 1.5 pt between them, 2 pt tall at rest and up to 12 pt tall, always whole points tall and centred on the row.
    /// Every bar moves on its own (periods between about 0.5 and 0.9 s, no travelling wave) and uses the whole range.
    private static let compactPeriods: [Double] = [0.78, 0.52, 0.77, 0.91, 0.62]
    private static let compactPhases: [Double] = [0.0, 1.9, 3.7, 5.1, 0.8]

    /// 0...1: where bar `index` is between its smallest and its tallest height at time `t`.
    private func compactAmount(index: Int, t: Double) -> Double {
        let i = index % Self.compactPeriods.count
        let period = Self.compactPeriods[i]
        let main = sin(2 * Double.pi * t / period + Self.compactPhases[i])
        let slow = sin(2 * Double.pi * t / (period * 1.9) + Self.compactPhases[(i + 2) % Self.compactPhases.count] * 1.3)
        return min(max(0.5 + 0.5 * (0.72 * main + 0.28 * slow) * 1.12, 0), 1)
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let env = envelope.advance(to: t, target: playing ? 1 : 0)
            let reading = level.read()
            let base = reading.live ? Double(reading.level) : 0.45 + 0.35 * abs(sin(t * 1.7))
            let count = compact ? 5 : 7
            // v436: whole-point bar width and gap, so every bar (the middle one too) is snapped to the pixels the same way.
            HStack(spacing: compact ? 1.5 : 3) {
                ForEach(0..<count, id: \.self) { index in
                    let rest: Double = 2
                    let height: Double = {
                        if compact {
                            // Reference: 2 ... 12 pt; the real loudness (when measured) scales how far the bars reach.
                            let reach = reading.live ? min(max(base * 1.3, 0.35), 1) : 1
                            let live = 2 + 10 * compactAmount(index: index, t: t) * reach
                            return (rest + (live - rest) * env).rounded()
                        }
                        let wave = 0.35 + 0.65 * abs(sin(t * 5.1 + Double(index) * 0.9))
                        let amount = min(max(base * wave * 1.3, 0.08), 1)
                        let regularRest: Double = 3
                        let live = 4 + amount * 16
                        return regularRest + (live - regularRest) * env
                    }()
                    Capsule()
                        .fill(barColor(index: index, count: count).opacity(0.35 + 0.57 * env))
                        .frame(width: 2, height: height)
                }
            }
            .frame(height: compact ? 12 : 22)
        }
    }

    /// One colour per bar, taken along the album gradient (the plain tint when there is none).
    private func barColor(index: Int, count: Int) -> Color {
        guard let gradient, gradient.count > 1, count > 1 else { return tint }
        return ArtworkPalette.sample(gradient, at: Double(index) / Double(count - 1))
    }

    /// The circle's lines: the album gradient laid across the circle (the plain tint when there is none).
    private func ringStyle(opacity: Double) -> AnyShapeStyle {
        guard let gradient, gradient.count > 1 else { return AnyShapeStyle(tint.opacity(opacity)) }
        return AnyShapeStyle(LinearGradient(colors: gradient.map { $0.opacity(opacity) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing))
    }

    // MARK: - Vibrating circle

    private var circle: some View {
        let size: CGFloat = compact ? 30 : 38
        // v507: 30 frames a second (was 60): the circle is 30 pt wide, so the extra frames cost twice the CPU and showed nothing.
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let env = envelope.advance(to: t, target: playing ? 1 : 0)
            let reading = level.read()
            let fallback = 0.3 + 0.4 * abs(sin(t * 2.6)) * abs(sin(t * 0.9 + 1))
            let raw = reading.live ? Double(reading.level) : fallback
            // Compress the range so quiet passages still move and loud ones hit hard.
            let loudness = min(pow(max(raw, 0), 0.55) * 1.3, 1)
            let kick = reading.live ? min(Double(level.readPunch()) * 2.4, 1) : 0
            // When the music stops, the waves flatten out slowly until only the circle is left.
            let amplitude = (0.04 + 0.20 * loudness + 0.12 * kick) * env
            // Plain vector shapes (no drawing surface), so nothing is painted behind the circle.
            ZStack {
                Circle()
                    .stroke(ringStyle(opacity: 0.5 + 0.45 * env), lineWidth: 1.4)
                    .frame(width: size * 0.8, height: size * 0.8)
                if env > 0.003 {
                    ForEach(0..<3, id: \.self) { loop in
                        WobbleShape(amplitude: amplitude,
                                    phase: t * (1.9 + Double(loop) * 0.6) + Double(loop) * 2.1,
                                    kick: kick)
                            .stroke(ringStyle(opacity: (0.75 - 0.18 * Double(loop)) * env), lineWidth: 1.0)
                            .frame(width: size * 0.8, height: size * 0.8)
                    }
                }
            }
            .frame(width: size, height: size)
        }
    }
}

/// A circle whose outline ripples (used for the vibrating circle visualizer).
private struct WobbleShape: Shape {
    var amplitude: Double
    var phase: Double
    var kick: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 48   // v507: was 72; at 24 pt across the difference cannot be seen
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * Double.pi
            let wobble = amplitude * (0.55 * sin(3 * angle + phase)
                                      + 0.35 * sin(5 * angle - phase * 1.3)
                                      + (0.2 + 0.4 * kick) * sin(9 * angle + phase * 2.2))
            let r = radius * (1 + wobble)
            let point = CGPoint(x: center.x + CGFloat(cos(angle) * r),
                                y: center.y + CGFloat(sin(angle) * r))
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
