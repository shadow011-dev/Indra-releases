import AppKit
import SwiftUI

/// The visible app name lives here only.
enum AppBrand {
    static let name = "Indra"
}

/// Colours follow the system: the accent colour you chose in System Settings, and light or dark appearance.
/// The shape of every album cover, measured on the reference widget: a round (circular) corner of 0.26 of the
/// cover's side, and the space between the cover and the notch's edge of 0.114 of it.
enum CoverCurve {
    static let ratio: CGFloat = 0.26
    static func radius(_ side: CGFloat) -> CGFloat { side * ratio }
    static func shape(_ side: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius(side), style: .circular)
    }
}

enum Theme {
    static let accent = Color.accentColor
    static let textSecondary = Color.primary.opacity(0.58)
    static let textTertiary = Color.primary.opacity(0.38)
    static let cardRadius: CGFloat = 16

    /// The system accent with a very light top-to-bottom shade, for selected pills and primary buttons.
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent.opacity(0.84)], startPoint: .top, endPoint: .bottom)
    }

    // Icon tile colours: Apple's own vivid system colours, so a white symbol has the strongest contrast on every tile.
    // The names are kept; the colours are chosen by meaning, see `AppPage.tint`.
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let cyan = Color(red: 0.20, green: 0.68, blue: 0.90)      // sky
    static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    static let indigo = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let violet = Color(red: 0.75, green: 0.35, blue: 0.95)
    static let pink = Color(red: 1.00, green: 0.22, blue: 0.37)
    static let red = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.00)
    static let yellow = Color(red: 1.00, green: 0.70, blue: 0.00)    // amber
    static let gray = Color(red: 0.50, green: 0.50, blue: 0.54)      // graphite
}

/// A coloured rounded square with a bold white symbol, like System Settings: a bright top, a deeper bottom,
/// a soft gloss and a thin lit edge, so it stays vivid on any background.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 28

    var body: some View {
        let radius = size * 0.28
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Color.white)
            .shadow(color: Color.black.opacity(0.22), radius: size * 0.04, y: size * 0.03)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.22), tint.mix(with: .black, by: 0.06)],
                                         startPoint: .top,
                                         endPoint: .bottom))
                    .shadow(color: tint.opacity(0.30), radius: size * 0.14, y: size * 0.06)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.26), Color.white.opacity(0)],
                                         startPoint: .top,
                                         endPoint: UnitPoint(x: 0.5, y: 0.55)))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.05)],
                                                 startPoint: .top,
                                                 endPoint: .bottom),
                                  lineWidth: 0.6)
            }
    }
}

/// A coloured symbol with no tile behind it: a light-to-deep gradient and no glow, so it reads on any
/// background and in both appearances. `secondary` colours the second layer of two-layer symbols (cloud and sun).
struct IconGlyph: View {
    let symbol: String
    var tint: Color = Theme.accent
    var secondary: Color? = nil
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var scheme

    private func shade(_ colour: Color) -> LinearGradient {
        let dark = scheme == .dark
        let top = colour.mix(with: .white, by: dark ? 0.22 : 0.06)
        let bottom = colour.mix(with: .black, by: dark ? 0.02 : 0.18)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Group {
            if let second = secondary {
                Image(systemName: symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(shade(tint), shade(second))
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(shade(tint))
            }
        }
        .font(.system(size: size * 0.76, weight: .semibold))
        .frame(width: size, height: size)
    }
}

/// The icon of one page: a small rounded tile in the page colour with a white glyph (sidebar and page headers).
/// With Reminders switched on, the To Do page shows the Reminders look instead.
/// v521: the clock of a page glyph's click animation: 0 = at rest, runs to 1 over `PageGlyph.animationLength`.
/// Every page icon reads this clock and moves its own parts in its own way (see `PageMark.animate`).
private struct GlyphClock { var t: Double = 0 }

/// v521: small easing helpers shared by the icon animations. All of them map 0...1 to 0...1 (or a pulse that returns to 0).
private enum GlyphMotion {
    static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    /// Progress of `t` between `a` and `b`, clamped to 0...1.
    static func seg(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard b > a else { return t >= b ? 1 : 0 }
        return clamp((t - a) / (b - a))
    }
    static func easeOut(_ x: CGFloat) -> CGFloat { let k = 1 - clamp(x); return 1 - k * k * k }
    static func easeIn(_ x: CGFloat) -> CGFloat { let k = clamp(x); return k * k * k }
    static func easeInOut(_ x: CGFloat) -> CGFloat {
        let k = clamp(x)
        return k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
    }
    /// Ends at exactly 1 after a small overshoot; `overshoot` is how far it goes past (about 1.7 = 10 percent).
    static func backOut(_ x: CGFloat, _ overshoot: CGFloat = 1.7) -> CGFloat {
        let k = clamp(x) - 1
        return 1 + (overshoot + 1) * k * k * k + overshoot * k * k
    }
    /// 0 -> 1 -> 0 over `x` in 0...1.
    static func pulse(_ x: CGFloat) -> CGFloat { sin(CGFloat.pi * clamp(x)) }
    /// Straight lines through (time, value) keys.
    static func track(_ t: CGFloat, _ keys: [(CGFloat, CGFloat)]) -> CGFloat {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let a = keys[i - 1], b = keys[i]
            guard b.0 > a.0 else { return b.1 }
            return a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
        }
        return last.1
    }
}

struct PageGlyph: View {
    let page: AppPage
    var size: CGFloat = 24
    /// v521: changes whenever the glyph should play its own click animation (the sidebar bumps it when a section is clicked).
    /// Every page has a different one, built from its own shapes (gear turns, lock opens, battery charges, ...). Only the drawing
    /// inside the tile moves, and everything is clipped to the tile, so nothing can leave the icon box.
    var bounce: Int = 0
    /// How long one click animation lasts, in seconds.
    static let animationLength: Double = 0.9
    @AppStorage(Preferences.remindersEnabledKey) private var remindersOn = false

    private static let tipsYellow = Color(red: 1.00, green: 0.80, blue: 0.22)
    /// The green of the Spotify icon (#1DB954).
    private static let spotifyGreen = Color(red: 0.114, green: 0.725, blue: 0.329)

    private var showsReminders: Bool { page == .todo && remindersOn }

    /// v494: every page icon is drawn like the Face Lock one (v477 / v491): a white tile with a bold, rounded, hand-drawn glyph
    /// in the page's own colour (see `PageMark`). Set to false to go back to coloured tiles with white glyphs.
    static let whiteTiles = true

    private var tile: Color {
        if PageGlyph.whiteTiles, page != .hapticLab { return Color.white }
        switch page {
        case .todo where showsReminders: return Color.white
        // v477: Face Lock is a white tile with the Spotify-green face glyph.
        case .faceLock where PageGlyph.whiteTiles: return Color.white
        case .faceLock: return page.appleColor
        // v411: the colours of the matching Apple apps / System Settings icons, used as they are (no darkening).
        case .calendar, .weather, .todo, .tray, .sensory, .battery, .bluetooth, .lockScreen, .tips, .about, .external:
            return page.appleColor
        // These two came out too dark with the deeper shade: bright, saturated colours chosen directly.
        case .media: return Color(red: 1.00, green: 0.24, blue: 0.36)
        default: return PageGlyph.deeper(page.tint)
        }
    }

    /// The page colour with more saturation and a little less light, so the tile reads rich rather than pastel.
    private static func deeper(_ colour: Color) -> Color {
        guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return colour }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // The grey tiles (General, About) have almost no colour: they only get darker, not tinted.
        let richer = saturation < 0.15 ? saturation : min(1, saturation * 1.25 + 0.05)
        return Color(hue: Double(hue), saturation: Double(richer), brightness: Double(brightness * 0.84))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [tile.mix(with: .white, by: 0.03), tile.mix(with: .black, by: 0.10)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(PageGlyph.whiteTiles || showsReminders ? Color.black.opacity(0.14) : Color.white.opacity(0.12), lineWidth: 0.5)
            Color.clear
                .frame(width: size, height: size)
                .keyframeAnimator(initialValue: GlyphClock(), trigger: bounce) { _, clock in
                    glyph(t: CGFloat(clock.t))
                } keyframes: { _ in
                    KeyframeTrack(\.t) {
                        LinearKeyframe(1.0, duration: PageGlyph.animationLength)
                    }
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    /// The colour of the page's glyph on a white tile (or white on a coloured tile).
    private var markColor: Color {
        PageGlyph.whiteTiles ? PageGlyph.glyphColor(for: page) : Color.white
    }

    /// v494: media is a brighter pink than the page's tint, general a darker grey, so each reads well on white.
    private static func glyphColor(for page: AppPage) -> Color {
        switch page {
        case .media: return Color(red: 1.00, green: 0.24, blue: 0.36)
        case .general: return Color(red: 0.50, green: 0.50, blue: 0.54)
        case .about: return Color(red: 0.50, green: 0.50, blue: 0.54)
        case .tips: return Color(red: 1.00, green: 0.76, blue: 0.04)
        default: return page.appleColor
        }
    }

    @ViewBuilder
    private func glyph(t: CGFloat) -> some View {
        switch page {
        case .todo where showsReminders:
            RemindersMark(size: size, t: t)
        case .faceLock:
            FaceLockMark(size: size, color: PageGlyph.whiteTiles ? nil : Color.white, t: t)
        case .hapticLab:
            Image(systemName: page.symbol)
                .font(.system(size: size * 0.50, weight: .semibold))
                .foregroundStyle(Color.white)
                .scaleEffect(1 + 0.18 * GlyphMotion.pulse(t))
        default:
            PageMark(page: page, size: size, color: markColor, solid: !PageGlyph.whiteTiles, t: t)
        }
    }
}

/// v494: the page icons, drawn in code in the style of the Face Lock icon (v491): bold rounded strokes with round caps and
/// joins, a light-to-deep gradient, no glow. Shapes are laid out on a 100 x 100 grid and scaled to the glyph's size, so they
/// stay sharp at any size. `solid` draws one flat colour (white glyphs on a coloured tile).
private struct PageMark: View {
    let page: AppPage
    let size: CGFloat
    let color: Color
    var solid = false
    /// v521: the click animation clock, 0 = at rest (see `PageGlyph.bounce`). At 0 and 1 the icon is drawn exactly as before.
    var t: CGFloat = 0

    private struct Parts {
        let line: Path      // stroked outlines and lines
        let solid: Path     // small filled shapes (stroked a little too, so their corners are round)
        let dots: Path      // filled dots
        var sun = Path()    // v496: drawn in yellow on a white tile (the Weather sun)
        /// v521: the parts of `line` a page animates on their own (the meaning of each index is set in `animate`).
        var layers: [Path] = []
    }

    private static func parts(for page: AppPage, u: CGFloat) -> Parts {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
        func Box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
        }
        switch page {
        case .general:
            var line = Path()
            line.move(to: P(41.72, 20.13))
            line.addLine(to: P(42.53, 9.69))
            line.addLine(to: P(57.47, 9.69))
            line.addLine(to: P(58.28, 20.13))
            line.addLine(to: P(65.27, 23.02))
            line.addLine(to: P(73.22, 16.21))
            line.addLine(to: P(83.79, 26.78))
            line.addLine(to: P(76.98, 34.73))
            line.addLine(to: P(79.87, 41.72))
            line.addLine(to: P(90.31, 42.53))
            line.addLine(to: P(90.31, 57.47))
            line.addLine(to: P(79.87, 58.28))
            line.addLine(to: P(76.98, 65.27))
            line.addLine(to: P(83.79, 73.22))
            line.addLine(to: P(73.22, 83.79))
            line.addLine(to: P(65.27, 76.98))
            line.addLine(to: P(58.28, 79.87))
            line.addLine(to: P(57.47, 90.31))
            line.addLine(to: P(42.53, 90.31))
            line.addLine(to: P(41.72, 79.87))
            line.addLine(to: P(34.73, 76.98))
            line.addLine(to: P(26.78, 83.79))
            line.addLine(to: P(16.21, 73.22))
            line.addLine(to: P(23.02, 65.27))
            line.addLine(to: P(20.13, 58.28))
            line.addLine(to: P(9.69, 57.47))
            line.addLine(to: P(9.69, 42.53))
            line.addLine(to: P(20.13, 41.72))
            line.addLine(to: P(23.02, 34.73))
            line.addLine(to: P(16.21, 26.78))
            line.addLine(to: P(26.78, 16.21))
            line.addLine(to: P(34.73, 23.02))
            line.closeSubpath()
            line.addEllipse(in: Box(38, 38, 24, 24))
            let solid = Path()
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots)
        case .media:
            var line = Path()
            line.addEllipse(in: Box(9, 9, 82, 82))
            var solid = Path()
            solid.move(to: P(42, 33))
            solid.addLine(to: P(42, 67))
            solid.addLine(to: P(69, 50))
            solid.closeSubpath()
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots)
        case .external:
            var line = Path()
            line.addRoundedRect(in: Box(7, 14, 86, 54), cornerSize: CGSize(width: 11 * u, height: 11 * u), style: .continuous)
            line.move(to: P(50, 68))
            line.addLine(to: P(50, 83))
            line.move(to: P(31, 86))
            line.addLine(to: P(69, 86))
            let solid = Path()
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots)
        case .calendar:
            var line = Path()
            line.addRoundedRect(in: Box(9, 18, 82, 73), cornerSize: CGSize(width: 15 * u, height: 15 * u), style: .continuous)
            line.move(to: P(9, 42))
            line.addLine(to: P(91, 42))
            line.move(to: P(32, 6))
            line.addLine(to: P(32, 26))
            line.move(to: P(68, 6))
            line.addLine(to: P(68, 26))
            let solid = Path()
            var dots = Path()
            dots.addEllipse(in: Box(28.6, 58.6, 10.8, 10.8))
            dots.addEllipse(in: Box(44.6, 58.6, 10.8, 10.8))
            dots.addEllipse(in: Box(60.6, 58.6, 10.8, 10.8))
            dots.addEllipse(in: Box(28.6, 72.6, 10.8, 10.8))
            dots.addEllipse(in: Box(44.6, 72.6, 10.8, 10.8))
            return Parts(line: line, solid: solid, dots: dots)
        case .weather:
            var line = Path()
            line.move(to: P(30, 84))
            line.addCurve(to: P(9, 65), control1: P(16, 84), control2: P(8, 75))
            line.addCurve(to: P(28, 51), control1: P(10, 55), control2: P(19, 50))
            line.addCurve(to: P(56, 35), control1: P(31, 38), control2: P(44, 31))
            line.addCurve(to: P(69, 50), control1: P(63, 37), control2: P(68, 43))
            line.addCurve(to: P(91, 69), control1: P(83, 49), control2: P(93, 58))
            line.addCurve(to: P(72, 84), control1: P(89, 79), control2: P(82, 84))
            line.closeSubpath()
            var sun = Path()
            sun.move(to: P(12.27, 23.87))
            sun.addLine(to: P(5.38, 22.66))
            sun.move(to: P(17.27, 14.27))
            sun.addLine(to: P(12.32, 9.32))
            sun.move(to: P(26.87, 9.27))
            sun.addLine(to: P(25.66, 2.38))
            sun.move(to: P(37.61, 10.69))
            sun.addLine(to: P(40.57, 4.34))
            sun.move(to: P(45.59, 18))
            sun.addLine(to: P(51.65, 14.5))
            sun.addEllipse(in: Box(20.5, 17.5, 19, 19))
            let solid = Path()
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots, sun: sun)
        case .todo:
            var checkA = Path()
            checkA.move(to: P(9, 24))
            checkA.addLine(to: P(16, 31))
            checkA.addLine(to: P(28, 16))
            var checkB = Path()
            checkB.move(to: P(9, 57))
            checkB.addLine(to: P(16, 64))
            checkB.addLine(to: P(28, 49))
            var circle = Path()
            circle.addEllipse(in: Box(11, 75.5, 15, 15))
            var rows = Path()
            rows.move(to: P(44, 24))
            rows.addLine(to: P(92, 24))
            rows.move(to: P(44, 57))
            rows.addLine(to: P(92, 57))
            rows.move(to: P(44, 83))
            rows.addLine(to: P(92, 83))
            var line = Path()
            line.addPath(checkA)
            line.addPath(checkB)
            line.addPath(circle)
            line.addPath(rows)
            return Parts(line: line, solid: Path(), dots: Path(), layers: [checkA, checkB, circle, rows])
        case .tray:
            var line = Path()
            line.move(to: P(11, 55))
            line.addLine(to: P(23, 21))
            line.addLine(to: P(77, 21))
            line.addLine(to: P(89, 55))
            line.addLine(to: P(89, 78))
            line.addQuadCurve(to: P(80, 87), control: P(89, 87))
            line.addLine(to: P(20, 87))
            line.addQuadCurve(to: P(11, 78), control: P(11, 87))
            line.closeSubpath()
            line.move(to: P(11, 55))
            line.addLine(to: P(34, 55))
            line.addQuadCurve(to: P(38, 59), control: P(37, 55))
            line.addQuadCurve(to: P(50, 69), control: P(41, 69))
            line.addQuadCurve(to: P(62, 59), control: P(59, 69))
            line.addQuadCurve(to: P(66, 55), control: P(63, 55))
            line.addLine(to: P(89, 55))
            let solid = Path()
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots)
        case .sensory:
            var body = Path()
            body.move(to: P(9, 38))
            body.addLine(to: P(27, 38))
            body.addLine(to: P(47, 20))
            body.addLine(to: P(47, 80))
            body.addLine(to: P(27, 62))
            body.addLine(to: P(9, 62))
            body.closeSubpath()
            var wave1 = Path()
            wave1.move(to: P(64.72, 33.65))
            wave1.addQuadCurve(to: P(71.15, 43.94), control: P(69.41, 37.87))
            wave1.addQuadCurve(to: P(71.15, 56.06), control: P(72.89, 50))
            wave1.addQuadCurve(to: P(64.72, 66.35), control: P(69.41, 62.13))
            var wave2 = Path()
            wave2.move(to: P(75.43, 21.76))
            wave2.addQuadCurve(to: P(86.53, 39.53), control: P(83.52, 29.05))
            wave2.addQuadCurve(to: P(86.53, 60.47), control: P(89.53, 50))
            wave2.addQuadCurve(to: P(75.43, 78.24), control: P(83.52, 70.95))
            var line = Path()
            line.addPath(body)
            line.addPath(wave1)
            line.addPath(wave2)
            return Parts(line: line, solid: Path(), dots: Path(), layers: [body, wave1, wave2])
        case .battery:
            var line = Path()
            line.addRoundedRect(in: Box(6, 27, 80, 46), cornerSize: CGSize(width: 13 * u, height: 13 * u), style: .continuous)
            line.move(to: P(94, 42))
            line.addLine(to: P(94, 58))
            var solid = Path()
            solid.addRoundedRect(in: Box(16, 37, 42, 26), cornerSize: CGSize(width: 5 * u, height: 5 * u), style: .continuous)
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots)
        case .bluetooth:
            var line = Path()
            line.move(to: P(27, 31))
            line.addLine(to: P(73, 69))
            line.addLine(to: P(50, 89))
            line.addLine(to: P(50, 11))
            line.addLine(to: P(73, 31))
            line.addLine(to: P(27, 69))
            let solid = Path()
            let dots = Path()
            return Parts(line: line, solid: solid, dots: dots)
        case .lockScreen:
            var body = Path()
            body.addRoundedRect(in: Box(14, 44, 72, 48), cornerSize: CGSize(width: 14 * u, height: 14 * u), style: .continuous)
            var shackle = Path()
            shackle.move(to: P(29, 44))
            shackle.addLine(to: P(29, 32))
            shackle.addQuadCurve(to: P(50, 9), control: P(29, 9))
            shackle.addQuadCurve(to: P(71, 32), control: P(71, 9))
            shackle.addLine(to: P(71, 44))
            var stem = Path()
            stem.move(to: P(50, 66))
            stem.addLine(to: P(50, 74))
            var line = Path()
            line.addPath(body)
            line.addPath(shackle)
            line.addPath(stem)
            let solid = Path()
            var dots = Path()
            dots.addEllipse(in: Box(44.6, 57.6, 10.8, 10.8))
            return Parts(line: line, solid: solid, dots: dots, layers: [body, shackle, stem])
        case .tips:
            var bulb = Path()
            bulb.move(to: P(36, 70))
            bulb.addCurve(to: P(20, 38), control1: P(36, 60), control2: P(20, 54))
            bulb.addCurve(to: P(50, 9), control1: P(20, 22), control2: P(33, 9))
            bulb.addCurve(to: P(80, 38), control1: P(67, 9), control2: P(80, 22))
            bulb.addCurve(to: P(64, 70), control1: P(80, 54), control2: P(64, 60))
            bulb.closeSubpath()
            var base = Path()
            base.move(to: P(38, 82))
            base.addLine(to: P(62, 82))
            base.move(to: P(43, 93))
            base.addLine(to: P(57, 93))
            var line = Path()
            line.addPath(bulb)
            line.addPath(base)
            return Parts(line: line, solid: Path(), dots: Path(), layers: [bulb, base])
        case .about:
            var ring = Path()
            ring.addEllipse(in: Box(9, 9, 82, 82))
            var stem = Path()
            stem.move(to: P(50, 45))
            stem.addLine(to: P(50, 71))
            var line = Path()
            line.addPath(ring)
            line.addPath(stem)
            let solid = Path()
            var dots = Path()
            dots.addEllipse(in: Box(44.6, 24.6, 10.8, 10.8))
            return Parts(line: line, solid: solid, dots: dots, layers: [ring, stem])
        default:
            return Parts(line: Path(), solid: Path(), dots: Path())
        }
    }

    /// v521: one different click animation per page, drawn from the same shapes as the resting icon. Every motion happens on the
    /// 100 x 100 grid inside the tile (the tile also clips), starts and ends exactly at the resting drawing, and has its own idea:
    /// General turns two teeth, Media plays the next track, External Notch drops a notch from the top edge, Calendar's days hop in a
    /// wave, Weather's sun spins up while the cloud drifts, To Do ticks itself off, Files Tray catches a file, Volume pumps and
    /// sends out waves, Battery drains and charges, Bluetooth searches, Lock Screen unlocks and snaps shut, Tips switches on,
    /// About hops its dot.
    private static func animate(_ page: AppPage, context ctx: GraphicsContext, t: CGFloat, u: CGFloat, line: CGFloat,
                                shading: GraphicsContext.Shading, sunShading: GraphicsContext.Shading,
                                style: StrokeStyle) {
        typealias E = GlyphMotion
        let parts = PageMark.parts(for: page, u: u)
        let solidStyle = StrokeStyle(lineWidth: line * 0.7, lineCap: .round, lineJoin: .round)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
        func Box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
        }
        /// A copy of the path scaled, turned and moved around `pivot` (scale first, then turn, then move).
        func moved(_ path: Path, pivot: CGPoint, scaleX sx: CGFloat = 1, scaleY sy: CGFloat = 1,
                   rotate r: CGFloat = 0, dx: CGFloat = 0, dy: CGFloat = 0) -> Path {
            var m = CGAffineTransform(translationX: pivot.x + dx, y: pivot.y + dy)
            m = m.rotated(by: r)
            m = m.scaledBy(x: sx, y: sy)
            m = m.translatedBy(x: -pivot.x, y: -pivot.y)
            return path.applying(m)
        }
        func stroke(_ path: Path, _ with: GraphicsContext.Shading? = nil, opacity: CGFloat = 1) {
            var c = ctx
            c.opacity = Double(E.clamp(opacity))
            c.stroke(path, with: with ?? shading, style: style)
        }
        /// A filled shape with a thin round outline, like the resting `solid` parts.
        func solidShape(_ path: Path, opacity: CGFloat = 1) {
            var c = ctx
            c.opacity = Double(E.clamp(opacity))
            c.fill(path, with: shading)
            c.stroke(path, with: shading, style: solidStyle)
        }
        func dot(_ centre: CGPoint, radius: CGFloat, opacity: CGFloat = 1) {
            var c = ctx
            c.opacity = Double(E.clamp(opacity))
            c.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                   with: shading)
        }
        func layer(_ i: Int) -> Path { i < parts.layers.count ? parts.layers[i] : Path() }

        switch page {
        case .general:
            // The gear turns two teeth (45 degrees) with a tiny overshoot, like a clockwork step.
            let angle = E.backOut(E.seg(t, 0, 0.9), 1.1) * (CGFloat.pi / 4)
            stroke(moved(parts.line, pivot: P(50, 50), rotate: angle))

        case .media:
            // Next track: the play triangle leaves to the right and a new one slides in from the left, all inside the ring.
            stroke(parts.line)
            var inside = ctx
            inside.clip(to: Path(ellipseIn: Box(12, 12, 76, 76)))
            func triangle(dx: CGFloat) {
                let shifted = parts.solid.applying(CGAffineTransform(translationX: dx * u, y: 0))
                inside.fill(shifted, with: shading)
                inside.stroke(shifted, with: shading, style: solidStyle)
            }
            let leaving = E.easeIn(E.seg(t, 0, 0.45))
            if leaving < 1 { triangle(dx: 44 * leaving) }
            if t > 0.40 { triangle(dx: -44 * (1 - E.backOut(E.seg(t, 0.40, 0.95), 0.9))) }

        case .external:
            // A notch drops in from the top edge of the screen, settles, and slides back up. Clipped to the screen.
            stroke(parts.line)
            let y: CGFloat
            if t < 0.40 { y = 8 + 17 * E.backOut(E.seg(t, 0, 0.40), 1.2) }
            else if t < 0.65 { y = 25 }
            else { y = 25 - 17 * E.easeIn(E.seg(t, 0.65, 0.95)) }
            var screen = ctx
            screen.clip(to: Path(roundedRect: Box(12, 18.5, 76, 44), cornerRadius: 7 * u, style: .continuous))
            screen.fill(Path(roundedRect: Box(38, y, 24, 9), cornerRadius: 4.5 * u, style: .continuous), with: shading)

        case .calendar:
            // The days hop one after another in a small wave.
            stroke(parts.line)
            let centres = [P(34, 64), P(50, 64), P(66, 64), P(34, 78), P(50, 78)]
            for (i, centre) in centres.enumerated() {
                let start = 0.07 * CGFloat(i)
                let k = E.pulse(E.seg(t, start, start + 0.45))
                dot(CGPoint(x: centre.x, y: centre.y - 4 * u * k), radius: 5.4 * u * (1 + 0.38 * k))
            }

        case .weather:
            // The sun spins up (a little turn and a little growth) while the cloud drifts right and comes back.
            let drift = 3 * u * E.pulse(t)
            stroke(moved(parts.line, pivot: P(50, 60), dx: drift))
            let k = E.seg(t, 0, 0.8)
            let wobble = sin(2 * CGFloat.pi * k) * (10 * CGFloat.pi / 180)
            let grow = 1 + 0.08 * E.pulse(k)
            stroke(moved(parts.sun, pivot: P(30, 27), scaleX: grow, scaleY: grow, rotate: wobble), sunShading)

        case .todo:
            // The first two items are ticked off again (the ticks erase and redraw one after the other), then the empty circle wakes up.
            func tick(_ path: Path, start: CGFloat, end: CGFloat) {
                let amount: CGFloat = t < 0.12 ? 1 - E.easeOut(E.seg(t, 0, 0.12)) : E.easeOut(E.seg(t, start, end))
                if amount > 0.02 { stroke(path.trimmedPath(from: 0, to: amount)) }
            }
            tick(layer(0), start: 0.12, end: 0.42)
            tick(layer(1), start: 0.30, end: 0.60)
            let wake = 1 + 0.3 * E.pulse(E.seg(t, 0.58, 0.90))
            stroke(moved(layer(2), pivot: P(18.5, 83), scaleX: wake, scaleY: wake))
            stroke(layer(3))

        case .tray:
            // A file drops into the tray (fading as it lands) and the tray gives a little under its weight.
            let alpha = E.seg(t, 0.05, 0.18) * (1 - E.seg(t, 0.50, 0.62))
            if alpha > 0.01 {
                let cardY = 2 + 36 * E.easeIn(E.seg(t, 0.05, 0.55))
                var c = ctx
                c.opacity = Double(alpha)
                c.fill(Path(roundedRect: Box(37, cardY, 26, 20), cornerRadius: 5 * u, style: .continuous), with: shading)
            }
            let hit = E.pulse(E.seg(t, 0.52, 0.85))
            stroke(moved(parts.line, pivot: P(50, 87), scaleX: 1 + 0.03 * hit, scaleY: 1 - 0.07 * hit))

        case .sensory:
            // The speaker pumps, and the two waves go out one after the other (each slides outward and dims, then returns).
            let pump = 1 + 0.07 * E.pulse(E.seg(t, 0, 0.45))
            stroke(moved(layer(0), pivot: P(28, 50), scaleX: pump, scaleY: pump))
            let first = E.pulse(E.seg(t, 0.15, 0.60))
            let second = E.pulse(E.seg(t, 0.35, 0.80))
            stroke(moved(layer(1), pivot: P(50, 50), dx: 3 * u * first), opacity: 1 - 0.7 * first)
            stroke(moved(layer(2), pivot: P(50, 50), dx: 3 * u * second), opacity: 1 - 0.7 * second)

        case .battery:
            // The battery drains almost empty and charges back up, left to right.
            stroke(parts.line)
            let level: CGFloat = t < 0.15
                ? 1 - 0.88 * E.easeOut(E.seg(t, 0, 0.15))
                : 0.12 + 0.88 * E.easeInOut(E.seg(t, 0.15, 0.85))
            let width = max(1, 42 * level)
            solidShape(Path(roundedRect: Box(16, 37, width, 26), cornerRadius: min(5, width / 2) * u, style: .continuous))

        case .bluetooth:
            // The rune pulses while signal arcs ripple out on both sides, searching.
            let pulse = 1 + 0.10 * E.pulse(E.seg(t, 0, 0.5))
            stroke(moved(parts.line, pivot: P(50, 50), scaleX: pulse, scaleY: pulse))
            func arc(_ x: CGFloat, _ halfHeight: CGFloat, _ bulge: CGFloat, mirrored: Bool) -> Path {
                let sx: (CGFloat) -> CGFloat = { mirrored ? 100 - $0 : $0 }
                var path = Path()
                path.move(to: P(sx(x), 50 - halfHeight))
                path.addQuadCurve(to: P(sx(x), 50 + halfHeight), control: P(sx(x + bulge), 50))
                return path
            }
            let near = E.pulse(E.seg(t, 0.10, 0.60))
            let far = E.pulse(E.seg(t, 0.30, 0.80))
            for mirrored in [false, true] {
                stroke(moved(arc(78, 9, 8, mirrored: mirrored), pivot: P(50, 50), dx: (mirrored ? -1 : 1) * 2 * u * near), opacity: near)
                stroke(moved(arc(84, 17, 10, mirrored: mirrored), pivot: P(50, 50), dx: (mirrored ? -1 : 1) * 2 * u * far), opacity: far)
            }

        case .lockScreen:
            // The shackle swings open on its right foot, the keyhole blinks, then it snaps shut and the body settles.
            let open: CGFloat
            if t < 0.30 { open = E.backOut(E.seg(t, 0, 0.30), 1.4) }
            else if t < 0.58 { open = 1 }
            else { open = 1 - E.easeIn(E.seg(t, 0.58, 0.78)) }
            let settle = E.pulse(E.seg(t, 0.76, 0.95))
            stroke(moved(layer(0), pivot: P(50, 92), scaleY: 1 - 0.05 * settle))
            stroke(layer(2))
            stroke(moved(layer(1), pivot: P(71, 44), rotate: open * 14 * CGFloat.pi / 180))
            dot(P(50, 63), radius: 5.4 * u * (1 + 0.4 * E.pulse(E.seg(t, 0.30, 0.60))))

        case .tips:
            // The bulb switches on: it flickers once, glows, and fades back.
            let glow = E.track(t, [(0, 0), (0.12, 1), (0.22, 0.25), (0.34, 1), (0.72, 1), (1, 0)])
            var lit = ctx
            lit.opacity = Double(E.clamp(glow * 0.95))
            lit.fill(layer(0), with: shading)
            stroke(layer(0))
            stroke(layer(1))

        case .about:
            // The dot hops (and bounces once), the stem shrinks and grows back from the bottom.
            stroke(layer(0))
            let grow: CGFloat = t < 0.12
                ? 1 - 0.5 * E.easeOut(E.seg(t, 0, 0.12))
                : 0.5 + 0.5 * E.backOut(E.seg(t, 0.12, 0.62), 1.3)
            stroke(moved(layer(1), pivot: P(50, 71), scaleY: grow))
            let first = E.seg(t, 0, 0.5)
            let second = E.seg(t, 0.5, 0.78)
            let hop = 6 * 4 * first * (1 - first) + 1.6 * 4 * second * (1 - second)
            dot(P(50, 30 - hop), radius: 5.4 * u)

        default:
            // A page without its own animation just stays as it is.
            stroke(parts.line)
            ctx.fill(parts.solid, with: shading)
            ctx.stroke(parts.solid, with: shading, style: solidStyle)
            ctx.fill(parts.dots, with: shading)
        }
    }

    var body: some View {
        Canvas { context, canvas in
            let s = min(canvas.width, canvas.height)
            let u = s / 100
            let line = max(1.3, s * 0.088)
            let parts = PageMark.parts(for: page, u: u)
            let shading: GraphicsContext.Shading
            if solid {
                shading = .color(color)
            } else {
                let gradient = Gradient(colors: [color.mix(with: .white, by: 0.22), color.mix(with: .black, by: 0.14)])
                shading = .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: s, y: s))
            }
            let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            // v496: the Weather sun is yellow (a white-tile icon only; on a coloured tile it stays one flat colour).
            let sunShading: GraphicsContext.Shading = solid ? shading : .linearGradient(
                Gradient(colors: [Color(red: 1.00, green: 0.84, blue: 0.18), Color(red: 1.00, green: 0.70, blue: 0.00)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: s * 0.5, y: s * 0.5))
            // v521: while the click animation runs, each page draws its own moving version; at rest (0 or 1) the normal drawing below.
            if t > 0.001 && t < 0.999 {
                PageMark.animate(page, context: context, t: t, u: u, line: line,
                                 shading: shading, sunShading: sunShading, style: style)
                return
            }
            context.stroke(parts.line, with: shading, style: style)
            context.stroke(parts.sun, with: sunShading, style: style)
            context.fill(parts.solid, with: shading)
            context.stroke(parts.solid, with: shading, style: StrokeStyle(lineWidth: line * 0.7, lineCap: .round, lineJoin: .round))
            context.fill(parts.dots, with: shading)
        }
        .frame(width: size * 0.66, height: size * 0.66)
    }
}

/// v491: the Face Lock icon, drawn instead of the plain system symbol: four rounded corner brackets, two eyes, a nose and a
/// smile in a green gradient, with bolder rounded strokes, so it reads clearly even at sidebar size.
private struct FaceLockMark: View {
    let size: CGFloat
    /// nil = the green gradient (white tile); a colour = that flat colour (coloured tile).
    var color: Color? = nil
    /// v521: the click animation clock, 0 = at rest (see `PageGlyph.bounce`): the brackets tighten onto the face, a scan line sweeps
    /// down, then the eyes blink.
    var t: CGFloat = 0

    var body: some View {
        Canvas { context, canvas in
            let s = min(canvas.width, canvas.height)
            let line = max(1.2, s * 0.088)
            let inset = line / 2
            let minX = inset, minY = inset, maxX = s - inset, maxY = s - inset
            let r = s * 0.24, arm = s * 0.12
            // Corner brackets.
            var brackets = Path()
            brackets.move(to: CGPoint(x: minX, y: minY + r + arm)); brackets.addLine(to: CGPoint(x: minX, y: minY + r))
            brackets.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
            brackets.addLine(to: CGPoint(x: minX + r + arm, y: minY))
            brackets.move(to: CGPoint(x: maxX - r - arm, y: minY)); brackets.addLine(to: CGPoint(x: maxX - r, y: minY))
            brackets.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            brackets.addLine(to: CGPoint(x: maxX, y: minY + r + arm))
            brackets.move(to: CGPoint(x: minX, y: maxY - r - arm)); brackets.addLine(to: CGPoint(x: minX, y: maxY - r))
            brackets.addQuadCurve(to: CGPoint(x: minX + r, y: maxY), control: CGPoint(x: minX, y: maxY))
            brackets.addLine(to: CGPoint(x: minX + r + arm, y: maxY))
            brackets.move(to: CGPoint(x: maxX - r - arm, y: maxY)); brackets.addLine(to: CGPoint(x: maxX - r, y: maxY))
            brackets.addQuadCurve(to: CGPoint(x: maxX, y: maxY - r), control: CGPoint(x: maxX, y: maxY))
            brackets.addLine(to: CGPoint(x: maxX, y: maxY - r - arm))
            // Eyes.
            var eyes = Path()
            eyes.move(to: CGPoint(x: s * 0.36, y: s * 0.33)); eyes.addLine(to: CGPoint(x: s * 0.36, y: s * 0.43))
            eyes.move(to: CGPoint(x: s * 0.64, y: s * 0.33)); eyes.addLine(to: CGPoint(x: s * 0.64, y: s * 0.43))
            // Nose.
            var nose = Path()
            nose.move(to: CGPoint(x: s * 0.5, y: s * 0.35)); nose.addLine(to: CGPoint(x: s * 0.5, y: s * 0.56))
            nose.addQuadCurve(to: CGPoint(x: s * 0.44, y: s * 0.585), control: CGPoint(x: s * 0.5, y: s * 0.60))
            // Smile.
            var smile = Path()
            smile.move(to: CGPoint(x: s * 0.36, y: s * 0.68))
            smile.addQuadCurve(to: CGPoint(x: s * 0.64, y: s * 0.68), control: CGPoint(x: s * 0.5, y: s * 0.80))
            let green = Gradient(colors: [Color(red: 0.34, green: 0.86, blue: 0.48), Color(red: 0.06, green: 0.60, blue: 0.30)])
            let shading: GraphicsContext.Shading
            if let color {
                shading = .color(color)
            } else {
                shading = .linearGradient(green, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: s, y: s))
            }
            let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            if t > 0.001 && t < 0.999 {
                let centre = CGPoint(x: s / 2, y: s / 2)
                // The brackets tighten onto the face and spring back.
                let squeeze: CGFloat = t < 0.25
                    ? 1 - 0.13 * GlyphMotion.easeOut(GlyphMotion.seg(t, 0, 0.25))
                    : 0.87 + 0.13 * GlyphMotion.backOut(GlyphMotion.seg(t, 0.25, 0.55), 1.6)
                var m = CGAffineTransform(translationX: centre.x, y: centre.y)
                m = m.scaledBy(x: squeeze, y: squeeze)
                m = m.translatedBy(x: -centre.x, y: -centre.y)
                context.stroke(brackets.applying(m), with: shading, style: style)
                // The eyes blink near the end.
                let blink = 1 - 0.85 * GlyphMotion.pulse(GlyphMotion.seg(t, 0.78, 0.96))
                var b = CGAffineTransform(translationX: 0, y: s * 0.38)
                b = b.scaledBy(x: 1, y: blink)
                b = b.translatedBy(x: 0, y: -s * 0.38)
                context.stroke(eyes.applying(b), with: shading, style: style)
                context.stroke(nose, with: shading, style: style)
                context.stroke(smile, with: shading, style: style)
                // A scan line sweeps down through the face and fades at both ends.
                let sweep = GlyphMotion.seg(t, 0.25, 0.80)
                let fade = GlyphMotion.pulse(sweep)
                if fade > 0.02 {
                    var scan = Path()
                    let y = s * (0.24 + 0.52 * sweep)
                    scan.move(to: CGPoint(x: s * 0.24, y: y))
                    scan.addLine(to: CGPoint(x: s * 0.76, y: y))
                    var c = context
                    c.opacity = Double(fade)
                    c.stroke(scan, with: shading, style: StrokeStyle(lineWidth: line * 0.7, lineCap: .round))
                }
                return
            }
            var path = Path()
            path.addPath(brackets)
            path.addPath(eyes)
            path.addPath(nose)
            path.addPath(smile)
            context.stroke(path, with: shading, style: style)
        }
        .frame(width: size * 0.66, height: size * 0.66)
    }
}

/// Three coloured list dots with their lines, as on the Reminders app icon.
private struct RemindersMark: View {
    let size: CGFloat
    /// v521: the click animation clock, 0 = at rest (see `PageGlyph.bounce`): the three list dots pop one after another and each
    /// line stretches a little as its dot lands.
    var t: CGFloat = 0

    private func row(_ colour: Color, _ index: Int) -> some View {
        let start = 0.14 * CGFloat(index)
        let k = GlyphMotion.pulse(GlyphMotion.seg(t, start, start + 0.45))
        return HStack(spacing: size * 0.07) {
            ZStack {
                Circle().fill(colour)
                Circle().fill(Color.white).frame(width: size * 0.09, height: size * 0.09)
            }
            .frame(width: size * 0.19, height: size * 0.19)
            .scaleEffect(1 + 0.35 * k)
            Capsule()
                .fill(Color.gray.opacity(0.35))
                .frame(height: max(0.8, size * 0.035))
                .scaleEffect(x: 1 - 0.18 * k, y: 1, anchor: .trailing)
        }
    }

    var body: some View {
        VStack(spacing: size * 0.10) {
            row(Color(red: 0.20, green: 0.52, blue: 0.98), 0)
            row(Color(red: 0.95, green: 0.27, blue: 0.30), 1)
            row(Color(red: 1.00, green: 0.60, blue: 0.12), 2)
        }
        .padding(.horizontal, size * 0.17)
    }
}

// MARK: - Page and cards

struct CardBackground: View {
    var radius: CGFloat = Theme.cardRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .shadow(color: Color.black.opacity(0.06), radius: 6, y: 2)
            // The lit top edge that fades down the sides.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.20), Color.primary.opacity(0.06), Color.primary.opacity(0.04)],
                                             startPoint: .top,
                                             endPoint: .bottom),
                              lineWidth: 1)
        }
    }
}

/// Scrolling page with a large header (icon, title, one-line description) followed by cards.
struct SettingsPage<Content: View>: View {
    let page: AppPage
    let content: Content
    @AppStorage(Preferences.remindersEnabledKey) private var remindersOn = false

    init(_ page: AppPage, @ViewBuilder content: () -> Content) {
        self.page = page
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 11) {
                    PageGlyph(page: page, size: 27)
                    Text(page.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                }
                .staggered(0, base: 0.02, step: 0.06)
                content
                    .staggered(1, base: 0.02, step: 0.06)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
    }
}

/// A titled group of rows on one glass card. No footnotes: the app does not explain itself in small print.
struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 8)
            }
            VStack(spacing: 0) { content }
                .background { CardBackground() }
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

/// One row: optional icon tile, title with an optional description, and a control on the right.
struct SettingRow<Trailing: View>: View {
    let symbol: String?
    let tint: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    init(symbol: String? = nil,
         tint: Color = Theme.accent,
         title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            // A soft pill under the row while the pointer is on it.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(hovering && enabled ? 0.045 : 0))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovering = inside }
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

struct ToggleRow: View {
    var symbol: String? = nil
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            PremiumSwitch(isOn: $isOn)
        }
    }
}

// MARK: - Controls

struct PremiumSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0.30 : 0.10), lineWidth: 0.8))
                Circle()
                    .fill(LinearGradient(colors: [Color.white, Color(white: 0.92)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 20, height: 20)
                    .shadow(color: Color.black.opacity(0.30), radius: 2.5, y: 1.2)
                    .padding(2)
            }
            .frame(width: 44, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
    }
}

/// Segmented choice with a pill that slides to the selected option.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var pill

    init(_ options: [(Value, String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<options.count, id: \.self) { index in
                let option = options[index]
                let selected = option.0 == selection
                Button {
                    guard !selected else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.accentGradient)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8))
                                    .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

/// A selectable tile (icon or picture plus a name), highlighted with the accent when chosen.
struct ChoiceTile<Content: View>: View {
    let selected: Bool
    var enabled = true
    let action: () -> Void
    let content: Content

    init(selected: Bool,
         enabled: Bool = true,
         action: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.enabled = enabled
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button {
            action()
        } label: {
            content
                .frame(maxWidth: .infinity)
                .frame(height: 82)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected
                              ? AnyShapeStyle(LinearGradient(colors: [Theme.accent.opacity(0.26), Theme.accent.opacity(0.10)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.05)))
                        .shadow(color: selected ? Theme.accent.opacity(0.28) : Color.clear, radius: 10, y: 3)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.10)),
                                      lineWidth: selected ? 1.5 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .padding(7)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .scaleEffect(selected ? 1.02 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .hoverLift(1.03)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .animation(.spring(response: 0.36, dampingFraction: 0.76), value: selected)
    }
}

/// Symbol above a name: the usual content of a ChoiceTile.
struct TileLabel: View {
    let symbol: String
    let title: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(selected ? Theme.accent : Color.primary.opacity(0.65))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.7))
        }
    }
}

struct ActionButton: View {
    enum Kind { case primary, secondary, destructive }

    let title: String
    var symbol: String? = nil
    var kind: Kind = .secondary
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(Theme.accentGradient)
        case .secondary: return AnyShapeStyle(Color.primary.opacity(hovering ? 0.14 : 0.08))
        case .destructive: return AnyShapeStyle(Color.red.opacity(hovering ? 0.22 : 0.14))
        }
    }

    private var textColor: Color {
        switch kind {
        case .primary: return Color.white
        case .secondary: return Color.primary
        case .destructive: return Color.red
        }
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                Capsule().fill(fill)
                    .shadow(color: kind == .primary ? Theme.accent.opacity(hovering ? 0.55 : 0.32) : Color.clear,
                            radius: hovering ? 10 : 7, y: 3)
            }
            .overlay {
                if kind == .primary {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)],
                                             startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .overlay(Capsule().strokeBorder(kind == .primary ? Color.white.opacity(0.28) : Color.primary.opacity(0.10), lineWidth: 1))
            .brightness(hovering && kind == .primary ? 0.06 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.95))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .opacity(enabled ? 1 : 0.4)
    }
}

struct StatusPill: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (ok ? Color.green : Color.orange).opacity(0.8), radius: 4)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// A soft tinted note for tips and explanations.
struct InfoNote: View {
    let text: String
    var symbol = "info.circle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: [Theme.accent.opacity(0.15), Theme.accent.opacity(0.06)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.20), lineWidth: 1))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.07)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 1))
    }
}

extension View {
    func fieldStyle() -> some View {
        modifier(FieldStyle())
    }
}
