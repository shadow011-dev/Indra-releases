import AppKit

enum AccentColor {
    /// The colour that covers the most of the artwork, as a deeper shade of itself.
    /// Pixels are counted by area (not by how vivid they are), so a black and white cover with a few red lips
    /// gives a grey, not red. Near-black pixels are treated as background and ignored. Grey, white and washed-out
    /// pixels count together as one "neutral" group that can win too; it then gives a mid-dark grey.
    static func extract(from image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Twelve hue groups plus one neutral group, each counted by the number of pixels.
        var count = [Double](repeating: 0, count: 12)
        var red = [Double](repeating: 0, count: 12)
        var green = [Double](repeating: 0, count: 12)
        var blue = [Double](repeating: 0, count: 12)
        var neutralCount = 0.0
        var neutralBrightness = 0.0

        for index in 0..<(side * side) {
            let r = Double(pixels[index * 4]) / 255
            let g = Double(pixels[index * 4 + 1]) / 255
            let b = Double(pixels[index * 4 + 2]) / 255
            let color = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            guard brightness > 0.12 else { continue }          // black background
            if saturation > 0.22 {
                let bucket = min(Int(hue * 12), 11)
                count[bucket] += 1
                red[bucket] += r
                green[bucket] += g
                blue[bucket] += b
            } else {
                neutralCount += 1
                neutralBrightness += Double(brightness)
            }
        }

        // A colour spreads over two neighbouring hue groups when it sits on the border between them.
        var smoothed = count
        for i in 0..<12 {
            smoothed[i] = count[i] + 0.5 * (count[(i + 11) % 12] + count[(i + 1) % 12])
        }
        guard let best = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) else { return nil }
        let total = count.reduce(0, +) + neutralCount
        guard total >= 12 else { return nil }

        if neutralCount >= smoothed[best] {
            // Mostly grey / white: a mid-dark grey that still shows on the black notch.
            let level = neutralBrightness / max(neutralCount, 1)
            return NSColor(white: CGFloat(min(max(level * 0.72, 0.42), 0.68)), alpha: 1)
        }

        // Average of the winning hue group and its two neighbours, weighted by their pixel counts.
        let left = (best + 11) % 12, right = (best + 1) % 12
        let members = [left, best, right]
        let n = members.reduce(0.0) { $0 + count[$1] }
        guard n > 0 else { return nil }
        let average = NSColor(srgbRed: CGFloat(members.reduce(0.0) { $0 + red[$1] } / n),
                              green: CGFloat(members.reduce(0.0) { $0 + green[$1] } / n),
                              blue: CGFloat(members.reduce(0.0) { $0 + blue[$1] } / n),
                              alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A deeper shade of the artwork colour: rich, never neon.
        return NSColor(hue: hue,
                       saturation: min(max(saturation, 0.45), 0.9),
                       brightness: min(max(brightness * 0.72, 0.42), 0.68),
                       alpha: 1)
    }
}

extension NSColor {
    /// A deeper shade of the same colour, for the start of a gradient.
    var accentDarker: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(saturation + 0.1, 1), brightness: brightness * 0.6, alpha: 1)
    }
}
