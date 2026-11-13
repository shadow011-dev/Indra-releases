import SwiftUI
import CoreImage

/// The Style-tile thumbnail, recolored with the user's chosen animation color
/// (same recolor as the real animation). Re-renders when `animationColor` changes.
/// v476: the colour table is built in the background; until it is ready the tile keeps showing the previous picture
/// instead of freezing the settings window.
struct ColoredUnlockStill: View {
    @AppStorage("faceLockAnimationColor") private var colorRaw: String = "blue"
    @AppStorage("faceLockAnimationHex") private var customHex: String = "0A84FF"
    @State private var readyTick = 0

    private static let ciContext = SharedCI.context
    private static var cache: [String: CGImage] = [:]
    private static var lastShown: CGImage?

    var body: some View {
        let _ = readyTick
        if let image = image() {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private func image() -> CGImage? {
        let color = AnimationColor(rawValue: colorRaw) ?? .blue
        // The tile always shows the picked colour, never the album colour of the lock screen vinyl.
        let hex = color.recolorHex(ignoringAlbum: true)
        if let cached = Self.cache[hex] { return cached }
        guard AnimationColor.cachedRecolor(hex: hex) != nil else {
            AnimationColor.prepareRecolor(hex: hex) { readyTick += 1 }
            return Self.lastShown ?? Self.render(hex: hex)
        }
        return Self.render(hex: hex)
    }

    private static func render(hex: String) -> CGImage? {
        if let cached = cache[hex] { return cached }
        guard let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png"),
              let ns = NSImage(contentsOf: url),
              var cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let recolor = AnimationColor.recolor(hex: hex)
        let input = CIImage(cgImage: cg)
        let output = recolor.apply(to: input)
        if let out = ciContext.createCGImage(output, from: input.extent) { cg = out }
        if cache.count > 16 { cache.removeAll() }
        cache[hex] = cg
        lastShown = cg
        return cg
    }
}
