import SwiftUI
import CoreImage

enum AnimationColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, graphite, custom

    var id: String { rawValue }

    /// The swatch colour. v476: this one value is both the dot in settings and the colour the animation is recoloured
    /// to, so the two can no longer disagree.
    var nsColor: NSColor {
        switch self {
        case .blue:     return NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1)
        case .purple:   return NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        case .pink:     return NSColor(srgbRed: 1.00, green: 0.18, blue: 0.55, alpha: 1)
        case .red:      return NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
        case .orange:   return NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)
        case .yellow:   return NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case .green:    return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .graphite: return NSColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1)
        case .custom:   return CustomColor.storedNSColor
        }
    }

    /// Swatch color for the settings picker.
    var color: Color { Color(nsColor: nsColor) }

    /// Measured from the artwork baked into the original videos and the still (the lit pixels are 52,153,255):
    /// hue 210.15 deg, saturation 0.80, brightness 1.0. Earlier versions assumed 215 deg, which tinted every colour 5 deg off.
    nonisolated static let sourceHue: Double = 210.15
    nonisolated static let sourceSaturation: Float = 0.80
    nonisolated static let sourceBrightness: Float = 1.0

    /// The colour (hex) the recolour table is built for. While the lock screen vinyl is open `.custom` means the album
    /// colour, unless `ignoringAlbum` (the settings tile always shows the picked colour).
    func recolorHex(ignoringAlbum: Bool = false) -> String {
        if self == .custom, !ignoringAlbum, let album = FaceScanColor.albumActive { return album }
        return CustomColor.hexString(nsColor)
    }

    /// The recolour table for this colour. v476: every colour (blue included) is recoloured, so the animation matches
    /// its swatch. The table is normally ready already (see `prepareRecolor`); the first call builds it right here.
    func makeRecolor(ignoringAlbum: Bool = false) -> AnimationRecolor? {
        Self.recolor(hex: recolorHex(ignoringAlbum: ignoringAlbum))
    }

    /// Builds the 64 x 64 x 64 colour table that moves the artwork's blue to `hex`: the hue is rotated, and saturation and
    /// brightness are scaled so the lit parts end up at the swatch's own saturation and brightness. White, black and
    /// the glow's soft edges keep their look.
    nonisolated static func buildCube(hex: String) -> AnimationRecolor {
        let target = hsv(ofHex: hex)
        let neutral = target.s < 0.12
        let n = 64
        let shift = Float((target.h - Self.sourceHue) / 360.0)
        // How much to scale saturation / brightness. Limited so a dull colour never makes the animation hard to see on the black notch.
        let satRatio: Float = neutral ? 0 : min(max(Float(target.s) / Self.sourceSaturation, 0.5), 1.3)
        let valRatio: Float = min(max(Float(target.v) / Self.sourceBrightness, 0.7), 1.0)
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)

        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let (h, s, v) = Self.rgbToHSV(Float(r) / Float(n - 1),
                                                  Float(g) / Float(n - 1),
                                                  Float(b) / Float(n - 1))
                    var newHue = h + shift
                    newHue -= floor(newHue)
                    // Only the coloured pixels take the swatch's saturation / brightness.
                    let weight = min(1, s / Self.sourceSaturation)
                    let newSat: Float = neutral ? 0 : min(1, s * satRatio)
                    let newVal = v * (1 + (valRatio - 1) * weight)
                    let (nr, ng, nb) = Self.hsvToRGB(newHue, newSat, newVal)
                    values.append(contentsOf: [nr, ng, nb, 1])
                }
            }
        }

        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return AnimationRecolor(cubeData: data, dimension: n)
    }

    /// Hue (0-360), saturation and brightness (0-1) of a `RRGGBB` hex string.
    nonisolated static func hsv(ofHex hex: String) -> (h: Double, s: Double, v: Double) {
        let value = UInt32(hex, radix: 16) ?? 0x0A84FF
        let (h, s, v) = Self.rgbToHSV(Float((value >> 16) & 0xFF) / 255,
                                      Float((value >> 8) & 0xFF) / 255,
                                      Float(value & 0xFF) / 255)
        return (Double(h) * 360, Double(s), Double(v))
    }

    nonisolated private static func rgbToHSV(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    nonisolated private static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        let scaled = h * 6
        let i = Int(floor(scaled)) % 6
        let f = scaled - floor(scaled)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

/// Applies a precomputed hue-mapping color cube to a frame.
nonisolated struct AnimationRecolor: Sendable {
    let cubeData: Data
    let dimension: Int

    /// v477: recolours a frame in a gradient. Each stop's table recolours the whole frame; the results are joined left to
    /// right, blended linearly between neighbouring stops, the way the notch waveform lays the album gradient across its bars.
    /// White, black and the glow's soft edges keep their look, as with one colour.
    static func applyGradient(_ tables: [AnimationRecolor], to image: CIImage) -> CIImage {
        let extent = image.extent
        guard let first = tables.first else { return image }
        var output = first.apply(to: image).cropped(to: extent)
        guard tables.count > 1, extent.width > 0 else { return output }
        let last = CGFloat(tables.count - 1)
        for index in 1..<tables.count {
            let x0 = extent.minX + extent.width * CGFloat(index - 1) / last
            let x1 = extent.minX + extent.width * CGFloat(index) / last
            guard let ramp = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: x0, y: 0), "inputColor0": CIColor.black,
                "inputPoint1": CIVector(x: x1, y: 0), "inputColor1": CIColor.white
            ])?.outputImage else { continue }
            let layer = tables[index].apply(to: image).cropped(to: extent)
            output = layer.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: ramp.cropped(to: extent)
            ]).cropped(to: extent)
        }
        return output
    }

    func apply(to image: CIImage) -> CIImage {
        guard let cube = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        cube.setValue(image, forKey: kCIInputImageKey)
        cube.setValue(dimension, forKey: "inputCubeDimension")
        cube.setValue(cubeData, forKey: "inputCubeData")
        cube.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return cube.outputImage ?? image
    }
}

/// v468: the colour the face animation uses right now.
/// While the lock screen vinyl (with or without lyrics) is open, the animation takes the album's colour; otherwise it
/// follows the colour chosen in the app. The album colour is set by the lock screen window and cleared when the
/// vinyl closes.
/// v476: a change of the chosen colour is now picked up at once (see `startObserving`): the colour table, the still and
/// both videos are rebuilt in the background the moment the setting changes, not at the next scan.
enum FaceScanColor {
    /// Hex of the album colour, or nil when the chosen colour applies. Only written on the main thread.
    nonisolated(unsafe) private(set) static var albumHex: String?
    /// v477: the album's gradient (the same colours the notch waveform uses, left to right), as hex strings. Only used
    /// while the setting "Album gradient" is on (see `gradientOn`).
    nonisolated(unsafe) private(set) static var albumGradient: [String]?

    /// v491: true while a scan runs on the desktop (home screen: a hover scan or the app lock). The album colour belongs to the
    /// lock screen only; on the desktop the colour chosen in Settings is always used. (It used to depend on whether the
    /// lock screen had already let go of the album colour, so the same scan came out in either colour.)
    nonisolated(unsafe) private(set) static var desktopScan = false

    /// The album colour when it applies right now (never during a desktop scan).
    static var albumActive: String? { desktopScan ? nil : albumHex }

    @MainActor
    static func noteDesktopScan(_ onDesktop: Bool) {
        guard desktopScan != onDesktop else { return }
        desktopScan = onDesktop
        chosenColourMayHaveChanged()
    }

    /// v477: the lock screen setting that makes the face animation follow the album gradient instead of one colour.
    static var gradientOn: Bool { UserDefaults.standard.bool(forKey: "faceLockAlbumGradient") }

    /// The colour stops the animation is recoloured with right now: the album gradient when that is wanted and known,
    /// else the one colour.
    static var recolorHexes: [String] {
        if albumActive != nil, gradientOn, let stops = albumGradient, stops.count > 1 { return stops }
        return [effective.recolorHex()]
    }

    /// v477: the recolouring as one function (one colour table, or one per gradient stop blended left to right).
    nonisolated static func recolorFunction(for hexes: [String]) -> (@Sendable (CIImage) -> CIImage)? {
        if hexes.count > 1 {
            let tables = hexes.map { AnimationColor.recolor(hex: $0) }
            return { image in AnimationRecolor.applyGradient(tables, to: image) }
        }
        guard let hex = hexes.first else { return nil }
        let table = AnimationColor.recolor(hex: hex)
        return { image in table.apply(to: image).cropped(to: image.extent) }
    }

    /// The colour the videos and the still are recoloured with right now.
    static var effective: AnimationColor {
        if albumActive != nil { return .custom }
        return AnimationColor(rawValue: UserDefaults.standard.string(forKey: "faceLockAnimationColor") ?? "") ?? .blue
    }

    /// Identifies the effective colour, for the still and video caches.
    static var cacheKey: String {
        if let albumHex = albumActive {
            if gradientOn, let stops = albumGradient, stops.count > 1 { return "album|" + albumHex + "|g|" + stops.joined(separator: ",") }
            return "album|" + albumHex
        }
        let defaults = UserDefaults.standard
        return (defaults.string(forKey: "faceLockAnimationColor") ?? "") + "|" + (defaults.string(forKey: "faceLockAnimationHex") ?? "")
    }

    /// The album's most vivid colour, lifted so the animation stays bright on the black notch.
    static func albumColour(from tones: [Color]) -> NSColor? {
        guard let srgb = NSColor(ArtworkPalette.accent(of: tones)).usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, sat * 1.1), brightness: min(max(b * 1.15, 0.72), 0.95), alpha: 1)
    }

    /// v490: waits for the face animation to finish before the album colour is let go (see `setAlbum`).
    @MainActor private static var releaseTask: Task<Void, Never>?

    @MainActor
    private static func releaseAlbumNow() {
        releaseTask?.cancel()
        releaseTask = nil
        guard albumHex != nil else { return }
        albumHex = nil
        albumGradient = nil
        lastSeenKey = cacheKey
        ScanAnimationHostView.prewarmStill()
    }

    /// v490: the Mac was unlocked from the vinyl screen and the face animation is still on screen on the desktop. The lock
    /// screen is gone at that moment, which used to drop the album colour in the middle of the animation (it turned back
    /// into the chosen colour). Now the album colour stays until the animation has gone. Locking again, or a new album
    /// colour, ends the wait at once; so does a safety limit.
    @MainActor
    private static func holdAlbumUntilAnimationEnds() {
        guard releaseTask == nil else { return }
        releaseTask = Task { @MainActor in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                if LockMonitor.isScreenActuallyLocked() { break }
                if NotchOverlayController.shared.phase == .closed || Date().timeIntervalSince(started) > 8 { break }
            }
            guard !Task.isCancelled else { return }
            releaseAlbumNow()
        }
    }

    @MainActor
    static func setAlbum(_ color: NSColor?, gradient: [NSColor]? = nil) {
        guard let color else {
            guard albumHex != nil else { return }
            // Unlocked while the face animation is still showing: keep the album colour until it is done.
            // Still locked (the vinyl was only closed): follow the chosen colour at once, as before.
            if !LockMonitor.isScreenActuallyLocked(), NotchOverlayController.shared.phase != .closed {
                holdAlbumUntilAnimationEnds()
                return
            }
            releaseAlbumNow()
            return
        }
        // A new album colour (the vinyl is open again) ends any wait to let the old one go.
        releaseTask?.cancel()
        releaseTask = nil
        // The album colour only comes from the lock screen, so a desktop scan is over by now.
        desktopScan = false
        let hex = CustomColor.hexString(color)
        let stops = (gradient?.count ?? 0) > 1 ? gradient?.map { CustomColor.hexString($0) } : nil
        guard hex != albumHex || stops != albumGradient else { return }
        // The colour tables take a moment to build: do it now, away from the main thread, so the animation that follows
        // (the scan starts a few hundred ms after the screen wakes) never waits for them. The gradient's tables are
        // built too, so switching the setting on later is instant.
        AnimationColor.prepareRecolors(hexes: [hex] + (stops ?? [])) {
            albumHex = hex
            albumGradient = stops
            lastSeenKey = cacheKey
            ScanAnimationHostView.prewarmStill()
        }
    }

    // MARK: - Reacting to the colour picker (v476)

    private static var lastSeenKey = ""
    private static var defaultsObserver: NSObjectProtocol?

    /// Starts watching the chosen colour. When it changes (a dot, the photo picker or the wallpaper), the new colour table
    /// is built in the background and then the still on screen and both videos are rebuilt, so the next scan already
    /// plays in the new colour with no wait and no flash of the old one.
    @MainActor
    static func startObserving() {
        guard defaultsObserver == nil else { return }
        lastSeenKey = cacheKey
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { chosenColourMayHaveChanged() }
        }
    }

    @MainActor
    private static func chosenColourMayHaveChanged() {
        let key = cacheKey
        guard key != lastSeenKey else { return }
        lastSeenKey = key
        ScanAnimationHostView.prewarmStill()
    }
}

extension AnimationColor {
    private nonisolated static let cubeLock = NSLock()
    nonisolated(unsafe) private static var cubes: [String: AnimationRecolor] = [:]

    /// The table for a colour if it has been built already.
    nonisolated static func cachedRecolor(hex: String) -> AnimationRecolor? {
        cubeLock.lock(); defer { cubeLock.unlock() }
        return cubes[hex]
    }

    /// The table for a colour; builds it on the calling thread if it is not ready (only the first use, or a scan
    /// right after a colour change, ever gets here).
    nonisolated static func recolor(hex: String) -> AnimationRecolor {
        if let cached = cachedRecolor(hex: hex) { return cached }
        let cube = buildCube(hex: hex)
        store(cube, hex: hex)
        return cube
    }

    private nonisolated static func store(_ cube: AnimationRecolor, hex: String) {
        cubeLock.lock()
        if cubes.count > 16 { cubes.removeAll() }
        cubes[hex] = cube
        cubeLock.unlock()
    }

    /// v477: the same for several colours (the stops of a gradient).
    @MainActor
    static func prepareRecolors(hexes: [String], done: @escaping @MainActor () -> Void) {
        let missing = Array(Set(hexes.filter { cachedRecolor(hex: $0) == nil }))
        if missing.isEmpty { done(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            for hex in missing { _ = recolor(hex: hex) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// Builds the colour table for `hex` on a background queue, then calls `done` on the main thread.
    @MainActor
    static func prepareRecolor(hex: String, done: @escaping @MainActor () -> Void) {
        if cachedRecolor(hex: hex) != nil { done(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = recolor(hex: hex)
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }
}
