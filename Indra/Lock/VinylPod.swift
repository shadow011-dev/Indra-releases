import AppKit
import SwiftUI

/// Keeps the disc's angle between frames. The disc eases up to speed when the music starts and
/// coasts to a stop when it pauses, so it never jumps or freezes abruptly.
final class VinylSpin {
    private var angle = 0.0
    private var velocity = 0.0
    /// A burst of extra speed that dies away on its own: the record whirls while it forms, then settles.
    private var boost = 0.0
    private var last = 0.0
    /// Closing: the label always turns anticlockwise (like the opening whirl, reversed) and lands exactly upright, whatever the
    /// disc was doing (spinning, paused, or long idle), so the cover visibly rotates while it becomes a cover.
    private var closeStart: Double?
    private var closeFrom = 0.0
    private var closeTo = 0.0
    static let closeDuration = 0.46

    /// Called when the record opens. Even after a long time of sitting still (or paused), the label turns
    /// during the transition instead of waiting for the needle.
    func kick(_ speed: Double) {
        boost = max(boost, speed)
        last = 0   // the next frame starts a fresh time step, however long the disc was idle
    }

    func advance(playing: Bool, closing: Bool = false, at time: Double) -> Double {
        if closing {
            if closeStart == nil {
                closeStart = time
                closeFrom = angle
                // The opening whirl played the other way: the label turns anticlockwise (the angle goes down), slowing
                // as it settles, and lands upright after at least about a third of a turn.
                closeTo = (angle / 360).rounded(.down) * 360
                if closeFrom - closeTo < 130 { closeTo -= 360 }
            }
            let t = min(max((time - (closeStart ?? time)) / Self.closeDuration, 0), 1)
            let eased = 1 - pow(1 - t, 3)
            last = time
            if t >= 1 {
                angle = 0
                velocity = 0
                boost = 0
                return closeTo
            }
            return closeFrom + (closeTo - closeFrom) * eased
        }
        if closeStart != nil {
            closeStart = nil
            angle = 0
            velocity = 0
            boost = 0
        }
        let dt = last == 0 ? 0 : min(max(time - last, 0), 0.1)
        last = time
        let target = playing ? 110.0 : 0.0
        let rate = playing ? 4.5 : 2.0
        velocity += (target - velocity) * min(1, rate * dt)
        boost -= boost * min(1, 2.3 * dt)
        angle = (angle + (velocity + boost) * dt).truncatingRemainder(dividingBy: 360)
        return angle
    }
}

/// The album cover and the vinyl record in one view. Closed, it is just the square cover (the record is
/// hidden behind it). Opening, the cover rounds off and shrinks into the record's centre label while the
/// black disc grows out from behind it, the grooves fade in and the tonearm swings down: the record is
/// formed during the transition, not swapped in. Closing plays the same thing backwards.
/// Open, it has a tonearm that sets down when the music plays and lifts when it pauses, and a disc that spins.
struct VinylPod: View {
    let artwork: NSImage?
    /// Changes when the song changes: the tonearm lifts, then comes back down on the new record.
    let trackKey: String
    let playing: Bool
    let size: CGFloat
    /// False: the square cover. True: the finished record. Flip it inside an animation to morph.
    let open: Bool
    /// Corner radius of the square cover, in this view's own full-size coordinates.
    let coverRadius: CGFloat
    /// Tapping the cover in the middle of the record.
    let onCollapse: () -> Void
    /// Tapping the tonearm: play or pause.
    let onToggle: () -> Void
    /// How far through the song it is (0...1) at a given moment: the stylus follows it from the outer groove inwards.
    var progress: (Date) -> Double = { _ in 0 }
    /// A white record (white disc, dark grooves and needle) instead of the black one.
    var white = false
    /// The expanded notch's record (Duo, "Clicking the cover: Vinyl"): a pale grooved disc with a raised rim and a
    /// plain photo label, and a long thin tonearm. The lock screen never sets this.
    var notch = false
    /// The notch record's disc colour (a light shade of the album); nil keeps it off-white.
    var discTint: NSColor?
    /// Colour for the record's circular lines (the slider's colour); nil keeps them black.
    var lineTint: NSColor?
    /// v406: the record is built and waiting under the cover (the Duo page keeps it ready). Every layer of it stays at 1 %
    /// instead of 0, because a layer at 0 is dropped by the renderer and would only be drawn for the first time during the
    /// opening, which made the first frames of the opening stutter. At 1 % it cannot be seen but is already drawn.
    var parked = false
    @State private var spin = VinylSpin()
    @State private var settled = true
    /// True from the first frame of the record being open until a moment after it has closed again, so the closing
    /// frames know they are closing (no flash of an unrotated cover between "open" turning false and the spin).
    @State private var wasOpen = false
    @State private var closeToken = 0
    @State private var latestShown = false
    @State private var optimistic: Bool?
    @State private var optimisticToken = 0
    @State private var lifted = false
    @State private var armDown = false
    @State private var armToken = 0
    @State private var liftToken = 0
    @State private var latestArtwork: NSImage?
    @State private var lastTrackKey = ""

    /// What the record shows: the tap is reflected at once, without waiting for the player to answer.
    private var shown: Bool { optimistic ?? playing }
    /// Needle on the record: playing, the record is formed, and not lifted for a song change.
    private var active: Bool { open && armDown && shown && !lifted }
    /// Disc turning. It starts with the transition (a real record spins before the needle lands), so the cover
    /// already turns while it becomes the vinyl, whatever happened before.
    private var turning: Bool { open && shown && !lifted }
    private var closing: Bool { !open && wasOpen }

    // The disc grows a little after the cover starts to shrink; on the way back it shrinks first.
    private var discMotion: Animation {
        open ? .smooth(duration: 0.74).delay(0.04) : .smooth(duration: 0.46)
    }

    // The disc fades in quickly as it comes out from behind the cover, and on the way back stays visible until it is
    // nearly hidden, so it never pops in or out while it is still growing or shrinking.
    private var discFade: Animation {
        open ? .easeOut(duration: 0.34).delay(0.04) : .easeIn(duration: 0.3).delay(0.16)
    }

    var body: some View {
        ZStack {
            VinylBody(size: size, white: white, notch: notch, tint: discTint, lineTint: lineTint)
                .equatable()
                .scaleEffect(open ? 1 : 0.4)
                .animation(discMotion, value: open)
                .opacity(open ? 1 : (parked ? 0.01 : 0))
                .animation(discFade, value: open)
                .allowsHitTesting(false)
            CoverShadow(size: size, radius: CoverCurve.radius(size))
                .scaleEffect(open ? 0.4 : 1)
                .opacity(open ? 0 : (parked ? 0.01 : 1))
                .animation(open ? .smooth(duration: 0.7) : .smooth(duration: 0.46), value: open)
                .allowsHitTesting(false)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: (settled && !turning && !closing) || (!open && !closing))) { context in
                let angle = spin.advance(playing: turning, closing: closing, at: context.date.timeIntervalSinceReferenceDate)
                // The cover picture and the grooves' arcs inside are cached bitmaps (see VinylLabel); each frame only
                // turns them. The turning fades in with the record, so the cover is upright while it is still a cover.
                // v406: the label is compared before it is rebuilt, so the 60 frames a second only turn it (they used to
                // rebuild its cover and label pictures on every frame).
                VinylLabel(artwork: artwork, size: size, open: open, coverRadius: coverRadius, white: white, notch: notch,
                           parked: parked)
                    .equatable()
                    .rotationEffect(.degrees(open || closing ? angle : 0))
                    // Opening eases the label up to its turning angle; closing is driven frame by frame by the spin.
                    .animation(open ? .smooth(duration: 0.7) : nil, value: open)
            }
            if !notch {
                VinylSheen(size: size)
                    .opacity(open ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4).delay(open ? 0.22 : 0), value: open)
            }
            Circle()
                .fill(Color.white.opacity(0.001))
                .frame(width: size * (notch ? 0.46 : 0.4), height: size * (notch ? 0.46 : 0.4))
                .onTapGesture(perform: onCollapse)
                .allowsHitTesting(open)
            Tonearm(size: size, playing: active, white: white, notch: notch, progress: progress) {
                optimistic = !shown
                onToggle()
                // v419: only the newest tap may clear its own guess (an older tap's timer used to clear a newer tap's after
                // less than the full time, so the needle jumped back for a moment).
                optimisticToken += 1
                let mine = optimisticToken
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if mine == optimisticToken { optimistic = nil }
                }
            }
            .opacity(open ? 1 : (parked ? 0.01 : 0))
            .animation(open ? .smooth(duration: 0.4).delay(0.26) : .easeOut(duration: 0.22), value: open)
            .allowsHitTesting(open)
        }
        .frame(width: size, height: size)
        .onAppear {
            latestShown = turning
            lastTrackKey = trackKey
            latestArtwork = artwork
            armDown = open
            wasOpen = open
            settled = !turning
        }
        .onChange(of: open) { _, isOpen in
            armToken += 1
            let token = armToken
            closeToken += 1
            let closeNow = closeToken
            if isOpen {
                wasOpen = true
                // The label starts turning with the morph, from the very first frame.
                settled = false
                spin.kick(shown ? 300 : 190)
                scheduleSettle()
                // The needle comes down once the record has mostly formed.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 430_000_000)
                    if token == armToken { armDown = true }
                }
            } else {
                armDown = false
                // The label keeps turning until it has landed upright as the cover, then the disc rests.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64((VinylSpin.closeDuration + 0.12) * 1_000_000_000))
                    if closeNow == closeToken { wasOpen = false }
                }
            }
        }
        .onChange(of: playing) { _, _ in optimistic = nil }
        .onChange(of: artwork) { _, new in latestArtwork = new }
        .onChange(of: trackKey) { _, key in
            guard key != lastTrackKey else { return }
            lastTrackKey = key
            changeRecord()
        }
        .onChange(of: turning) { _, now in
            latestShown = now
            if now {
                settled = false
            } else {
                scheduleSettle()
            }
        }
    }

    /// Lets the disc's timeline sleep once it has coasted to a stop.
    private func scheduleSettle() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !latestShown { settled = true }
        }
    }
}

extension VinylPod {
    /// Song changed: lift the needle, wait for the new cover, then set the needle down on the new record.
    private func changeRecord() {
        liftToken += 1
        let token = liftToken
        let before = latestArtwork
        withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { lifted = true }
        Task { @MainActor in
            // At least a beat in the air, then until the new cover has arrived (but never for long).
            try? await Task.sleep(nanoseconds: 420_000_000)
            var waited = 0
            while token == liftToken, latestArtwork === before, waited < 8 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard token == liftToken else { return }
            lifted = false
        }
    }
}

/// The soft shadow under the square cover, drawn once as a picture. Only its opacity and scale change.
private struct CoverShadow: View {
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .circular)
            .fill(Color.black.opacity(0.38))
            .frame(width: size, height: size)
            .blur(radius: 28)
            .offset(y: 12)
            .padding(size * 0.3)
            .drawingGroup()
            .padding(-size * 0.3)
    }
}

/// The black disc and its grooves. Never changes, so it is drawn once and kept as a picture.
private struct VinylBody: View, Equatable {
    let size: CGFloat
    var white = false
    var notch = false
    var tint: NSColor?
    var lineTint: NSColor?

    /// v406: compared by value. The disc's colour used to be handed over as a new colour object on every update of the
    /// player (even with the same shade), so the whole disc, with its shadow, was drawn again each time, for instance
    /// right when the needle came down in the middle of the opening.
    static func == (lhs: VinylBody, rhs: VinylBody) -> Bool {
        lhs.size == rhs.size && lhs.white == rhs.white && lhs.notch == rhs.notch
            && lhs.tint == rhs.tint && lhs.lineTint == rhs.lineTint
    }

    var body: some View {
        if notch {
            NotchDisc(size: size, tint: tint, lineTint: lineTint)
        } else {
            classicDisc
        }
    }

    private var classicDisc: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: white ? [Color(white: 1.0), Color(white: 0.95), Color(white: 0.86)]
                                                       : [Color(white: 0.13), Color(white: 0.05), Color(white: 0.02)],
                                         center: .center,
                                         startRadius: size * 0.05,
                                         endRadius: size * 0.5))
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                var radius = size * 0.235
                var index = 0
                while radius < size * 0.485 {
                    let wide = index % 17 == 0
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    let opacity = wide ? 0.13 : (index % 2 == 0 ? 0.045 : 0.025)
                    context.stroke(Path(ellipseIn: rect),
                                   with: .color((white ? Color.black : Color.white).opacity(white ? opacity * 0.9 : opacity)),
                                   lineWidth: wide ? 1.2 : 0.6)
                    radius += size * 0.0048
                    index += 1
                }
            }
            Circle().strokeBorder((white ? Color.black : Color.white).opacity(0.10), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: size * 0.07, y: size * 0.03)
        .padding(size * 0.2)
        .drawingGroup()
        .padding(-size * 0.2)
    }
}

/// The notch record's circular lines as a picture drawn at 4x resolution (cached per size and colour).
private enum NotchGrooves {
    private static var cache: [String: NSImage] = [:]

    static func image(size: CGFloat, lineTint: NSColor?) -> NSImage {
        let rgb = lineTint?.usingColorSpace(.sRGB)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = rgb == nil ? "\(size)-black" : String(format: "%.1f-%.3f-%.3f-%.3f", size, r, g, b)
        if let cached = cache[key] { return cached }

        let scale: CGFloat = 4
        let pixels = max(Int((size * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        let center = size / 2
        var radius = size * 0.272
        var index = 0
        // At the notch's small size the lines would be under 1 pt apart: keep at least 1 pt between them.
        let step = max(size * 0.0082, 1.0)
        while radius < size * 0.462 {
            let strong = index % 6 == 0
            // Black hairlines by default; with a line colour, the same lines in that colour, kept light so the disc
            // itself still looks as it was.
            let color: NSColor = rgb.map { $0.withAlphaComponent(strong ? 0.26 : 0.15) }
                ?? NSColor.black.withAlphaComponent(strong ? 0.085 : 0.052)
            color.setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: center - radius, y: center - radius,
                                                   width: radius * 2, height: radius * 2))
            path.lineWidth = strong ? 0.9 : 0.78
            path.stroke()
            radius += step
            index += 1
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        // v419: one 4x-resolution picture per colour, and the colour follows the song: it grew by megabytes with every song.
        if cache.count > 6 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The expanded notch's record, from the reference photo: an off-white disc, a bright raised rim, then evenly
/// spaced hairline grooves right up to a smooth ring around the photo label. Never changes, so it is drawn once.
private struct NotchDisc: View {
    let size: CGFloat
    var tint: NSColor?
    /// The circular lines' colour (the slider's); nil = the default black hairlines.
    var lineTint: NSColor?

    /// Centre, middle and edge shades of the disc, and its bright rim.
    private var shades: (inner: Color, mid: Color, edge: Color, rim: Color) {
        guard let tint = tint?.usingColorSpace(.sRGB) else {
            return (Color(white: 0.935), Color(white: 0.922), Color(white: 0.905), Color(white: 0.985))
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        tint.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        func shade(_ s: CGFloat, _ b: CGFloat) -> Color { Color(hue: Double(hue), saturation: Double(s), brightness: Double(b)) }
        return (shade(saturation * 0.9, min(brightness + 0.02, 1)), shade(saturation, brightness),
                shade(saturation * 1.1, brightness - 0.05), shade(saturation * 0.35, 1))
    }


    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [shades.inner, shades.mid, shades.edge],
                                         center: .center,
                                         startRadius: size * 0.18,
                                         endRadius: size * 0.5))
            // The circular lines are drawn once at 4x the size and shrunk by the screen, so they are smoothed instead of
            // being cut into pixels (drawn directly, lines this close together break into a grid pattern).
            Image(nsImage: NotchGrooves.image(size: size, lineTint: lineTint))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
            // The black border round the photo label: as wide as the bright rim, and outside the photo so the photo keeps its size.
            Circle()
                .stroke(Color.black.opacity(0.94), lineWidth: size * 0.03)
                .frame(width: size * 0.49, height: size * 0.49)
            // The raised rim: brighter than the grooved part, with a fine shadow line on its inner edge.
            Circle()
                .inset(by: size * 0.03)
                .stroke(Color.black.opacity(0.075), lineWidth: 0.7)
            Circle()
                .strokeBorder(shades.rim, lineWidth: size * 0.03)
            Circle()
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.32), radius: size * 0.08, y: size * 0.035)
        .padding(size * 0.2)
        .drawingGroup()
        .padding(-size * 0.2)
    }
}

/// The record's label as a sharp picture: the cover cropped to a circle at the label's own size, drawn at twice the
/// screen's resolution (cached), with the same slow dissolve between songs as the cover.
private struct LabelDisc: View {
    let image: NSImage?
    let diameter: CGFloat
    @State private var current: NSImage?
    @State private var previous: NSImage?
    @State private var latest: NSImage?
    @State private var fade: CGFloat = 1
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // v401: with no cover (nothing playing) the label is plain black; it used to be empty, so the pale disc
            // showed through the middle of the record.
            Circle().fill(Color.black)
            if let previous {
                disc(previous)
            }
            if let current {
                disc(current).opacity(fade)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { current = image; latest = image }
        .onChange(of: image) { _, new in
            latest = new
            guard let new else {
                // The next song may just not have its cover yet: the old label stays until it arrives (v416: up to 3 s, it
                // was 0.6 s, after which the label went black and the new cover then faded in over black).
                settleTask?.cancel()
                settleTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, latest == nil else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        previous = nil
                        current = nil
                    }
                }
                return
            }
            settleTask?.cancel()
            // v416: the round label picture is drawn in the background FIRST (it used to be drawn on the main thread in the
            // middle of the change, which stalled the first frames of the fade), then the fade starts at once, in 0.42 s
            // (it was 0.9 s).
            settleTask = Task { @MainActor in
                await LabelBitmap.prepare(new, diameter: diameter)
                guard !Task.isCancelled, latest === new else { return }
                previous = current
                current = new
                fade = 0
                withAnimation(.smooth(duration: 0.42)) { fade = 1 }
                try? await Task.sleep(nanoseconds: 520_000_000)
                guard !Task.isCancelled else { return }
                previous = nil
            }
        }
    }

    private func disc(_ source: NSImage) -> some View {
        Image(nsImage: LabelBitmap.disc(source, diameter: diameter))
            .resizable()
            .interpolation(.high)
            .frame(width: diameter, height: diameter)
    }
}

private enum LabelBitmap {
    private static var cache: [String: (source: NSImage, disc: NSImage)] = [:]

    private static func key(_ source: NSImage, _ diameter: CGFloat) -> String {
        "\(ObjectIdentifier(source).hashValue)-\(Int(diameter * 10))"
    }

    /// The finished label picture (drawn here and now only when `prepare` has not done it yet). Main thread only.
    static func disc(_ source: NSImage, diameter: CGFloat) -> NSImage {
        let key = key(source, diameter)
        if let hit = cache[key], hit.source === source { return hit.disc }
        if cache.count > 8 { cache.removeAll() }
        let image = render(source, diameter: diameter)
        cache[key] = (source, image)
        return image
    }

    /// Draws the label picture off the main thread and stores it, so showing it later costs nothing.
    @MainActor
    static func prepare(_ source: NSImage, diameter: CGFloat) async {
        let key = key(source, diameter)
        if let hit = cache[key], hit.source === source { return }
        let image = await Task.detached(priority: .userInitiated) { LabelBitmap.render(source, diameter: diameter) }.value
        if cache.count > 8 { cache.removeAll() }
        cache[key] = (source, image)
    }

    /// The picture as a circle, aspect fill, centred. Touches no shared state.
    fileprivate static func render(_ source: NSImage, diameter: CGFloat) -> NSImage {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(Int((diameter * backing * 2).rounded(.up)), 2)
        let fallback = NSImage(size: NSSize(width: diameter, height: diameter))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              source.size.width > 0, source.size.height > 0 else {
            return fallback
        }
        let side = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).addClip()
        let fit = max(side / source.size.width, side / source.size.height)
        let width = source.size.width * fit
        let height = source.size.height * fit
        source.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.addRepresentation(rep)
        return image
    }
}

/// The part that turns. Closed it is only the square cover; open it is the centre label (the cover shrunk
/// to a circle). (v523: no spindle in the middle any more.)
private struct VinylLabel: View, Equatable {
    let artwork: NSImage?
    let size: CGFloat
    let open: Bool
    let coverRadius: CGFloat
    var white = false
    var notch = false
    var parked = false

    static func == (lhs: VinylLabel, rhs: VinylLabel) -> Bool {
        lhs.artwork === rhs.artwork && lhs.size == rhs.size && lhs.open == rhs.open
            && lhs.coverRadius == rhs.coverRadius && lhs.white == rhs.white && lhs.notch == rhs.notch
            && lhs.parked == rhs.parked
    }

    /// The label's share of the record's width once it is open (a little larger than the reference photo's 38 % in the notch).
    private var labelScale: CGFloat { notch ? 0.46 : 0.4 }

    /// Leads when the record forms; follows a beat late when it folds back into the cover.
    private var coverMotion: Animation {
        open ? .smooth(duration: 0.62) : .smooth(duration: 0.44)
    }

    /// Open, the label is a true circle. (A "continuous" rounded square at full radius is a squircle: its
    /// corners stay a little boxy and do not follow the round record.)
    private var coverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: open ? size / 2 : coverRadius, style: .circular)
    }

    var body: some View {
        ZStack {
            // v441: the three short bright arcs that used to sit in the grooves are gone.

            // The picture is flattened once; opening and closing only change the clip, the scale and the
            // backing fill around that bitmap, so no frame of the morph has to redraw the cover.
            ArtworkLayers(image: artwork, size: size)
                .frame(width: size, height: size)
                .drawingGroup()
                .background(Color.white.opacity(open ? 0 : 0.14))
                .clipShape(coverShape)
            .overlay(coverShape.strokeBorder(Color.black.opacity(open ? (notch ? 0 : (white ? 0.3 : 0.6)) : 0),
                                             lineWidth: notch ? 1 : 2.5))
            // The cover's soft shadow is a separate, cached layer (CoverShadow): animating a blur radius
            // inside this picture would redraw it on every frame of the open animation.
            .scaleEffect(open ? labelScale : 1)
            .animation(coverMotion, value: open)
            // Once the record has formed, the sharp label below takes over from this picture (which is scaled down
            // from the full cover size and would blur and shimmer while it turns). Closing, the cover is back at once.
            .opacity(open ? 0 : (parked ? 0.01 : 1))
            .animation(open ? .linear(duration: 0.01).delay(0.74) : nil, value: open)

            // The turning label: the picture drawn once at the label's own size (and finer than the screen), so
            // turning it does not resample a bigger bitmap.
            LabelDisc(image: artwork, diameter: size * labelScale)
                .overlay(Circle().strokeBorder(Color.black.opacity(notch ? 0 : (white ? 0.3 : 0.6)),
                                               lineWidth: (notch ? 1 : 2.5) * labelScale))
                .opacity(open ? 1 : (parked ? 0.01 : 0))
                .animation(open ? .easeInOut(duration: 0.28).delay(0.42) : .easeOut(duration: 0.18), value: open)
                .allowsHitTesting(false)

            // v523: no spindle hole in the middle of the label, on the lock screen either (the notch's record never had one).
        }
        .frame(width: size, height: size)
    }
}

/// Two soft light streaks that stay still while the disc turns underneath, like light on real vinyl.
private struct VinylSheen: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(AngularGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Color.white.opacity(0.12), location: 0.06),
                .init(color: .clear, location: 0.16),
                .init(color: .clear, location: 0.5),
                .init(color: Color.white.opacity(0.12), location: 0.56),
                .init(color: .clear, location: 0.66),
                .init(color: .clear, location: 1.0)
            ], center: .center, angle: .degrees(-50)))
            .frame(width: size, height: size)
            .drawingGroup()
            .allowsHitTesting(false)
    }
}

/// Tonearm pivoting at the top right: on the record while playing, swung out to the side when paused.
private struct ArmLine: Shape {
    var pivot = CGPoint(x: 0.93, y: 0.08)
    var tip = CGPoint(x: 0.77, y: 0.52)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * pivot.x, y: rect.height * pivot.y))
        path.addLine(to: CGPoint(x: rect.width * tip.x, y: rect.height * tip.y))
        return path
    }
}

/// The expanded notch's tonearm, from the reference: a long thin rod that leans 13 degrees from the upright, a dark
/// capsule base at the top right with a small pivot dot, and a dark upright headshell with a stylus at the bottom.
/// Lengths are shares of the record's width.
private enum NotchArm {
    static let pivot = CGPoint(x: 0.94, y: 0.05)
    static let length: CGFloat = 0.5
    static let leanDegrees: Double = 13
    /// The stylus on the outermost groove / on the innermost one, as the arm's turn from its drawn pose.
    static let outerDegrees = -14.4
    static let innerDegrees = 7.2
    /// How far the arm swings out to the side when it is up.
    static let restDegrees = -26.0
    static var tip: CGPoint {
        let lean = leanDegrees * .pi / 180
        return CGPoint(x: pivot.x - length * CGFloat(sin(lean)), y: pivot.y + length * CGFloat(cos(lean)))
    }
}

/// Where the stylus is, as an angle of the arm. The arm is drawn with its tip at 0 degrees (inner grooves);
/// positive turns it clockwise, towards the middle of the record. The tip sits on the outermost groove at
/// -24.5 degrees and on the innermost at +4, so it walks inwards as the song plays, like a real turntable.
/// The needle is chased with a critically damped spring: ordinary playback is followed without lag, and when
/// the song is moved (the slider let go, a lyrics swipe) the arm glides smoothly to its new place.
private final class ArmTracker {
    static let outerDegrees = -24.5
    static let innerDegrees = 4.0

    private var position = 0.0
    private var velocity = 0.0
    private var last = 0.0
    private var held = 0.0

    static func degrees(forProgress progress: Double) -> Double {
        outerDegrees + (innerDegrees - outerDegrees) * min(max(progress, 0), 1)
    }

    /// Puts the stylus straight onto a place (no glide): used when the needle lands on a new song or record.
    func snap(to degrees: Double) {
        position = degrees
        held = degrees
        velocity = 0
    }

    /// `target` is where the arm should be (0 while it is up). While the slider is held the target is not
    /// followed: the arm stays where it was and only moves once the slider is let go.
    func advance(target: Double, frozen: Bool, at time: Double) -> Double {
        let dt = last == 0 ? 0 : min(max(time - last, 0), 0.05)
        last = time
        if !frozen { held = target }
        let omega = 7.0
        let accel = omega * omega * (held - position) - 2 * omega * velocity
        velocity += accel * dt
        position += velocity * dt
        return position
    }
}

/// True while the progress slider is being dragged (the song only moves when it is let go).
enum SeekDrag {
    static var active = false
}

private struct Tonearm: View {
    let size: CGFloat
    let playing: Bool
    var white = false
    var notch = false
    let progress: (Date) -> Double
    let onTap: () -> Void

    private var pivot: UnitPoint {
        notch ? UnitPoint(x: NotchArm.pivot.x, y: NotchArm.pivot.y) : UnitPoint(x: 0.93, y: 0.08)
    }
    private var armDegrees: (outer: Double, inner: Double, rest: Double) {
        if notch {
            return (outer: NotchArm.outerDegrees, inner: NotchArm.innerDegrees, rest: NotchArm.restDegrees)
        }
        return (outer: ArmTracker.outerDegrees, inner: ArmTracker.innerDegrees, rest: -34)
    }
    private func degrees(forProgress progress: Double) -> Double {
        let angles = armDegrees
        return angles.outer + (angles.inner - angles.outer) * min(max(progress, 0), 1)
    }
    @State private var tracker = ArmTracker()
    @State private var settled = true
    @State private var settleToken = 0

    var body: some View {
        // The timeline keeps running while the arm is down, and for a moment after it lifts so it can come back to rest.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playing && settled)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let shake = playing
                ? 0.34 * (0.50 * sin(t * 47) + 0.30 * sin(t * 31 + 1.3) + 0.20 * sin(t * 83 + 0.4))
                : 0
            // How far along the record the stylus is, on top of the arm's own swing in and out.
            let along = tracker.advance(target: playing ? degrees(forProgress: progress(context.date)) : 0,
                                        frozen: SeekDrag.active,
                                        at: t)
            ZStack {
                // v406: the arm's picture is compared before it is rebuilt: this timeline runs on every frame, and the arm
                // (a canvas with a blurred shadow) used to be drawn again on every one of them while the needle was down.
                ArmArt(size: size, white: white, notch: notch).equatable()
                // Invisible, wide strip along the arm so it is easy to hit.
                ArmLine(pivot: notch ? NotchArm.pivot : CGPoint(x: 0.93, y: 0.08),
                        tip: notch ? NotchArm.tip : CGPoint(x: 0.77, y: 0.52))
                    .stroke(Color.white.opacity(0.001),
                            style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                    .frame(width: size, height: size)
                    .onTapGesture(perform: onTap)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(playing ? 0 : armDegrees.rest), anchor: pivot)
            // Lowering gets a small bounce as the needle lands; lifting is smooth.
            .animation(playing ? Animation.spring(response: 0.7, dampingFraction: 0.55)
                               : Animation.spring(response: 0.6, dampingFraction: 0.9),
                       value: playing)
            .rotationEffect(.degrees(along + shake), anchor: pivot)
        }
        .frame(width: size, height: size)
        .onChange(of: playing) { _, now in
            settleToken += 1
            let token = settleToken
            if now {
                // The needle comes down where the song is now, instead of gliding there from wherever it was.
                tracker.snap(to: degrees(forProgress: progress(Date())))
                settled = false
            } else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    if token == settleToken { settled = true }
                }
            }
        }
    }
}

/// The tonearm's picture (v406): never changes while the record is there, so it is compared first and not redrawn.
private struct ArmArt: View, Equatable {
    let size: CGFloat
    var white = false
    var notch = false

    var body: some View {
        arm
    }

    @ViewBuilder
    private var arm: some View {
        if notch { notchArm } else { classicArm }
    }

    /// The reference tonearm: drawn along its own axis (rod straight down from the pivot), then turned to its lean.
    private var notchArm: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width
            let pivot = CGPoint(x: s * NotchArm.pivot.x, y: s * NotchArm.pivot.y)
            let lean = Angle.degrees(NotchArm.leanDegrees)
            let rodLength = s * NotchArm.length

            // Base and rod share the arm's axis: +y runs along the rod, away from the pivot.
            var axis = context
            axis.translateBy(x: pivot.x, y: pivot.y)
            axis.rotate(by: lean)

            // Dark capsule base, the pivot dot near its top.
            let base = Path(roundedRect: CGRect(x: -s * 0.036, y: -s * 0.034, width: s * 0.072, height: s * 0.104),
                            cornerRadius: s * 0.036, style: .continuous)
            axis.fill(base, with: .color(Color(white: 0.13)))

            // The rod: a thin metal tube, with a fine highlight along one side.
            var rod = Path()
            rod.move(to: .zero)
            rod.addLine(to: CGPoint(x: 0, y: rodLength))
            axis.stroke(rod, with: .color(Color(white: 0.30)),
                        style: StrokeStyle(lineWidth: s * 0.017, lineCap: .butt))
            var shine = Path()
            shine.move(to: CGPoint(x: -s * 0.0035, y: s * 0.012))
            shine.addLine(to: CGPoint(x: -s * 0.0035, y: rodLength))
            axis.stroke(shine, with: .color(Color.white.opacity(0.55)),
                        style: StrokeStyle(lineWidth: s * 0.004, lineCap: .butt))

            axis.fill(Path(ellipseIn: CGRect(x: -s * 0.014, y: -s * 0.014, width: s * 0.028, height: s * 0.028)),
                      with: .color(Color(white: 0.86)))

            // Headshell: a dark block that stands more upright than the rod, with the stylus at its lower left.
            let tip = CGPoint(x: pivot.x - rodLength * CGFloat(sin(lean.radians)),
                              y: pivot.y + rodLength * CGFloat(cos(lean.radians)))
            var head = context
            head.translateBy(x: tip.x, y: tip.y)
            head.rotate(by: .degrees(NotchArm.leanDegrees * -0.55))
            let shell = Path(roundedRect: CGRect(x: -s * 0.022, y: -s * 0.004, width: s * 0.044, height: s * 0.078),
                             cornerRadius: s * 0.006, style: .continuous)
            head.fill(shell, with: .color(Color(white: 0.09)))
            let stylus = Path(roundedRect: CGRect(x: -s * 0.02, y: s * 0.07, width: s * 0.012, height: s * 0.014),
                              cornerRadius: s * 0.004, style: .continuous)
            head.fill(stylus, with: .color(Color(white: 0.8)))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 3.5, y: 2)
        .padding(size * 0.1)
        .drawingGroup()
        .padding(-size * 0.1)
        .allowsHitTesting(false)
    }

    private var classicArm: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width
            let pivot = CGPoint(x: s * 0.93, y: s * 0.08)
            let tip = CGPoint(x: s * 0.77, y: s * 0.52)
            var armPath = Path()
            armPath.move(to: pivot)
            armPath.addLine(to: tip)
            context.stroke(armPath, with: .color(white ? Color(white: 0.22) : Color.white.opacity(0.82)),
                           style: StrokeStyle(lineWidth: s * 0.014, lineCap: .round))
            let head = Path(roundedRect: CGRect(x: tip.x - s * 0.02, y: tip.y - s * 0.004,
                                                width: s * 0.04, height: s * 0.06),
                            cornerSize: CGSize(width: s * 0.008, height: s * 0.008))
            context.fill(head, with: .color(white ? Color(white: 0.15) : Color.white.opacity(0.92)))
            let base = CGRect(x: pivot.x - s * 0.045, y: pivot.y - s * 0.045, width: s * 0.09, height: s * 0.09)
            context.fill(Path(ellipseIn: base), with: .color(white ? Color(white: 0.3) : Color.white.opacity(0.88)))
            let hub = CGRect(x: pivot.x - s * 0.018, y: pivot.y - s * 0.018, width: s * 0.036, height: s * 0.036)
            context.fill(Path(ellipseIn: hub), with: .color(white ? Color.white.opacity(0.9) : Color.black.opacity(0.7)))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        // Drawn once as a picture: the arm only turns, it is never redrawn (its shadow is a blur).
        .padding(size * 0.1)
        .drawingGroup()
        .padding(-size * 0.1)
        .allowsHitTesting(false)
    }
}
