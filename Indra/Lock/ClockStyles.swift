import AppKit
import CoreText
import SwiftUI

/// The clock faces of the lock screen. Every face is drawn by hand (no plain system text), so each one looks like
/// it belongs on a dark, glassy lock screen. Older versions saved other names; they map to a new face (see `resolve`).
enum LockClockStyle: String, CaseIterable, Identifiable {
    case aurora     // digits filled with a slow, drifting colour from the album (the default, first in the picker)
    case stack      // hours over minutes, one solid and one outlined (side by side while lyrics are open)
    case groove     // digits cut from vinyl grooves
    case dots       // a glowing LED dot matrix
    case disc       // time on a record label inside a ring of seconds
    case slit       // digits sliced in two, the lower half nudged aside

    var id: String { rawValue }

    static func resolve(_ raw: String) -> LockClockStyle {
        switch raw {
        case "solid", "standard", "rounded", "thin", "bold", "serif", "mono", "glass": return .stack
        case "stencil": return .groove
        case "lines", "outline": return .slit
        default: return LockClockStyle(rawValue: raw) ?? .stack
        }
    }

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .groove: return "Groove"
        case .dots: return "Dots"
        case .stack: return "Stack"
        case .disc: return "Disc"
        case .slit: return "Slit"
        }
    }
}

/// The time in the chosen face. `size` is the digit height class (132 on the lock screen, small in the picker).
struct LockClockFace: View {
    let text: String
    let style: LockClockStyle
    let tint: Color
    var size: CGFloat = LockClock.timeSize
    /// False in the picker previews (no moving light).
    var animated = true
    /// Lyrics are open: the Stack face puts the minutes beside the hours (other faces ignore this).
    var inline = false
    /// True only in the style picker: a frozen sample. On the lock screen the Disc always shows the real seconds,
    /// also while the widget moves (when `animated` is switched off for a moment).
    var preview = false
    /// True while the clock can be seen: a new song's colour then glides in quickly. While it is hidden the colour is
    /// simply set, so nothing is left to play out (and show) when the screen comes back.
    var glide = true

    private var ink: Color { Color.white.mix(with: tint, by: 0.32).opacity(0.96) }

    /// 0 while lyrics are closed, 1 while they are open. Every face morphs between its two looks on one spring
    /// (like Stack does), each in a way that fits how the face is drawn.
    private var focus: CGFloat { inline ? 1 : 0 }

    var body: some View {
        Group {
            switch style {
            case .aurora: AuroraClock(text: text, tint: tint, size: size, animated: animated, focus: focus)
            case .groove: GrooveClock(text: text, ink: ink, size: size, focus: focus)
            case .dots: DotsClock(text: text, ink: ink, size: size, inline: inline)
            case .stack: StackClock(text: text, ink: ink, size: size, inline: inline)
            case .disc: DiscClock(text: text, ink: ink, size: size, preview: preview, focus: focus)
            case .slit: SlitClock(text: text, ink: ink, size: size, focus: focus)
            }
        }
        .animation(.smooth(duration: 0.95), value: inline)
        // A new song's colour glides in quickly with the backdrop instead of jumping a moment after it.
        .animation(glide ? .easeOut(duration: 0.22) : nil, value: AuroraTint.key(tint))
    }
}

/// The Aurora digits take the album colour, brightened so they stay vivid on the dimmed backdrop.
/// The colour is kept as plain numbers so SwiftUI can animate it from one song's colour to the next.
enum AuroraTint {
    static func components(of color: Color) -> (CGFloat, CGFloat, CGFloat) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return (0.62, 0.66, 0.95) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Grey artwork stays grey; coloured artwork gets a little more life and light.
        let boosted = NSColor(hue: hue,
                              saturation: saturation < 0.08 ? saturation : min(1, saturation * 1.12),
                              brightness: max(brightness, 0.8),
                              alpha: 1)
        let rgb = boosted.usingColorSpace(.sRGB) ?? srgb
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    /// Changes whenever the colour does (used to start the colour animation).
    static func key(_ color: Color) -> [Int] {
        let c = components(of: color)
        return [Int((c.0 * 255).rounded()), Int((c.1 * 255).rounded()), Int((c.2 * 255).rounded())]
    }
}

private func heavyLayout(_ text: String, size: CGFloat) -> ClockGlyphs.Layout? {
    ClockGlyphs.layout(text, size: size, weight: .heavy, design: .rounded,
                       widthScale: 0.9, tracking: -size * 0.02)
}

private func fallbackText(_ text: String, size: CGFloat, ink: Color) -> some View {
    Text(text).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundStyle(ink)
}

// MARK: - Aurora

/// The slow drift of the Aurora light, kept as a running clock that only moves while the digits are animated.
/// When the animation rests (a song change, a moving widget) the light stays exactly where it is and carries on
/// from there, instead of jumping to a fixed position and back.
private final class AuroraPhase {
    private var phase: Double = 0
    private var last: Date?

    func value(at date: Date, running: Bool) -> Double {
        if running, let last {
            phase += min(max(date.timeIntervalSince(last), 0), 0.1)
        }
        last = date
        return phase
    }
}

/// Heavy digits filled with a soft colour that slowly drifts across them, with a faint glow in the same colour.
private struct AuroraClock: View, Animatable {
    let text: String
    let size: CGFloat
    let animated: Bool
    /// Lyrics open (1): the filled digits empty out into glowing outlines; closed (0): solid colour again.
    var focus: CGFloat = 0
    /// The album colour, as numbers (so it animates between songs).
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    @State private var phaseClock = AuroraPhase()

    init(text: String, tint: Color, size: CGFloat, animated: Bool, focus: CGFloat = 0) {
        self.text = text
        self.size = size
        self.animated = animated
        self.focus = focus
        let c = AuroraTint.components(of: tint)
        red = c.0
        green = c.1
        blue = c.2
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(focus, AnimatablePair(red, AnimatablePair(green, blue))) }
        set {
            focus = newValue.first
            red = newValue.second.first
            green = newValue.second.second.first
            blue = newValue.second.second.second
        }
    }

    private var tint: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: 1) }

    var body: some View {
        if let layout = heavyLayout(text, size: size) {
            let inset: CGFloat = 10
            let hollow = min(max(focus, 0), 1)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { context in
                let t = phaseClock.value(at: context.date, running: animated)
                let drift = CGFloat((sin(t * 0.3) + 1) / 2)
                let w = layout.size.width
                let h = layout.size.height
                let light = Color.white.mix(with: tint, by: 0.12)
                // v429: the far end of the drift leans towards violet only as far as the cover itself is coloured. A grey
                // or black-and-white cover used to turn blue-violet here, which did not match the cover or the backdrop.
                let spread = max(red, green, blue) - min(red, green, blue)
                let colourful = max(red, green, blue) > 0.001 ? spread / max(red, green, blue) : 0
                let far = tint.mix(with: Color(red: 0.55, green: 0.42, blue: 1.0), by: 0.55 * min(1, Double(colourful) / 0.4))
                let outline = Color.white.mix(with: tint, by: 0.45)
                Canvas { context, _ in
                    context.translateBy(x: inset, y: inset)
                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [light, tint, far]),
                        startPoint: CGPoint(x: w * (drift - 0.35), y: 0),
                        endPoint: CGPoint(x: w * (drift + 0.75), y: h))
                    // Two calm stages: the colour drains out of the fill first, then one clean outline fades in.
                    let fillAmount = 1 - min(hollow / 0.6, 1)
                    let lineAmount = min(max((hollow - 0.35) / 0.65, 0), 1)
                    var fillContext = context
                    fillContext.opacity = Double(fillAmount)
                    for glyph in layout.glyphs {
                        fillContext.fill(glyph.path, with: shading)
                        if lineAmount > 0.01 {
                            context.stroke(glyph.path, with: .color(outline.opacity(Double(lineAmount))),
                                           style: StrokeStyle(lineWidth: max(1.6, size * 0.022), lineJoin: .round))
                        }
                        context.stroke(glyph.path, with: .color(Color.white.opacity(0.35 * Double(fillAmount))),
                                       style: StrokeStyle(lineWidth: max(0.8, size * 0.008), lineJoin: .round))
                    }
                }
                .frame(width: w + inset * 2, height: h + inset * 2)
                .shadow(color: tint.opacity(0.5 - 0.25 * hollow), radius: size * 0.12)
            }
        } else {
            fallbackText(text, size: size, ink: tint)
        }
    }
}

// MARK: - Groove

/// Digits that look cut from a record: fine horizontal grooves, brighter where light would catch them.
private struct GrooveClock: View, Animatable {
    let text: String
    let ink: Color
    let size: CGFloat
    /// Lyrics open (1): the record "starts playing": grooves open up a little and the light band sweeps across them.
    var focus: CGFloat = 0
    var animatableData: CGFloat {
        get { focus }
        set { focus = newValue }
    }

    var body: some View {
        if let layout = heavyLayout(text, size: size) {
            let inset: CGFloat = 6
            let w = layout.size.width
            let h = layout.size.height
            let pitch = max(2.2, size * (0.03 + 0.012 * focus))
            Canvas { context, _ in
                context.translateBy(x: inset, y: inset)
                for glyph in layout.glyphs {
                    context.fill(glyph.path, with: .color(Color.white.opacity(0.1)))
                    context.drawLayer { layer in
                        layer.clip(to: glyph.path)
                        var y: CGFloat = 0
                        var index = 0
                        while y < h {
                            let shine = 0.55 + 0.4 * sin(Double(index) * 0.35 + Double(focus) * 6.0)
                            layer.fill(Path(CGRect(x: 0, y: y, width: w, height: pitch * 0.56)),
                                       with: .color(ink.opacity(shine)))
                            y += pitch
                            index += 1
                        }
                    }
                    context.stroke(glyph.path, with: .color(Color.white.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: max(0.8, size * 0.008), lineJoin: .round))
                }
            }
            .frame(width: w + inset * 2, height: h + inset * 2)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .scaleEffect(1 - 0.1 * focus)
        } else {
            fallbackText(text, size: size, ink: ink)
        }
    }
}

// MARK: - Dots

/// A 5 x 7 LED matrix: lit dots glow, unlit ones stay as a faint grid.
/// When lyrics open or close, the lit dots go out one by one (fast, in a random sparkle), and once the lyrics
/// have appeared they light up again one by one, sweeping from left to right.
private struct DotsClock: View {
    let text: String
    let ink: Color
    let size: CGFloat
    let inline: Bool

    @State private var start = Date.distantPast
    @State private var running = false
    @State private var token = 0
    private static let total: Double = 1.7

    private static let patterns: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ":": ["0", "0", "1", "0", "1", "0", "0"],
    ]

    private var columns: [[Bool]] {
        var result: [[Bool]] = []
        for character in text {
            let key: Character = (character == ".") ? ":" : character
            guard let rows = DotsClock.patterns[key] else { continue }
            if !result.isEmpty { result.append(Array(repeating: false, count: 7)) }
            for column in 0..<rows[0].count {
                result.append(rows.map { Array($0)[column] == "1" })
            }
        }
        return result
    }

    /// A fixed pseudo-random number in 0...1 for every dot, so the sparkle order is the same each time.
    private func scatter(_ x: Int, _ y: Int, _ salt: Double) -> Double {
        let v = sin(Double(x) * 12.9898 + Double(y) * 78.233 + salt) * 43758.5453
        return v - floor(v)
    }

    /// 1 = fully lit, 0 = out. Goes out at a random moment in the first 0.3 s, comes back left to right after 0.65 s.
    private func visibility(x: Int, y: Int, count: Int, t: Double) -> Double {
        let outAt = scatter(x, y, 1) * 0.30
        let inAt = 0.65 + Double(x) / Double(max(count - 1, 1)) * 0.65 + scatter(x, y, 7) * 0.12
        if t < outAt { return 1 }
        if t < outAt + 0.1 { return 1 - (t - outAt) / 0.1 }
        if t < inAt { return 0 }
        if t < inAt + 0.26 {
            let p = (t - inAt) / 0.26
            return p * p * (3 - 2 * p)
        }
        return 1
    }

    private func replay() {
        token += 1
        let mine = token
        start = Date()
        running = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((DotsClock.total + 0.1) * 1_000_000_000))
            if mine == token { running = false }
        }
    }

    var body: some View {
        let cols = columns
        let cell = size * 0.72 / 7
        let pad = cell * 1.2
        let width = CGFloat(cols.count) * cell
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { context in
            let t = running ? context.date.timeIntervalSince(start) : DotsClock.total
            Canvas { gc, _ in
                for (x, column) in cols.enumerated() {
                    for (y, lit) in column.enumerated() {
                        let center = CGPoint(x: pad + (CGFloat(x) + 0.5) * cell, y: pad + (CGFloat(y) + 0.5) * cell)
                        let r = cell * 0.36
                        let off = CGRect(x: center.x - r * 0.55, y: center.y - r * 0.55, width: r * 1.1, height: r * 1.1)
                        guard lit else {
                            gc.fill(Path(ellipseIn: off), with: .color(Color.white.opacity(0.1)))
                            continue
                        }
                        let v = CGFloat(visibility(x: x, y: y, count: cols.count, t: t))
                        if v < 1 { gc.fill(Path(ellipseIn: off), with: .color(Color.white.opacity(0.1))) }
                        guard v > 0.01 else { continue }
                        let rr = r * (0.45 + 0.55 * v)
                        let halo = CGRect(x: center.x - rr * 1.9, y: center.y - rr * 1.9, width: rr * 3.8, height: rr * 3.8)
                        gc.fill(Path(ellipseIn: halo), with: .color(ink.opacity(0.16 * v)))
                        let dot = CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)
                        gc.fill(Path(ellipseIn: dot), with: .color(ink.opacity(v)))
                    }
                }
            }
        }
        .frame(width: width + pad * 2, height: cell * 7 + pad * 2)
        .onChange(of: inline) { _, _ in replay() }
    }
}

// MARK: - Stack

/// Hours above minutes: the hours solid, the minutes drawn as an outline. While lyrics are open the minutes glide
/// up beside the hours (and back down again), both pieces moving on one spring so the change is a single motion.
private struct StackClock: View {
    let text: String
    let ink: Color
    let size: CGFloat
    let inline: Bool

    private var parts: [String] {
        text.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }

    private let inset: CGFloat = 5

    var body: some View {
        let pieces = parts
        if pieces.count == 2,
           let top = ClockGlyphs.layout(pieces[0], size: size * 0.74, weight: .black, design: .rounded,
                                        widthScale: 0.9, tracking: -size * 0.02),
           let bottom = ClockGlyphs.layout(pieces[1], size: size * 0.74, weight: .black, design: .rounded,
                                           widthScale: 0.9, tracking: -size * 0.02) {
            let topW = top.size.width + inset * 2
            let topH = top.size.height + inset * 2
            let bottomW = bottom.size.width + inset * 2
            let bottomH = bottom.size.height + inset * 2
            let rowGap = size * 0.05
            let sideGap = size * 0.3        // room for the two dots
            // Stacked: both centred in a column. Beside: hours on the left, minutes on the right.
            let totalW = inline ? topW + sideGap + bottomW : max(topW, bottomW)
            let totalH = inline ? max(topH, bottomH) : topH + rowGap + bottomH
            let topX: CGFloat = inline ? 0 : (totalW - topW) / 2
            let topY: CGFloat = inline ? (totalH - topH) / 2 : 0
            let bottomX: CGFloat = inline ? topW + sideGap : (totalW - bottomW) / 2
            let bottomY: CGFloat = inline ? (totalH - bottomH) / 2 : topH + rowGap
            // The two dots of the colon sit between hours and minutes; stacked, they hide between the two rows.
            let dot = size * 0.1
            let dotGap = size * 0.2
            let dotMotion: Animation = inline ? Animation.smooth(duration: 0.6).delay(0.15)
                                              : Animation.easeIn(duration: 0.1)
            let colonX: CGFloat = inline ? topW + sideGap / 2 : totalW / 2
            let colonY: CGFloat = inline ? totalH / 2 : topH + rowGap / 2
            ZStack(alignment: .topLeading) {
                draw(top, filled: true)
                    .offset(x: topX, y: topY)
                draw(bottom, filled: false)
                    .offset(x: bottomX, y: bottomY)
                VStack(spacing: dotGap) {
                    Circle().fill(Color.white.opacity(0.96)).frame(width: dot, height: dot)
                    Circle().fill(ink).frame(width: dot, height: dot)
                }
                .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
                .scaleEffect(inline ? 1 : 0.3)
                .opacity(inline ? 1 : 0)
                // Arrive with the slide; leave almost at once when the lyrics close.
                .animation(dotMotion, value: inline)
                .offset(x: colonX - dot / 2, y: colonY - (dot * 2 + dotGap) / 2)
                .allowsHitTesting(false)
            }
            .frame(width: totalW, height: totalH, alignment: .topLeading)
            .animation(.smooth(duration: 0.95), value: inline)
        } else {
            fallbackText(text, size: size, ink: ink)
        }
    }

    private func draw(_ layout: ClockGlyphs.Layout, filled: Bool) -> some View {
        let line = max(1.4, size * 0.02)
        return Canvas { context, _ in
            context.translateBy(x: inset, y: inset)
            for glyph in layout.glyphs {
                if filled {
                    context.fill(glyph.path, with: .linearGradient(
                        Gradient(colors: [Color.white.opacity(0.98), ink.opacity(0.75)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: layout.size.height)))
                } else {
                    context.stroke(glyph.path, with: .color(ink),
                                   style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: layout.size.width + inset * 2, height: layout.size.height + inset * 2)
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
    }
}

// MARK: - Disc

/// The time on a record label. Sixty ticks around the edge light up second by second, like a needle going round.
private struct DiscClock: View, Animatable {
    let text: String
    let ink: Color
    let size: CGFloat
    let preview: Bool
    /// Lyrics change (0 to 1): the ring, with its lit seconds bar exactly as it is, makes one full turn, so the bar
    /// is never cut or changed and ends up where it started.
    var focus: CGFloat = 0
    var animatableData: CGFloat {
        get { focus }
        set { focus = newValue }
    }

    var body: some View {
        let diameter = size * 1.2
        // Ticks on the real second boundaries, so the lit bar keeps growing during the turn and never jumps.
        let firstTick = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        TimelineView(.periodic(from: firstTick, by: 1)) { context in
            let seconds = preview ? 40 : Calendar.current.component(.second, from: context.date)
            ZStack {
                Canvas { gc, canvas in
                    let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                    let radius = min(canvas.width, canvas.height) / 2 - 2
                    let unit = size / 132
                    let outer = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                       width: radius * 2, height: radius * 2))
                    gc.fill(outer, with: .color(Color.black.opacity(0.3)))
                    gc.stroke(outer, with: .color(Color.white.opacity(0.22)), lineWidth: 1)
                    for k in 0..<4 {
                        let r = radius * (0.56 + 0.08 * CGFloat(k))
                        gc.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                  with: .color(Color.white.opacity(0.05)), lineWidth: 0.7)
                    }
                    for i in 0..<60 {
                        let angle = Double(i) / 60 * 2 * Double.pi - Double.pi / 2
                        let length = (i % 5 == 0 ? 9.0 : 5.0) * Double(unit)
                        let outerR = Double(radius) - 3 * Double(unit)
                        let innerR = outerR - length
                        var tick = Path()
                        tick.move(to: CGPoint(x: Double(center.x) + cos(angle) * innerR,
                                              y: Double(center.y) + sin(angle) * innerR))
                        tick.addLine(to: CGPoint(x: Double(center.x) + cos(angle) * outerR,
                                                 y: Double(center.y) + sin(angle) * outerR))
                        let lit = i <= seconds
                        gc.stroke(tick, with: .color(lit ? ink : Color.white.opacity(0.2)),
                                  style: StrokeStyle(lineWidth: max(1, 1.6 * unit), lineCap: .round))
                    }
                }
                .rotationEffect(.degrees(Double(focus) * 360))
                Text(text)
                    .font(.system(size: size * 0.34, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.96))
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Slit

/// Digits cut across the middle: the lower half slides a little to the side, as if the time had been sliced.
private struct SlitClock: View, Animatable {
    let text: String
    let ink: Color
    let size: CGFloat
    /// Lyrics open (1): the halves slide well apart, then retract part of the way, so the digits stay easy to read.
    var focus: CGFloat = 0
    var animatableData: CGFloat {
        get { focus }
        set { focus = newValue }
    }

    var body: some View {
        if let layout = ClockGlyphs.layout(text, size: size, weight: .bold, design: .rounded,
                                           widthScale: 0.92, tracking: -size * 0.01) {
            let inset: CGFloat = 8
            let w = layout.size.width
            let h = layout.size.height
            // The halves slide far apart in the middle of the change, then retract to a small offset that stays readable.
            let swing = CGFloat(sin(Double(focus) * Double.pi))
            let shift = max(0, size * (0.06 * focus + 0.1 * swing))
            let gap = max(2, size * (0.02 + 0.01 * focus + 0.025 * swing))
            let spread = size * 0.26
            Canvas { context, _ in
                context.translateBy(x: inset, y: inset)
                // The upper half moves left and the lower half right, so the time stays centred as the cut opens.
                context.translateBy(x: (spread - shift) / 2, y: 0)
                for glyph in layout.glyphs {
                    context.drawLayer { layer in
                        layer.clip(to: Path(CGRect(x: -inset, y: -inset, width: w + inset * 2, height: h / 2 - gap / 2 + inset)))
                        layer.fill(glyph.path, with: .color(Color.white.opacity(0.97)))
                    }
                    context.drawLayer { layer in
                        layer.translateBy(x: shift, y: 0)
                        layer.clip(to: Path(CGRect(x: -inset, y: h / 2 + gap / 2, width: w + inset * 2, height: h / 2 + inset)))
                        layer.fill(glyph.path, with: .color(ink))
                    }
                }
            }
            .frame(width: w + spread + inset * 2, height: h + inset * 2)
            .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        } else {
            fallbackText(text, size: size, ink: ink)
        }
    }
}

// MARK: - Glyph outlines

/// Outlines of the digits as SwiftUI paths, each with its own box, laid out with the origin at the top left.
enum ClockGlyphs {
    struct Glyph {
        let path: Path
        let rect: CGRect
    }

    struct Layout {
        let glyphs: [Glyph]
        let size: CGSize
    }

    private static var cache: [String: Layout] = [:]

    static func layout(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       design: NSFontDescriptor.SystemDesign,
                       widthScale: CGFloat, tracking: CGFloat) -> Layout? {
        // The clock asks every second for the same text: build the outlines only when something changed.
        let key = "\(text)|\(size)|\(weight.rawValue)|\(design.rawValue)|\(widthScale)|\(tracking)"
        if let cached = cache[key] { return cached }

        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var font = base
        if let descriptor = base.fontDescriptor.withDesign(design),
           let designed = NSFont(descriptor: descriptor, size: size) {
            font = designed
        }
        let ctFont = font as CTFont
        var paths: [CGPath] = []
        var x: CGFloat = 0
        for unit in text.utf16 {
            var character = unit
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else { continue }
            var advance = CGSize.zero
            _ = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
            if let outline = CTFontCreatePathForGlyph(ctFont, glyph, nil) {
                // Font space has y pointing up; screen space has it pointing down.
                var place = CGAffineTransform(translationX: x, y: 0)
                    .concatenating(CGAffineTransform(scaleX: widthScale, y: -1))
                if let placed = outline.copy(using: &place) { paths.append(placed) }
            }
            x += advance.width + tracking
        }
        guard !paths.isEmpty else { return nil }
        var box = paths[0].boundingBoxOfPath
        for path in paths.dropFirst() { box = box.union(path.boundingBoxOfPath) }

        var glyphs: [Glyph] = []
        for path in paths {
            var move = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            guard let moved = path.copy(using: &move) else { continue }
            glyphs.append(Glyph(path: Path(moved), rect: moved.boundingBoxOfPath))
        }
        let result = Layout(glyphs: glyphs, size: box.size)
        // v419: the clock text changes every minute, so a new entry was added every minute for ever (outlines of every glyph).
        // v523: one limit, 40 (a second line cleared the cache at 24, so the 40 never applied and the outlines of the clock
        // and date were rebuilt more often than they needed to be).
        if cache.count > 40 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

// MARK: - Picker (Settings)

/// Tiles showing the time in every face, with the name underneath. The chosen one gets a blue frame.
struct ClockStylePicker: View {
    @Binding var raw: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        let current = LockClockStyle.resolve(raw)
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(LockClockStyle.allCases) { style in
                let selected = style == current
                Button {
                    guard !selected else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { raw = style.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        LockClockFace(text: "10:09", style: style, tint: Color(hue: 0.6, saturation: 0.5, brightness: 1),
                                      size: 30, animated: false, preview: true)
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(selected ? AnyShapeStyle(Theme.accent.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.05)))
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.10)),
                                              lineWidth: selected ? 1.5 : 1))
                        Text(style.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
