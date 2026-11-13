import SwiftUI

/// Large version of the notch visualizer for the lock screen. It follows the same Settings choice
/// (waveform or vibrating circle), the same accent colour and the same audio levels as the notch.
/// When no live audio is arriving (or the style is "None") it falls back to the same gentle animation.
struct LockVisualizer: View {
    let level: SmoothedLevel
    let playing: Bool
    /// False while the view is not shown: the animation pauses.
    let active: Bool
    let tint: Color
    @AppStorage(Preferences.visualizerStyleKey) private var style = "waveform"
    @State private var envelope = VisualizerEnvelope()
    @State private var lingering = false
    @State private var lingerToken = 0
    @State private var gain = AutoGain()

    /// Always white, so the shape stays readable on any song's gradient.
    private var shape: Color { .white }

    private var paused: Bool { !(active && (playing || lingering)) }

    var body: some View {
        ZStack {
            // Soft light in the accent colour behind the shape.
            GeometryReader { geo in
                RadialGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0)],
                               center: .center,
                               startRadius: 0,
                               endRadius: max(min(geo.size.width, geo.size.height) / 2, 1))
            }
                .opacity(playing ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.9), value: playing)
            if style == "circle" {
                circle
            } else {
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

    // MARK: - Waveform

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let env = envelope.advance(to: t, target: playing ? 1 : 0)
            let reading = level.read()
            let live = reading.live && level.isFresh()
            let base = live ? gain.normalize(Double(reading.level), at: t) : 0.45 + 0.35 * abs(sin(t * 1.7))
            Canvas { canvas, area in
                let count = 19
                let barWidth: CGFloat = 12
                let spacing: CGFloat = 9
                let total = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
                let startX = (area.width - total) / 2
                let midY = area.height / 2
                let rest: CGFloat = 12
                let tallest = area.height * 0.62
                for index in 0..<count {
                    // Taller in the middle, shorter towards the sides.
                    let x = Double(index) / Double(count - 1) * 2 - 1
                    let bell = 0.38 + 0.62 * (1 - x * x)
                    let wave = 0.35 + 0.65 * abs(sin(t * 5.1 + Double(index) * 0.9))
                    let amount = min(max(base * wave * 1.3 * bell, 0.06), 1)
                    let height = rest + (tallest - rest) * CGFloat(amount) * CGFloat(env)
                    let rect = CGRect(x: startX + CGFloat(index) * (barWidth + spacing),
                                      y: midY - height / 2,
                                      width: barWidth,
                                      height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                with: .color(shape.opacity(0.5 + 0.47 * env)))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 8)
        }
    }

    // MARK: - Vibrating circle

    private var circle: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let env = envelope.advance(to: t, target: playing ? 1 : 0)
            let reading = level.read()
            let live = reading.live && level.isFresh()
            let fallback = 0.3 + 0.4 * abs(sin(t * 2.6)) * abs(sin(t * 0.9 + 1))
            let raw = live ? gain.normalize(Double(reading.level), at: t) : fallback
            // Same range compression as the notch: quiet passages still move, loud ones hit hard.
            let loudness = min(pow(max(raw, 0), 0.55) * 1.3, 1)
            let kick = live ? min(Double(level.readPunch()) * 2.4, 1) : 0
            Canvas { canvas, area in
                let center = CGPoint(x: area.width / 2, y: area.height / 2)
                // The ring itself never changes size; only the waves around it move.
                let radius = min(area.width, area.height) / 2 * 0.68
                let ring = Path(ellipseIn: CGRect(x: center.x - radius,
                                                  y: center.y - radius,
                                                  width: radius * 2,
                                                  height: radius * 2))
                canvas.stroke(ring, with: .color(shape.opacity((0.12 + 0.08 * env))), lineWidth: 12)
                canvas.stroke(ring, with: .color(shape.opacity(0.6 + 0.4 * env)), lineWidth: 3)
                guard env > 0.003 else { return }
                let amplitude = (0.04 + 0.20 * loudness + 0.12 * kick) * env
                for loop in 0..<3 {
                    let phase = t * (1.9 + Double(loop) * 0.6) + Double(loop) * 2.1
                    var path = Path()
                    let steps = 120
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
                    let strength = (0.75 - 0.18 * Double(loop)) * env
                    canvas.stroke(path, with: .color(shape.opacity(strength * 0.14)), lineWidth: 9)
                    canvas.stroke(path, with: .color(shape.opacity(strength)),
                                  style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 8)
        }
    }
}

/// Quiet songs would barely move the shape: the loudness is scaled by a slowly falling peak, so every song
/// uses the full height.
final class AutoGain {
    private var peak = 0.2
    private var lastTime = 0.0

    func normalize(_ value: Double, at time: Double) -> Double {
        let dt = lastTime == 0 ? 0 : min(max(time - lastTime, 0), 0.1)
        lastTime = time
        peak = max(value, peak - peak * 0.25 * dt, 0.12)
        return min(value / peak, 1)
    }
}
