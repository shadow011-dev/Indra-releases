import SwiftUI

/// v429: the level of the volume / brightness bar as a number ("62%"), for every place the inline bar is drawn (beside the
/// closed notch, hanging below it with the Calm animation, and under the open notch). Whether it shows, how big it is and
/// where it sits are chosen in Settings > Volume & Brightness > Percentage.
extension Notification.Name {
    /// Posted by the "Show now" button of the percentage settings: the closed notch plays a volume bar at 62 %.
    static let indraHUDPreview = Notification.Name("indraHUDPreview")
}

/// The number itself. Size and fine position come from Settings; it counts smoothly as the level moves.
struct InlinePercentText: View {
    let value: Double
    let tint: Color
    /// v438: fixed (they were sliders in Settings): 11 pt, and 4 pt of room between the number and the bar.
    /// v491: 15 % smaller (9.35 pt).
    private let size = 11.0 * 0.85
    private let nudgeX = 4.0
    private let nudgeY = 0.0

    var body: some View {
        let level = min(max(value, 0), 1) * 100
        Text("\(Int(level.rounded()))%")
            .font(.system(size: CGFloat(min(max(size, 7), 18)), weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.92))
            .shadow(color: tint.opacity(0.35), radius: 3)
            .contentTransition(.numericText(value: level))
            .animation(.easeOut(duration: 0.16), value: Int(level.rounded()))
            .fixedSize()
            .offset(x: CGFloat(nudgeX), y: CGFloat(nudgeY))
    }
}

/// The inline bar with the number placed where Settings says. With the number off it is just the bar.
struct InlineHUDLevel: View {
    let value: Double
    let tint: Color
    /// Width of the bar when the number is not beside it.
    var barWidth: CGFloat = 73
    @AppStorage(Preferences.sensoryPercentKey) private var showsPercent = false
    /// v467: the number always sits beside the bar (the Position setting is gone).
    private let place = "bar"

    var body: some View {
        if showsPercent && place == "above" {
            VStack(spacing: 2) {
                InlinePercentText(value: value, tint: tint)
                HUDBar(value: value, tint: tint, width: barWidth)
            }
        } else if showsPercent && place == "bar" {
            // The number sits to the RIGHT of the bar.
            // v479: 4 pt less bar, so "100%" has room inside the slot even at its widest.
            // v517: 10 pt between the bar and the number (it was 6, and the bar's extra length made them touch).
            HStack(spacing: 10) {
                HUDBar(value: value, tint: tint, width: max(barWidth - 44, 30))
                InlinePercentText(value: value, tint: tint)
            }
        } else {
            HUDBar(value: value, tint: tint, width: barWidth)
        }
    }
}

/// v464: the HUD's symbol drawn by level. The sun is drawn here (a disc with eight rays): the rays grow longer and brighter
/// with the brightness, from nothing to full length. The speaker is the system's 1, 2 and 3 wave symbols, picked by the
/// volume (no bounce); muted shows the slashed speaker. Every symbol sits in a cell of the same width, centred, so the
/// muted and the normal speaker are drawn on the same spot.
struct HUDSymbol: View {
    let symbol: String
    let value: Double
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold

    private var isSun: Bool { symbol == "display" || symbol.hasPrefix("sun.max") }
    private var isSpeaker: Bool { symbol.hasPrefix("speaker") }
    private var isMuted: Bool { symbol.hasPrefix("speaker.slash") }

    var body: some View {
        Group {
            if isSun {
                HUDSun(level: min(max(value, 0), 1))
                    .frame(width: size * 1.3, height: size * 1.3)
            } else if isSpeaker {
                // v466: the speaker stays as it is; its waves are added or removed with the volume (muted: none, and a slash).
                HUDSpeaker(level: isMuted ? 0 : min(max(value, 0), 1), slash: isMuted ? 1 : 0)
                    .frame(width: size * 1.3, height: size * 1.3)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size * 1.5, height: size * 1.3, alignment: .center)
    }
}

/// A speaker drawn here: the cone stays, and its three waves appear one after the other as the volume rises (and go the
/// same way as it falls), each fading in and out. Muted: no waves and a slash that draws itself across.
struct HUDSpeaker: View, Animatable {
    var level: Double
    var slash: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, slash) }
        set { level = newValue.first; slash = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            let u = min(size.width, size.height)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (size.width - u) / 2 + CGFloat(x) * u, y: (size.height - u) / 2 + CGFloat(y) * u)
            }
            var body = Path()
            body.move(to: point(0.06, 0.38))
            body.addLine(to: point(0.22, 0.38))
            body.addLine(to: point(0.44, 0.19))
            body.addLine(to: point(0.44, 0.81))
            body.addLine(to: point(0.22, 0.62))
            body.addLine(to: point(0.06, 0.62))
            body.closeSubpath()
            context.fill(body, with: .foreground)
            context.stroke(body, with: .foreground, style: StrokeStyle(lineWidth: u * 0.06, lineJoin: .round))

            let origin = point(0.44, 0.5)
            let radii = [0.19, 0.32, 0.45]
            for (index, radius) in radii.enumerated() {
                let shown = min(max((level - Double(index) / 3) * 6, 0), 1)
                guard shown > 0 else { continue }
                var arc = Path()
                arc.addArc(center: origin, radius: CGFloat(radius) * u,
                           startAngle: .degrees(-42), endAngle: .degrees(42), clockwise: false)
                var layer = context
                layer.opacity = shown
                layer.stroke(arc, with: .foreground, style: StrokeStyle(lineWidth: u * 0.075, lineCap: .round))
            }

            if slash > 0 {
                let from = point(0.12, 0.14), to = point(0.9, 0.86)
                var line = Path()
                line.move(to: from)
                line.addLine(to: CGPoint(x: from.x + (to.x - from.x) * CGFloat(slash), y: from.y + (to.y - from.y) * CGFloat(slash)))
                var layer = context
                layer.opacity = slash
                layer.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: u * 0.08, lineCap: .round))
            }
        }
    }
}

/// A sun whose rays grow with `level` (animated frame by frame, so they glide as the brightness changes).
struct HUDSun: View, Animatable {
    var level: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let core = unit * 0.20
            let gap = unit * 0.10
            let longest = unit * 0.17
            context.fill(Path(ellipseIn: CGRect(x: centre.x - core, y: centre.y - core, width: core * 2, height: core * 2)),
                         with: .foreground)
            let length = longest * (0.12 + 0.88 * level)
            context.opacity = 0.35 + 0.65 * level
            for index in 0..<8 {
                // The rays turn with the slider: half a turn from the lowest to the highest level.
                let angle = Double(index) * Double.pi / 4 + level * Double.pi
                let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
                var ray = Path()
                ray.move(to: CGPoint(x: centre.x + dx * (core + gap), y: centre.y + dy * (core + gap)))
                ray.addLine(to: CGPoint(x: centre.x + dx * (core + gap + length), y: centre.y + dy * (core + gap + length)))
                context.stroke(ray, with: .foreground,
                               style: StrokeStyle(lineWidth: unit * 0.075, lineCap: .round))
            }
        }
    }
}

/// The icon, and (when the number sits beside the icon) the number after it.
struct InlineHUDIcon: View {
    let symbol: String
    let value: Double
    let tint: Color
    var fontSize: CGFloat = 14
    @AppStorage(Preferences.sensoryPercentKey) private var showsPercent = false
    /// v467: the number always sits beside the bar (the Position setting is gone).
    private let place = "bar"

    var body: some View {
        HStack(spacing: 5) {
            HUDSymbol(symbol: symbol, value: value, size: fontSize)
                .foregroundStyle(tint)
                .animation(.easeOut(duration: 0.18), value: value)
                .animation(.easeOut(duration: 0.22), value: symbol)
            if showsPercent && place == "icon" {
                InlinePercentText(value: value, tint: tint)
            }
        }
    }
}
