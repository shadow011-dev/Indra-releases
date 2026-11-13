import AppKit
import SwiftUI

/// Nine colours (3 x 3, left to right, top to bottom) taken from the album artwork,
/// toned down so white text stays readable on the gradient they form.
enum ArtworkPalette {
    static let fallback: [Color] = Array(repeating: Color(white: 0.416), count: 9)

    static func tones(from image: NSImage?) -> [Color] {
        tones(from: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    /// Same, from a bitmap: safe to call off the main thread (the lock screen does, so a song change never stalls).
    static func tones(from cg: CGImage?) -> [Color] {
        guard let cg, let cells = grid(from: cg) else { return fallback }
        return cells.map(tone)
    }

    /// The colour the clock takes from the album: the most vivid of the nine colours (the middle one, which is
    /// often a dull patch of the cover, only wins when nothing else is livelier).
    static func accent(of tones: [Color]) -> Color {
        guard tones.count == 9 else { return tones.first ?? Color(white: 0.8) }
        var best = tones[4]
        var bestScore = -1.0
        for (index, tone) in tones.enumerated() {
            guard let srgb = NSColor(tone).usingColorSpace(.sRGB) else { continue }
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let score = Double(saturation) * (0.35 + Double(brightness)) + (index == 4 ? 0.04 : 0)
            if score > bestScore {
                bestScore = score
                best = tone
            }
        }
        return best
    }

    /// v440: three colours of the album, left to right, for the slider's fill and the visualizer. Each is the liveliest of
    /// its column of the 3 x 3 grid, lifted a little so it still shows on the black notch. Nil for artwork without
    /// any colour (grey covers keep the plain look).
    static func gradient(of tones: [Color]) -> [Color]? {
        guard tones.count == 9 else { return nil }
        var result: [Color] = []
        var anyColour = false
        for column in 0..<3 {
            var best = tones[3 + column]
            var bestScore = -1.0
            var bestSaturation = 0.0
            for row in 0..<3 {
                let tone = tones[row * 3 + column]
                guard let srgb = NSColor(tone).usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                let score = Double(saturation) * (0.35 + Double(brightness))
                if score > bestScore {
                    bestScore = score
                    best = tone
                    bestSaturation = Double(saturation)
                }
            }
            if bestSaturation > 0.12 { anyColour = true }
            guard let srgb = NSColor(best).usingColorSpace(.sRGB) else { return nil }
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            result.append(Color(hue: Double(hue),
                                saturation: Double(saturation),
                                brightness: min(max(Double(brightness) * 1.12, 0.58), 0.86)))
        }
        return anyColour ? result : nil
    }

    /// v451: two colours of the album for the slider, the waveform and the circle, joined by a gradient. The first is the
    /// colour that covers most of the cover; the second is the colour on the cover that sits furthest from it (its
    /// opposite: red against teal, pink against blue) and still covers a real part of the picture. Pixels are clustered
    /// in OKLab (no hue-bucket borders, so one pink is never split in two). A cover with one colour only gets a darker
    /// and a lighter shade of it, and a cover that is nearly all grey / black / white returns nil (plain white) instead
    /// of a colour taken from a few stray pixels. Colours keep their own saturation; only the brightness is lifted so
    /// they show on the black notch. Ordered light to dark, with the two ends pushed apart so the gradient is clearly visible.
    static func gradient(from image: NSImage?) -> [Color]? {
        analyse(image)?.colors
    }

    /// v491: THE accent of a cover, used by the lock screen clock and the face animation alike: the colour that covers most
    /// of the picture (the heaviest cluster of the analysis above), lifted so it stays bright on dark. Before, the clock took
    /// the most vivid of nine averaged patches and the face animation took that again with its own lift, so neither matched
    /// the cover (averaging a gold ring with black gives a muddy brown, and the livelier patch could be a different hue).
    /// Nil for grey covers.
    static func dominantAccent(from image: NSImage?) -> NSColor? {
        guard let primary = analyse(image)?.primary,
              let srgb = NSColor(srgbRed: primary.x, green: primary.y, blue: primary.z, alpha: 1).usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, sat * 1.1), brightness: min(max(b * 1.15, 0.72), 0.95), alpha: 1)
    }

    private static func analyse(_ image: NSImage?) -> (colors: [Color], primary: SIMD3<Double>)? {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 48
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        struct Px { var rgb: SIMD3<Double>; var lab: SIMD3<Double>; var w: Double }
        func oklab(_ c: SIMD3<Double>) -> SIMD3<Double> {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = lin(c.x), g = lin(c.y), b = lin(c.z)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                         1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                         0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        func dist(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let d = a - b
            return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        }

        var pixels: [Px] = []
        var lit = 0
        for index in 0..<(side * side) {
            let rgb = SIMD3(Double(data[index * 4]) / 255, Double(data[index * 4 + 1]) / 255, Double(data[index * 4 + 2]) / 255)
            guard max(rgb.x, rgb.y, rgb.z) > 0.14 else { continue }       // black background
            lit += 1
            let lab = oklab(rgb)
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            guard chroma > 0.03 else { continue }                          // grey / white: no colour to take
            pixels.append(Px(rgb: rgb, lab: lab, w: 0.25 + min(chroma / 0.15, 1.5)))
        }
        // Too little colour on the cover (black and white with a few coloured pixels): keep the plain look.
        guard lit > 0, pixels.count >= 12, Double(pixels.count) >= 0.06 * Double(lit) else { return nil }

        var left = pixels
        var found: [(mass: Double, rgb: SIMD3<Double>, lab: SIMD3<Double>)] = []
        for _ in 0..<6 {
            guard !left.isEmpty else { break }
            // Seed: the heaviest 8x8x8 colour cell among what is left.
            var cells = [Double](repeating: 0, count: 512)
            func cell(_ p: Px) -> Int {
                Int(min(p.rgb.x * 7.99, 7)) * 64 + Int(min(p.rgb.y * 7.99, 7)) * 8 + Int(min(p.rgb.z * 7.99, 7))
            }
            for p in left { cells[cell(p)] += p.w }
            guard let seed = cells.indices.max(by: { cells[$0] < cells[$1] }), cells[seed] > 0 else { break }
            var centre = SIMD3<Double>(0, 0, 0), total = 0.0
            for p in left where cell(p) == seed { centre += p.lab * p.w; total += p.w }
            centre /= total
            // Mean shift: move to the weighted mean of everything within 0.10 until it settles.
            for _ in 0..<4 {
                var sum = SIMD3<Double>(0, 0, 0), mass = 0.0
                for p in left where dist(p.lab, centre) < 0.10 { sum += p.lab * p.w; mass += p.w }
                if mass > 0 { centre = sum / mass }
            }
            var rgbSum = SIMD3<Double>(0, 0, 0), mass = 0.0
            for p in left where dist(p.lab, centre) < 0.10 { rgbSum += p.rgb * p.w; mass += p.w }
            guard mass > 0 else { break }
            found.append((mass, rgbSum / mass, centre))
            left.removeAll { dist($0.lab, centre) < 0.16 }
        }
        guard let primary = found.first else { return nil }
        // A cover whose colours are all faint (a warm-tinted black and white one) keeps the plain look.
        guard found.contains(where: { ($0.lab.y * $0.lab.y + $0.lab.z * $0.lab.z).squareRoot() >= 0.05 }) else { return nil }

        func hsb(_ rgb: SIMD3<Double>) -> (h: Double, s: Double, b: Double) {
            let color = NSColor(srgbRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return (Double(hue), Double(saturation), Double(brightness))
        }
        /// A light end and a dark end of the gradient: the two are pushed apart until their brightness differs by at
        /// least 0.3, so the gradient always shows (the dark end stays bright enough for the black notch).
        func ends(light: SIMD3<Double>, dark: SIMD3<Double>) -> [Color] {
            let l = hsb(light), d = hsb(dark)
            var lightLevel = min(max(l.b * 1.08 + 0.06, 0.72), 0.97)
            var darkLevel = min(max(d.b * 0.95, 0.46), 0.7)
            if lightLevel - darkLevel < 0.3 {
                let mid = (lightLevel + darkLevel) / 2
                lightLevel = min(mid + 0.16, 0.97)
                darkLevel = max(lightLevel - 0.32, 0.46)
            }
            return [Color(hue: l.h, saturation: min(l.s * 0.92, 0.95), brightness: lightLevel),
                    Color(hue: d.h, saturation: min(d.s * 1.1 + 0.05, 0.95), brightness: darkLevel)]
        }
        func hueAngle(_ lab: SIMD3<Double>) -> Double { atan2(lab.z, lab.y) * 180 / Double.pi }

        // The opposite: the colour furthest from the main one in hue (and a little in lightness), as long as it covers
        // a real part of the picture (at least 4 % of what the main colour covers).
        var opposite: (mass: Double, rgb: SIMD3<Double>, lab: SIMD3<Double>)?
        var oppositeScore = 0.0
        for candidate in found.dropFirst() where candidate.mass >= primary.mass * 0.04 {
            var turn = abs(hueAngle(candidate.lab) - hueAngle(primary.lab))
            if turn > 180 { turn = 360 - turn }
            let contrast = min(abs(candidate.lab.x - primary.lab.x) / 0.4, 1)
            let score = (0.7 * turn / 180 + 0.3 * contrast) * (candidate.mass / primary.mass).squareRoot()
            // Too close to the main colour in both hue and lightness is the same colour, not a second one.
            guard turn > 25 || abs(candidate.lab.x - primary.lab.x) > 0.18 else { continue }
            if score > oppositeScore {
                oppositeScore = score
                opposite = candidate
            }
        }
        guard let opposite = opposite else {
            // One colour only: a lighter and a darker shade of it.
            return (ends(light: primary.rgb, dark: primary.rgb), primary.rgb)
        }
        // Light to dark (OKLab lightness): the lighter colour at the start, the darker at the end.
        let lighter = primary.lab.x >= opposite.lab.x ? primary : opposite
        let darker = primary.lab.x >= opposite.lab.x ? opposite : primary
        return (ends(light: lighter.rgb, dark: darker.rgb), primary.rgb)
    }

    /// The colour at `position` (0...1) along a list of gradient colours (blended in sRGB).
    static func sample(_ colors: [Color], at position: Double) -> Color {
        guard colors.count > 1 else { return colors.first ?? .white }
        let p = min(max(position, 0), 1) * Double(colors.count - 1)
        let low = min(Int(p), colors.count - 2)
        let f = p - Double(low)
        guard let a = NSColor(colors[low]).usingColorSpace(.sRGB),
              let b = NSColor(colors[low + 1]).usingColorSpace(.sRGB) else { return colors[low] }
        return Color(.sRGB,
                     red: Double(a.redComponent) + (Double(b.redComponent) - Double(a.redComponent)) * f,
                     green: Double(a.greenComponent) + (Double(b.greenComponent) - Double(a.greenComponent)) * f,
                     blue: Double(a.blueComponent) + (Double(b.blueComponent) - Double(a.blueComponent)) * f,
                     opacity: 1)
    }

    private static func grid(from cg: CGImage) -> [NSColor]? {
        let side = 24
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let block = side / 3
        guard block > 0 else { return [] }
        var colors: [NSColor] = []
        for row in 0..<3 {
            for column in 0..<3 {
                var red = 0.0, green = 0.0, blue = 0.0
                for y in 0..<block {
                    for x in 0..<block {
                        let index = ((row * block + y) * side + column * block + x) * 4
                        red += Double(data[index])
                        green += Double(data[index + 1])
                        blue += Double(data[index + 2])
                    }
                }
                let count = Double(block * block) * 255
                colors.append(NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1))
            }
        }
        return colors
    }

    /// Keeps the artwork's own hue and saturation and only limits brightness, so white text stays readable:
    /// very bright artwork is held at a soft tone and very dark artwork does not turn black.
    private static func tone(_ color: NSColor) -> Color {
        guard let srgb = color.usingColorSpace(.sRGB) else { return Color(white: 0.416) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue),
                     saturation: min(1.0, Double(saturation) * 1.06),
                     brightness: min(0.74, 0.27 + 0.55 * Double(brightness)))
    }
}

/// Slowly drifting gradient built from the artwork colours; sits behind the enlarged player.
struct AlbumBackdrop: View {
    let tones: [Color]
    /// Song progress (0...1); the hue drifts a little over the length of the song.
    var progress: (() -> Double)?
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // A soft gradient needs no detail: it is drawn at one eighth of the size and stretched up by the
            // compositor, which is a small fraction of the GPU work of a full-screen mesh with a colour filter.
            GeometryReader { geo in
                let w = max(geo.size.width / 8, 8)
                let h = max(geo.size.height / 8, 8)
                MeshGradient(width: 3, height: 3, points: points(at: t), colors: tones)
                    .hueRotation(.degrees(LockFX.hueDrift ? ((progress?() ?? 0.5) - 0.5) * 12 : 0))
                    .frame(width: w, height: h)
                    .drawingGroup(opaque: true)
                    .scaleEffect(x: geo.size.width / w, y: geo.size.height / h, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        // Soft light behind the artwork and a gentle fall-off towards the corners (kept light and airy).
        .overlay(LinearGradient(colors: [Color.white.opacity(0.04), Color.clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.5)))
        .overlay(RadialGradient(colors: [Color.white.opacity(0.06), Color.clear],
                                center: UnitPoint(x: 0.5, y: 0.45),
                                startRadius: 0,
                                endRadius: 620))
        .overlay(RadialGradient(colors: [Color.clear, Color.black.opacity(0.15)],
                                center: UnitPoint(x: 0.5, y: 0.45),
                                startRadius: 450,
                                endRadius: 1100))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func points(at t: Double) -> [SIMD2<Float>] {
        let drift = Float(0.075)
        let sx = Float(sin(t * 0.32)), cx = Float(cos(t * 0.27)), sy = Float(sin(t * 0.23)), cy = Float(cos(t * 0.37))
        return [
            SIMD2(0, 0), SIMD2(0.5 + drift * sx, 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + drift * cy), SIMD2(0.5 + drift * cx, 0.5 + drift * sy), SIMD2(1, 0.5 - drift * cy),
            SIMD2(0, 1), SIMD2(0.5 - drift * sx, 1), SIMD2(1, 1)
        ]
    }
}
