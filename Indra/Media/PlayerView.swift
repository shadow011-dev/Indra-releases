import SwiftUI
import AVKit
import Combine

/// v404: whether the record is open on the Duo page. The notch reads it to give its bottom-left corner the shape of
/// the disc (see `NotchShape.vinylCorner`). Set by the player inside the same animation that opens / folds the record.
@MainActor
final class DuoVinylState: ObservableObject {
    /// v440: one state per notch. The MacBook's notch and the external monitor's island each keep their own record
    /// (before, they shared this one, so folding the record on one display folded it on the other too).
    static let shared = DuoVinylState()
    static let island = DuoVinylState()

    static func state(island isIsland: Bool) -> DuoVinylState { isIsland ? island : shared }

    @Published var open = false

    /// v412: true from the moment the notch is asked to open until it has started to grow. The record that was left
    /// open is rebuilt in that window, while the notch is still closed and hidden, instead of in the first frames of
    /// the opening animation (that rebuild was the stutter after a long rest).
    private(set) var opening = false
    /// Counts openings, for a player page that is already on screen.
    @Published private(set) var prewarm = 0

    func beginOpening() {
        opening = true
        prewarm &+= 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.opening = false
        }
    }

    func endOpening() { opening = false }
}

struct PlayerView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var identifier: SongIdentifier
    let levels: SmoothedLevel
    /// True only while the notch is open; pauses all timers otherwise.
    let active: Bool
    /// Half-width layout used on the Duo page.
    var compact = false
    /// v413: always the record (the "Clicking the cover" setting is gone).
    private let coverTap = Preferences.defaultCoverTap
    /// The record is drawn in the cover's place (it stays so while it folds back into a cover) / it is open.
    @State private var vinylShown = false
    @State private var vinylOpen = false
    @State private var vinylToken = 0
    /// Bumped when the notch opens with the record left open: the record is then built again, already open.
    @State private var podEpoch = 0
    /// Remembered across the notch closing: once the record is opened it stays the cover until the person taps it away.
    @AppStorage("notchVinylOn") private var mainVinylOn = false
    /// v440: the island remembers its own record, apart from the MacBook notch's.
    @AppStorage("islandVinylOn") private var islandVinylOn = false
    @Environment(\.notchIsland) private var island
    @AppStorage(Preferences.accentVisualizerKey) private var accentVisualizer = true
    @AppStorage(Preferences.accentSliderKey) private var accentSlider = true
    @AppStorage(Preferences.vinylAccentKey) private var vinylAccent = false
    @AppStorage(Preferences.vinylLinesKey) private var vinylLines = false

    private var vinylOn: Bool {
        get { island ? islandVinylOn : mainVinylOn }
        nonmutating set { if island { islandVinylOn = newValue } else { mainVinylOn = newValue } }
    }

    private var vinylState: DuoVinylState { DuoVinylState.state(island: island) }

    private var visualizerTint: Color {
        if accentVisualizer, let accent = media.accentNSColor { return Color(nsColor: accent) }
        return Color.white
    }

    private var sliderAccent: NSColor? { accentSlider ? media.accentNSColor : nil }

    /// v440: the album's colours, left to right, for the visualizer and the slider (each follows its own switch in Settings).
    private var visualizerGradient: [Color]? { accentVisualizer ? media.accentGradient : nil }
    private var sliderGradient: [Color]? { accentSlider ? media.accentGradient : nil }

    /// With "Vinyl lines match the slider": the record's circular lines take the slider's colour (nil = black lines,
    /// when the slider has no colour of its own).
    private var vinylLineTint: NSColor? { vinylLines ? sliderAccent : nil }

    /// Cover size on the Duo page: as tall as the page allows (about 65 % of the whole open notch, as in the
    /// reference); the slider sits beside it, under the artist name.
    static let duoArtSide: CGFloat = 88
    /// Corner radius of the Duo cover and the space around it, in the proportions of the reference widget
    /// (measured on it: corner = 0.20 of the cover, left space = 0.12, bottom space = 0.108). The corner is
    /// nearly concentric with the notch's own bottom corner (30 pt).
    static let duoArtRadius: CGFloat = CoverCurve.radius(88)
    /// Measured from the edge of the black body (the notch frame's own edge is 23 pt further out: the top ears).
    static let duoCoverLeftGap: CGFloat = 10
    static let notchEarInset: CGFloat = 23
    static let duoCoverBottomGap: CGFloat = 10

    private var track: TrackInfo? { media.track }
    private var isPlaying: Bool { track?.isPlaying ?? false }

    var body: some View {
        // Nothing playing looks like playing: the same cover tile (empty), "Not Playing", the progress bar and the
        // controls, all in the same places, so nothing moves when a song starts.
        playerBody
            .onAppear { restoreVinyl() }
            .onChange(of: active) { _, isOpen in
                if isOpen { restoreVinyl() }
            }
            .onReceive(vinylState.$prewarm.dropFirst()) { _ in restoreVinyl() }
    }

    /// The notch opens with the record already showing if it was left open.
    private func restoreVinyl() {
        guard compact, active || vinylState.opening, coverTap == "vinyl", vinylOn, !vinylOpen else { return }
        vinylToken += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // A new record that starts open (the one waiting under the cover starts closed).
            podEpoch += 1
            vinylShown = true
            vinylOpen = true
            vinylState.open = true
        }
    }

    @ViewBuilder
    private var playerBody: some View {
        if compact {
            compactBody
        } else {
            regularBody
        }
    }

    /// Duo page: a big cover with, on its right, the title and artist, a seek slider (filled with the album accent
    /// when "accent slider" is on in Settings, white otherwise) and the controls underneath.
    private var compactBody: some View {
        HStack(alignment: .center, spacing: 12) {
            artworkTile
            VStack(alignment: .leading, spacing: 0) {
                nameBlock
                Spacer(minLength: 0)
                progressRow
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    controlButton("backward.fill", size: 13) { media.previousTrack() }
                    controlButton(isPlaying ? "pause.fill" : "play.fill", size: 19) { media.togglePlayPause() }
                    controlButton("forward.fill", size: 13) { media.nextTrack() }
                }
                // Centred under the slider.
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PlayerView.duoArtSide)
            .id(track?.identity ?? "none")
            .transition(.blurReplace)
        }
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PlayerView.duoArtSide)
        .animation(.smooth(duration: 0.45), value: track?.identity)
        .onDisappear {
            SeekDrag.active = false
            vinylState.open = false   // the page is gone: the notch's corner goes back to normal
        }
    }

    /// The song and artist names on the Duo page (plain text; the slider below them is always there).
    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(track?.title ?? "Not Playing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(track == nil ? 0.4 : 1))
                .lineLimit(1)
                .opensPlayingApp(media)
            if let artist = track?.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .opensPlayingApp(media)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var regularBody: some View {
        VStack(spacing: compact ? 6 : 8) {
            topRow
            if track?.source == .identified {
                identifiedNote
            } else {
                progressRow
                controlsRow
            }
        }
        .animation(.smooth(duration: 0.45), value: track?.identity)
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: compact ? 8 : 12) {
            // Outside the id below, so the cover stays the same view and can flip to the new one.
            artworkTile
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Not Playing")
                    .font(.system(size: compact ? 12.5 : 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(track == nil ? 0.4 : 1))
                    .lineLimit(1)
                    .opensPlayingApp(media)
                if let artist = track?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: compact ? 10.5 : 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .opensPlayingApp(media)
                }
            }
            .id(track?.identity ?? "none")
            .transition(.blurReplace)
            Spacer(minLength: 4)
            if !compact {
                VisualizerView(level: levels, playing: isPlaying, active: active, tint: visualizerTint, gradient: visualizerGradient)
            }
        }
    }

    /// v406: with "Clicking the cover: Vinyl" the record is built the moment the page exists and waits under the cover
    /// (every layer of it drawn at 1 %, see `VinylPod.parked`). Before, it was built at the click, so the first frames of
    /// the opening were spent drawing the disc, its shadow, the label and the needle for the first time and the opening
    /// stuttered; the way back to the cover, where everything is already drawn, was smooth. Now the click only turns the
    /// waiting record on and starts the same kind of morph.
    @ViewBuilder
    private var artworkTile: some View {
        if compact && coverTap == "vinyl" {
            ZStack {
                vinylTile
                    .allowsHitTesting(vinylShown)
                coverTile
                    .opacity(vinylShown ? 0 : 1)
                    .allowsHitTesting(!vinylShown)
            }
            .frame(width: PlayerView.duoArtSide, height: PlayerView.duoArtSide)
        } else {
            coverTile
        }
    }

    /// With "Clicking the cover: Vinyl": the cover turns into the white record the way it does on the lock screen
    /// (the cover rounds off into the label, the disc grows out from behind it, the needle lands), with the same
    /// features: the needle follows the song and plays / pauses it, a song change lifts it, and a click on the middle
    /// of the record folds it back into the cover.
    private var vinylTile: some View {
        VinylPod(artwork: media.artwork,
                 trackKey: track?.identity ?? "",
                 playing: isPlaying,
                 size: PlayerView.duoArtSide,
                 open: vinylOpen,
                 coverRadius: PlayerView.duoArtRadius,
                 onCollapse: { Haptics.hf1(); vinylOn = false; closeVinyl() },
                 onToggle: {
                     Haptics.hf1()
                     media.togglePlayPause()
                 },
                 progress: { date in
                     guard let current = media.track, current.duration > 0 else { return 0 }
                     return current.elapsed(at: date) / current.duration
                 },
                 white: true,
                 notch: true,
                 discTint: vinylAccent ? media.vinylTintNSColor : nil,
                 lineTint: vinylLineTint,
                 parked: !vinylShown)
            .id(podEpoch)
            .frame(width: PlayerView.duoArtSide, height: PlayerView.duoArtSide)
            // No reset when the notch closes: the record stays as it is while the notch folds away.
    }

    private func openVinyl() {
        vinylOn = true
        vinylToken += 1
        let token = vinylToken
        // The waiting record takes the cover's place (it looks the same closed) ...
        vinylShown = true
        Task { @MainActor in
            // ... one beat (two frames) so it is on screen as the closed cover, then it forms. Nothing has to be drawn for
            // the first time any more, so the beat is shorter than it was.
            try? await Task.sleep(nanoseconds: 34_000_000)
            guard token == vinylToken else { return }
            withAnimation(.smooth(duration: 0.7)) { vinylOpen = true; vinylState.open = true }
        }
    }

    private func closeVinyl() {
        guard vinylShown else { return }
        vinylToken += 1
        let token = vinylToken
        withAnimation(.smooth(duration: 0.46)) { vinylOpen = false; vinylState.open = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if token == vinylToken { vinylShown = false }
        }
    }

    private var coverTile: some View {
        let side: CGFloat = compact ? PlayerView.duoArtSide : 52
        let radius: CGFloat = compact ? PlayerView.duoArtRadius : 12
        let curve: RoundedCornerStyle = compact ? .circular : .continuous
        return FlipArtwork(image: media.artwork, trackID: track?.identity ?? "none", side: side, radius: radius,
                           curve: curve, direction: { media.recentSkipDirection })
            .contentShape(RoundedRectangle(cornerRadius: radius, style: curve))
            .onTapGesture {
                Haptics.hf1()
                if compact, coverTap == "vinyl" {
                    openVinyl()
                } else {
                    media.openSourceApp()
                }
            }
    }

    // MARK: - Song identification (automatic)

    private var statusText: String? {
        switch identifier.phase {
        case .idle: return nil
        case .listening: return "Listening for music…"
        case .failed(let message): return message
        }
    }

    private var identifiedNote: some View {
        Text("Identified with Shazam")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressRow: some View {
        if active && isPlaying {
            // Redrawn every frame from the real playback time, so the bar is always exactly on the position (no lag).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                ProgressRow(track: track, date: context.date, onSeek: media.seek(to:), accent: sliderAccent, gradient: sliderGradient, slim: compact)
            }
        } else {
            ProgressRow(track: track, date: Date(), onSeek: media.seek(to:), accent: sliderAccent, gradient: sliderGradient, slim: compact)
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        ZStack {
            HStack(spacing: compact ? 18 : 40) {
                controlButton("backward.fill", size: compact ? 15 : 20) { media.previousTrack() }
                controlButton(isPlaying ? "pause.fill" : "play.fill", size: compact ? 21 : 28) { media.togglePlayPause() }
                controlButton("forward.fill", size: compact ? 15 : 20) { media.nextTrack() }
            }
            if !compact {
                HStack {
                    if track?.source == .system {
                        // Browsers and other apps have no repeat mode to control.
                        Color.clear.frame(width: 28, height: 28)
                    } else {
                        repeatButton
                    }
                    Spacer(minLength: 0)
                    AirPlayButton()
                        .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: isPlaying)
    }

    private var repeatButton: some View {
        Button(action: {
            media.cycleRepeat()
        }) {
            Image(systemName: media.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(media.repeatMode == .off ? 0.4 : 1))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .animation(.smooth(duration: 0.2), value: media.repeatMode == .off)
        }
        .buttonStyle(PressScaleStyle())
        .hoverLift(1.1)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.hf1()   // previous / play / pause / next
            action()
        }) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: compact ? 30 : 44, height: compact ? 24 : 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .hoverLift(1.08)
    }
}

/// System AirPlay route picker (white glyph; opens the macOS output popover).
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

// MARK: - Progress row

extension View {
    /// Clicking the song title or the artist name brings the app that is playing (Music, Spotify, the browser ...) to the front.
    func opensPlayingApp(_ media: MediaController) -> some View {
        contentShape(Rectangle())
            .onTapGesture {
                Haptics.hf1()
                media.openSourceApp()
            }
    }
}

/// What the lock screen's bar drew last (a plain object: changing it never redraws anything by itself).
final class SliderSmoothing {
    var value = 0.0
    var last = Date.distantPast
}

struct ProgressRow: View {
    let track: TrackInfo?
    let date: Date
    let onSeek: (TimeInterval) -> Void
    /// Album accent for the filled part of the bar (a gradient); nil = white.
    var accent: NSColor?
    /// v440: the album's own colours, left to right; when set, the filled part is drawn in this gradient.
    var gradient: [Color]? = nil
    /// Duo page: bar on top, elapsed and total time underneath, with a round handle.
    var stacked = false
    /// Duo page: one slim line, elapsed time on its left and time left on its right, with a small round handle.
    var slim = false
    /// 0...1: how much of the real position is shown. The lock screen eases this from 0 to 1 when the bar appears, so
    /// the bar (and the time beside it) grows from the start to where the song really is instead of popping in there.
    var reveal: Double = 1
    /// v401: the lock screen's bar glides toward the real position instead of stepping to it on every frame, so a seek,
    /// the bar growing in, and the slow creep of a long song all move smoothly. (Off for the notch's own bars.)
    var smooth = false
    @State private var smoothing = SliderSmoothing()
    @State private var dragFraction: Double?
    @State private var lastScrubStep = -1
    @State private var pressing = false

    private var duration: TimeInterval { track?.duration ?? 0 }
    private var elapsed: TimeInterval { track?.elapsed(at: date) ?? 0 }

    private var fraction: Double {
        if let dragFraction {
            if smooth { smoothing.value = dragFraction; smoothing.last = date }   // let go: glide on from where the finger left it
            return dragFraction
        }
        let target = (duration > 0 ? min(max(elapsed / duration, 0), 1) : 0) * reveal
        return smooth ? eased(target) : target
    }

    /// Moves the drawn position a fraction of the way to the real one each frame (the same answer for every read
    /// within one frame). Tiny differences, the normal creep of a playing song, are followed exactly.
    private func eased(_ target: Double) -> Double {
        if smoothing.last == date { return smoothing.value }
        let first = smoothing.last == .distantPast
        let dt = min(max(date.timeIntervalSince(smoothing.last), 0), 0.25)
        smoothing.last = date
        let difference = target - smoothing.value
        // v441: the bar always glides (before, any gap under 1.2 % was snapped to, so the normal creep of the song and
        // the small corrections of the player's clock showed as little steps). Only a sub-pixel gap is closed at once.
        if first || dt <= 0 || abs(difference) < 0.0002 {
            smoothing.value = target
        } else {
            smoothing.value += difference * (1 - exp(-dt * 9))
        }
        return smoothing.value
    }

    private var shownElapsed: TimeInterval {
        dragFraction.map { $0 * duration } ?? elapsed * reveal
    }

    var body: some View {
        Group {
            if slim {
                HStack(spacing: 6) {
                    Text(track == nil ? "-:--" : format(shownElapsed))
                        .frame(width: 30, alignment: .trailing)
                    bar
                    Text(duration > 0 ? "-" + format(max(duration - shownElapsed, 0)) : "-:--")
                        .frame(width: 34, alignment: .leading)
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            } else if stacked {
                VStack(spacing: 1) {
                    bar
                    HStack {
                        Text(track == nil ? "-:--" : format(shownElapsed))
                        Spacer(minLength: 0)
                        Text(duration > 0 ? format(duration) : "-:--")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text(track == nil ? "-:--" : format(shownElapsed))
                        .frame(width: 38, alignment: .trailing)
                    bar
                    Text(duration > 0 ? "-" + format(max(duration - shownElapsed, 0)) : "-:--")
                        .frame(width: 38, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(Color.white.opacity(0.5))
    }

    private var fillStyle: LinearGradient {
        if let gradient, gradient.count > 1 {
            // v458: dark at the start, light at the tip.
            return LinearGradient(colors: Array(gradient.reversed()), startPoint: .leading, endPoint: .trailing)
        }
        if let accent {
            return LinearGradient(colors: [Color(nsColor: accent.accentDarker), Color(nsColor: accent)],
                                  startPoint: .leading,
                                  endPoint: .trailing)
        }
        return LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.9)],
                              startPoint: .leading,
                              endPoint: .trailing)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                let thin: CGFloat = slim ? 4 : 5
                let thick: CGFloat = slim ? 7 : 9
                let handle: CGFloat = slim ? 9 : 11
                Capsule().fill(Color.white.opacity(0.18)).frame(height: pressing ? thick : thin)
                Capsule().fill(fillStyle)
                    .frame(width: max(0, geo.size.width * fraction), height: pressing ? thick : thin)
                    .animation(nil, value: fraction)
                if stacked || slim {
                    Circle()
                        .fill(Color.white)
                        .frame(width: pressing ? handle + 3 : handle, height: pressing ? handle + 3 : handle)
                        .offset(x: min(max(geo.size.width * fraction - handle / 2, 0), geo.size.width - handle))
                        .animation(nil, value: fraction)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, geo.size.width > 0 else { return }
                        pressing = true
                        SeekDrag.active = true   // the vinyl's stylus stays put while the slider is held
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        dragFraction = fraction
                        // One tick when the slider is grabbed, then one for every 5% it moves.
                        let step = Int((fraction * 20).rounded())
                        if step != lastScrubStep {
                            lastScrubStep = step
                            Haptics.hf3(lockout: 0.03)
                        }
                    }
                    .onEnded { value in
                        defer {
                            pressing = false
                            dragFraction = nil
                            lastScrubStep = -1
                            SeekDrag.active = false   // let go: the stylus glides to the new place
                        }
                        guard duration > 0, geo.size.width > 0 else { return }
                        let f = min(max(value.location.x / geo.size.width, 0), 1)
                        onSeek(f * duration)
                    }
            )
        }
        .frame(height: slim ? 14 : 16)
        .onDisappear { SeekDrag.active = false }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(max(t, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Visualizer placeholder (dots idle, bars while playing)

struct MusicBars: View {
    let playing: Bool
    let active: Bool
    var compact = false

    var body: some View {
        if playing && active {
            TimelineView(.animation(minimumInterval: compact ? 1.0 / 15.0 : 1.0 / 30.0)) { context in
                bars(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else if playing {
            bars(at: 0)
        } else {
            HStack(spacing: compact ? 3 : 4) {
                ForEach(0..<6, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: compact ? 2 : 2.5, height: compact ? 2 : 2.5)
                }
            }
        }
    }

    private func bars(at t: Double) -> some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: compact ? 2.5 : 3,
                           height: (compact ? 3 : 5) + (compact ? 9 : 14) * abs(sin(t * 3.2 + Double(i) * 0.9)))
            }
        }
        .frame(height: compact ? 14 : 20)
    }
}


/// The cover in the open notch. When the song changes the cover turns around its vertical axis and the new
/// album picture is on its back, so it flips over to reveal it (the same on the Duo page).
/// Next song: it turns forward, leaning and swinging a little to the left, with a quick, tidy settle.
/// Previous song: it turns the other way, leaning and swinging to the right, with a softer, bouncier settle, like
/// winding back. Everything else (a song that just ends) counts as next.
private struct FlipArtwork: View {
    let image: NSImage?
    let trackID: String
    let side: CGFloat
    let radius: CGFloat
    let curve: RoundedCornerStyle
    let direction: () -> MediaController.SkipDirection
    /// The two sides of the cover; `turns` says which one faces front.
    @State private var faces: [NSImage?]
    @State private var turns = 0
    @State private var angle = 0.0
    /// While a flip is still turning, a newer cover goes onto the side that is arriving instead of starting another flip
    /// (a second flip replaced the side that was still on screen, so the picture popped in the middle of the turn).
    @State private var flipUntil = Date.distantPast

    init(image: NSImage?, trackID: String, side: CGFloat, radius: CGFloat, curve: RoundedCornerStyle,
         direction: @escaping () -> MediaController.SkipDirection) {
        self.image = image
        self.trackID = trackID
        self.side = side
        self.radius = radius
        self.curve = curve
        self.direction = direction
        _faces = State(initialValue: [image, nil])
    }

    private var visible: NSImage? { faces[turns % 2] }

    var body: some View {
        FlipFace(angle: angle, front: faces[0], back: faces[1], side: side, radius: radius, curve: curve)
            .frame(width: side, height: side)
            .onChange(of: image) { _, new in
                if let new { flip(to: new) }
            }
            // A song without a cover: the old cover is kept for a moment, then it flips to the plain tile.
            .task(id: image == nil ? trackID : "") {
                guard image == nil, visible != nil else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                flip(to: nil)
            }
    }

    private func flip(to new: NSImage?) {
        if let current = visible, let new, current === new { return }
        if Date() < flipUntil {
            faces[turns % 2] = new
            return
        }
        flipUntil = Date().addingTimeInterval(0.6)
        faces[(turns + 1) % 2] = new
        turns += 1
        let backward = direction() == .backward
        let target = angle + (backward ? -180 : 180)
        let motion = backward
            ? Animation.spring(response: 0.72, dampingFraction: 0.68)
            : Animation.spring(response: 0.52, dampingFraction: 0.84)
        withAnimation(motion) {
            angle = target
        }
    }
}

/// Draws the side of the cover that faces front at the given angle (animatable, so the swap happens exactly
/// when the cover is edge-on).
private struct FlipFace: View, Animatable {
    var angle: Double
    let front: NSImage?
    let back: NSImage?
    let side: CGFloat
    let radius: CGFloat
    let curve: RoundedCornerStyle

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let turn = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let showFront = turn < 90 || turn >= 270
        // Positive while the cover turns forward, negative while it turns back: the lean, the swing and the small
        // lift all follow it, so the two directions look different and neither is a copy of the other.
        let swing = sin(angle * .pi / 180)
        return face(showFront ? front : back)
            // The back is drawn pre-turned, so it reads the right way round once the cover has flipped.
            .rotation3DEffect(.degrees(showFront ? 0 : 180), axis: (x: 0, y: 1, z: 0))
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotationEffect(.degrees(swing * 6))
            .scaleEffect(1 - 0.05 * abs(swing))
            .offset(x: -swing * 6)
    }

    private func face(_ image: NSImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: curve)
                .fill(Color.white.opacity(0.09))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side > 60 ? 28 : 20, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: curve))
    }
}
