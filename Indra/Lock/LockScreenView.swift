import AppKit
import CoreText
import IOKit.ps
import SwiftUI

enum LockMode: Equatable {
    case compact, expanded, lyrics
}

@MainActor
final class LockScreenModel: ObservableObject {
    @Published var mode: LockMode = .compact
    /// v468: the album's colour (nil without a cover), used by the face scan animation while the vinyl is open.
    @Published var accent: NSColor?
    /// False while the player is hidden; flips with a spring so the card arrives and leaves smoothly.
    @Published var shown = false
    /// Volume / brightness shown over the lock screen (nil when there is none) and whether it is grown open.
    @Published var hud: LockHUD?
    @Published var hudVisible = false
    /// A Bluetooth device that just connected / disconnected, and whether its card is grown open.
    @Published var bluetooth: LockBluetooth?
    @Published var bluetoothVisible = false
    /// A charger plugged in / pulled out (or a low battery) while locked, and whether its card is grown open.
    @Published var battery: LockBattery?
    @Published var batteryVisible = false
}

/// Music player drawn over the macOS lock screen: a small glass card, a big-artwork view,
/// and a lyrics view. Everything outside the controls is clear, so clicks reach the lock screen.
///
/// The artwork and the card are single, persistent views. Each mode only changes where they sit and
/// how big the artwork is, so switching modes is one continuous spring (the small cover grows into the big one).
struct LockScreenView: View {
    @ObservedObject var media: MediaController
    let levels: SmoothedLevel
    @ObservedObject var model: LockScreenModel
    @StateObject private var lyrics = LyricsStore()
    @StateObject private var motion = MotionArtworkStore()
    @AppStorage(Preferences.accentVisualizerKey) private var accentVisualizer = true
    @AppStorage(Preferences.visualizerStyleKey) private var visualizerStyle = "waveform"
    @AppStorage(Preferences.lockClockStyleKey) private var clockStyle = "aurora"
    @State private var tones = ArtworkPalette.fallback
    /// v491: the cover's accent (see `ArtworkPalette.dominantAccent`): the clock and the face animation use this one colour.
    @State private var accentTint: Color?
    @State private var paletteVersion = 0
    @State private var backdropArt: NSImage?
    /// The progress bar is hidden while the widget moves and comes back when it has settled.
    @State private var sliderVisible = true
    @State private var sliderTask: Task<Void, Never>?
    /// When the bar last came back; it grows from empty to the song's position over `sliderRevealLength` seconds.
    @State private var sliderRevealStart = Date.distantPast
    /// True while that growth runs, so the bar's clock keeps ticking even when the song is paused.
    @State private var sliderRevealing = false
    private let sliderRevealLength: Double = 1.1
    @State private var paletteTask: Task<Void, Never>?
    /// True for a moment after the song changes: the decorative animations rest so the change itself is smooth.
    @State private var changing = false
    @State private var changingTask: Task<Void, Never>?

    private var track: TrackInfo? { media.track }
    private var isPlaying: Bool { track?.isPlaying ?? false }
    /// Anything that is playing (song, video, audio) can open the vinyl.
    private var canOpen: Bool { track != nil }
    /// Taps on the song name while the song has no lyrics: the first does nothing, the second explains why.
    @State private var noLyricsTaps = 0
    @State private var noLyricsNote = false
    /// What the small note says: "Looking for lyrics…" while the lookup runs, "No lyrics for this song" when it ends empty.
    @State private var lyricsNoteText = "No lyrics available for this song"
    @State private var noLyricsTask: Task<Void, Never>?
    /// The song name was tapped while its lyrics were still being looked up: open them only if they turn up.
    @State private var pendingLyrics = false

    /// How far into the song we are (0...1); the gradient's hue drifts with it.
    private var songProgress: () -> Double {
        let media = self.media
        return {
            guard let track = media.track, track.duration > 0 else { return 0.5 }
            return min(max(track.elapsed(at: Date()) / track.duration, 0), 1)
        }
    }
    /// Base motion for a mode change; the cover leads, the card follows a beat later, the panes arrive last.
    private let flow = Animation.smooth(duration: 0.46)
    private let artMotion = Animation.spring(response: 0.5, dampingFraction: 0.95)
    private let cardMotion = Animation.spring(response: 0.52, dampingFraction: 0.97).delay(0.03)
    /// Closing the vinyl: one short curve for the mode change, the cover and the card, with no delays and no spring
    /// tail, so everything lands together (different curves finishing at different times is what made it look messy).
    private let closeFlow = Animation.smooth(duration: 0.42)
    private let closeArtMotion = Animation.smooth(duration: 0.42)
    private let closeCardMotion = Animation.smooth(duration: 0.42)

    /// Where the small card sits: its bottom edge is just above macOS's own "Show message when locked" text, which
    /// is drawn above the profile picture at about 80 % of the screen's height. The card is about 146 pt tall, so its
    /// top is worked out from the bottom; on a short screen it never rises above 46 % (which would crowd the clock).
    static let compactCardBottom: CGFloat = 0.79
    /// Space between the card and macOS's message text above the profile picture. It matches the space between the
    /// profile picture and the user's name under it (about 21 pt), on top of the message's own line height.
    static let compactCardGap: CGFloat = 42
    static let compactCardHeight: CGFloat = 146

    private struct Placement {
        var big: CGFloat
        var artSide: CGFloat
        var artOrigin: CGPoint
        var artRadius: CGFloat
        var cardOrigin: CGPoint
        var lyricsOrigin: CGPoint
    }

    private func placement(for mode: LockMode, in size: CGSize) -> Placement {
        let big = min(390, size.height * 0.41)
        let cardWidth: CGFloat = 300
        let top = size.height * 0.32
        let below = top + big + 30
        switch mode {
        case .compact:
            let cardX = (size.width - cardWidth) / 2
            let cardY = max(size.height * 0.46,
                            size.height * LockScreenView.compactCardBottom
                                - LockScreenView.compactCardGap - LockScreenView.compactCardHeight)
            return Placement(big: big, artSide: 48,
                             artOrigin: CGPoint(x: cardX + 16, y: cardY + 16), artRadius: CoverCurve.radius(48),
                             cardOrigin: CGPoint(x: cardX, y: cardY),
                             lyricsOrigin: CGPoint(x: size.width * 0.13 + big + 150, y: top))
        case .expanded:
            return Placement(big: big, artSide: big,
                             artOrigin: CGPoint(x: (size.width - big) / 2, y: top), artRadius: 22,
                             cardOrigin: CGPoint(x: (size.width - cardWidth) / 2, y: below),
                             lyricsOrigin: CGPoint(x: size.width * 0.13 + big + 150, y: top))
        case .lyrics:
            let artX = size.width * 0.13
            return Placement(big: big, artSide: big,
                             artOrigin: CGPoint(x: artX, y: top), artRadius: 22,
                             cardOrigin: CGPoint(x: artX + (big - cardWidth) / 2, y: below),
                             lyricsOrigin: CGPoint(x: artX + big + 150, y: top))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let compact = model.mode == .compact
            let place = placement(for: model.mode, in: geo.size)
            ZStack(alignment: .topLeading) {
                // These layers are always mounted (invisible and paused while the card is small), so opening the
                // vinyl only fades them in. Building a full-screen mesh gradient, its glows and the clock in the
                // middle of the open animation is what used to make the first frames stutter.
                AlbumPhotoBackdrop(artwork: backdropArt, artworkID: paletteVersion, tones: tones,
                                   progress: songProgress, paused: compact || !sliderVisible || changing,
                                   // The video is loaded as soon as the card is up (paused, behind the small card), so
                                   // opening the vinyl only has to press play instead of starting a stream from nothing.
                                   // v401: mounted as soon as the address is known, not only once the screen is up, so the
                                   // stream is already open, buffered and decoded (first picture on screen, paused) when the
                                   // lock screen appears; it starts moving the moment the screen is shown.
                                   motionURL: Preferences.lockPlayer ? motion.url : nil,
                                   motionPlaying: isPlaying && !compact && model.shown,
                                   motionReveal: !compact && model.shown,
                                   lyricsActive: model.mode == .lyrics)
                    .opacity(compact ? 0 : 1)
                    .animation(compact ? .easeOut(duration: 0.34) : .easeInOut(duration: 0.45), value: compact)
                if LockFX.bassPulse {
                    BassPulse(levels: levels, playing: isPlaying && !compact && sliderVisible && !changing)
                        .opacity(compact ? 0 : 1)
                }
                if LockFX.coverGlow {
                    CoverGlow(color: tones[4],
                              playing: isPlaying && !compact,
                              center: CGPoint(x: place.artOrigin.x + place.artSide / 2,
                                              y: place.artOrigin.y + place.artSide / 2),
                              size: place.artSide)
                        .opacity(compact ? 0 : 1)
                        .animation(.easeInOut(duration: 0.45), value: compact)
                }
                if LockFX.coverBloom {
                    CoverBloom(trigger: paletteVersion,
                               color: tones[4],
                               center: CGPoint(x: place.artOrigin.x + place.artSide / 2,
                                               y: place.artOrigin.y + place.artSide / 2))
                        .opacity(compact ? 0 : 1)
                }
                clock(height: geo.size.height, shown: !compact && sliderVisible && !changing)
                    .frame(width: geo.size.width)
                    .opacity(compact ? 0 : 1)
                    // Opacity only: scaling live text with a shadow re-draws it on every frame of the animation.
                    .animation(compact ? .easeOut(duration: 0.28) : .smooth(duration: 0.4).delay(0.04), value: compact)
                    .allowsHitTesting(false)
                if model.mode == .lyrics {
                    lyricsPane(height: place.big)
                        .offset(x: place.lyricsOrigin.x, y: place.lyricsOrigin.y)
                }
                card(compact: compact)
                    .frame(width: 300)
                    .offset(x: place.cardOrigin.x, y: place.cardOrigin.y)
                    .animation(model.mode == .compact ? closeCardMotion : cardMotion, value: model.mode)
                artworkView(place: place, compact: compact)
                    .offset(x: place.artOrigin.x, y: place.artOrigin.y)
                    .animation(model.mode == .compact ? closeArtMotion : artMotion, value: model.mode)
                // Right-edge strip: previous and next songs slide out when the pointer reaches it.
                if !compact {
                    let dockLength = min(geo.size.height * 0.5, 640)
                    QueueDock(media: media, length: dockLength)
                        .offset(x: geo.size.width - QueueDock.thickness, y: (geo.size.height - dockLength) / 2)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .opacity(model.shown ? 1 : 0)
            .scaleEffect(model.shown ? 1 : 0.94, anchor: .center)
            .overlay(alignment: .topTrailing) {
                // The gradient covers the whole menu bar strip, so the battery is drawn here.
                if !compact {
                    LockStatusIcons()
                        .padding(.trailing, 30)
                        .transition(.opacity)
                }
            }
        }
        .overlay {
            // Volume / brightness: hangs below the notch, on top of everything else.
            ZStack(alignment: .top) {
                Color.clear
                if let hud = model.hud {
                    LockHUDView(hud: hud, visible: model.hudVisible, tint: hudTint)
                        .environment(\.hudGradient, media.hudGradientForHUD)
                }
                if let device = model.bluetooth {
                    LockBluetoothView(device: device, visible: model.bluetoothVisible)
                        .id(device.id)
                }
                if let battery = model.battery {
                    LockBatteryHUDView(battery: battery, visible: model.batteryVisible)
                        .id(battery.id)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            refreshPalette()
            prefetchLyrics()
            holdSlider(for: 0.7)
        }
        .onChange(of: media.artwork) { _, _ in refreshPalette() }
        .onChange(of: media.colourHint) { _, _ in refreshPalette() }
        .onChange(of: model.mode) { _, mode in
            if mode == .lyrics { prefetchLyrics() }
            holdSlider(for: 0.7)
        }
        .onChange(of: model.shown) { _, shown in
            holdSlider(for: 0.7)
            // The lock screen just came up: a lookup that failed earlier (no network yet, a busy server) is tried again now.
            if shown { prefetchLyrics() }
        }
        // Lyrics are fetched as soon as the song changes, not when the lyrics view is opened.
        .onChange(of: track?.identity) { _, _ in prefetchLyrics() }
        .onChange(of: track?.identity) { _, _ in resetNoLyricsNote() }
        .onChange(of: track?.identity) { _, _ in noteSongChange() }
        // Lyrics that turn out not to exist close the lyrics view again instead of showing an empty page.
        .onChange(of: lyrics.phase) { _, phase in
            if phase == .missing && model.mode == .lyrics { go(.expanded) }
            if phase == .found, pendingLyrics {
                pendingLyrics = false
                noLyricsTask?.cancel()
                noLyricsTaps = 0
                noLyricsNote = false
                if model.mode != .lyrics { go(.lyrics) }
            }
            if phase == .missing, pendingLyrics {
                // Nothing moves: the vinyl stays where it is. v365: the answer is shown at once, as the small
                // note. (Before, it only counted the answer and a second tap was needed, and a tap made while the
                // lookup was still running never got a note at all.) A tap that already showed it is not repeated.
                pendingLyrics = false
                if noLyricsTaps == 0 { showNoLyricsNote(retry: false) }
                noLyricsTaps = 0
            }
        }
    }

    /// The HUD takes the song's colour like the notch's does, white otherwise.
    private var hudTint: Color {
        media.hudTintForHUD
    }

    private func holdSlider(for seconds: Double) {
        sliderTask?.cancel()
        sliderVisible = false
        sliderRevealing = false
        sliderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // The bar returns empty and grows to the song's position (see `sliderReveal`).
            sliderRevealStart = Date()
            sliderRevealing = true
            sliderVisible = true
            try? await Task.sleep(nanoseconds: UInt64((sliderRevealLength + 0.15) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            sliderRevealing = false
        }
    }

    /// 0 when the bar has just appeared, easing out to 1: the share of the song's position that is drawn.
    private func sliderReveal(at date: Date) -> Double {
        let t = date.timeIntervalSince(sliderRevealStart) / sliderRevealLength
        if t >= 1 { return 1 }
        if t <= 0 { return 0 }
        let rest = 1 - t
        return 1 - rest * rest * rest
    }

    private func noteSongChange() {
        changingTask?.cancel()
        changing = true
        changingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            changing = false
        }
    }

    private func prefetchLyrics() {
        guard Preferences.lockPlayer else { return }
        lyrics.load(for: track)
        motion.load(for: track)
    }

    /// While a new song loads its artwork is briefly nil: keep the current colours instead of flashing
    /// the fallback palette, and only fall back if there is still no artwork a moment later.
    /// The colours are worked out in the background, so a song change never stalls the screen.
    private func refreshPalette() {
        paletteTask?.cancel()
        let image = media.artwork
        // Until the real cover has loaded, the small queue picture (if the song has one) already gives the colours,
        // so the clock and the backdrop change the moment the song changes.
        let source = image ?? media.colourHint
        let identity = track?.identity ?? ""

        // A picture is at hand: its colours are worked out right now (it is only a 24 x 24 sample), so nothing
        // waits for a second pass.
        if let source, let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let result = ArtworkPalette.tones(from: cg)
            let dominant = ArtworkPalette.dominantAccent(from: source)
            if image != nil { PaletteCache.shared.store(result, dominant: dominant, for: identity) }
            applyTones(result, dominant: dominant)
            // The photo behind follows only a real cover; a small hint changes the colours alone.
            if image != nil {
                backdropArt = image
                paletteVersion &+= 1
            }
            return
        }

        // No picture yet. A song seen before keeps its known colours; otherwise the colours stay as they are for
        // a moment (the cover is usually only a heartbeat away) and only then fall back to grey. The wait is long
        // enough that a slow cover never makes the colours go grey first and change a second time.
        if let known = PaletteCache.shared.tones(for: identity) {
            applyTones(known, dominant: PaletteCache.shared.dominant(for: identity))
        }
        paletteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, media.artwork == nil, media.colourHint == nil else { return }
            if PaletteCache.shared.tones(for: identity) == nil {
                applyTones(ArtworkPalette.fallback)
            }
            backdropArt = nil
            paletteVersion &+= 1
        }
    }

    /// The new colours take effect at once, whether or not the vinyl is open. A quick glide is used only while the
    /// clock can be seen; while it is hidden nothing animates, so nothing is left to play out when it is opened.
    private func applyTones(_ new: [Color], dominant: NSColor? = nil) {
        let isFallback = new == ArtworkPalette.fallback
        // One accent for the clock and the face animation: the cover's dominant colour (grey covers use the old patch-based one).
        model.accent = isFallback ? nil : (dominant ?? FaceScanColor.albumColour(from: new))
        let tint: Color? = isFallback ? nil : dominant.map { Color($0) }
        if model.shown && model.mode != .compact {
            withAnimation(.easeOut(duration: 0.22)) { tones = new; accentTint = tint }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { tones = new; accentTint = tint }
        }
    }

    // MARK: - Clock (drawn here because the gradient covers the lock screen's own)

    private func clock(height: CGFloat, shown: Bool) -> some View {
        // v523: once a second while the lock window is shown, and not at all while it sits invisible (it used to redraw the
        // date and the clock outlines every second for the whole session).
        TimelineView(.animation(minimumInterval: 1, paused: !model.shown)) { context in
            VStack(spacing: 12) {
                Text(LockClock.date(context.date))
                    .font(.system(size: LockClock.dateSize, weight: LockClock.dateWeight))
                    .foregroundStyle(Color.white.opacity(0.95))
                LockClockFace(text: LockClock.time(context.date),
                              style: LockClockStyle.resolve(clockStyle),
                              tint: accentTint ?? ArtworkPalette.accent(of: tones),
                              animated: shown,
                              inline: model.mode == .lyrics,
                              glide: model.shown && model.mode != .compact)
            }
        }
        .padding(.top, height * 0.097)
    }

    private func go(_ mode: LockMode) {
        withAnimation(mode == .compact ? closeFlow : flow) { model.mode = mode }
    }

    // MARK: - Artwork

    /// The one cover view. In the small card it is the album cover; opened up it turns into a spinning vinyl
    /// record with the cover as its label: the cover rounds off and shrinks while the disc grows out from
    /// behind it. It is laid out at full size and only scaled and moved, so growing from the thumbnail to
    /// the big record costs no re-layout.
    private func artworkView(place: Placement, compact: Bool) -> some View {
        let morph = place.artSide / place.big
        return VinylPod(artwork: media.artwork, trackKey: track?.identity ?? "", playing: isPlaying,
                        size: place.big, open: !compact, coverRadius: place.artRadius / morph,
                        onCollapse: { Haptics.hf1(scope: .lock); go(.compact) },
                        onToggle: {
                            // The needle landing or lifting: a tap as it is pressed.
                            Haptics.hf1(scope: .lock)
                            media.togglePlayPause()
                        },
                        progress: { date in
                            // Read when drawn, so the stylus always follows the current position.
                            guard let current = media.track, current.duration > 0 else { return 0 }
                            return current.elapsed(at: date) / current.duration
                        })
            .frame(width: place.big, height: place.big)
            .hoverLift(compact ? 1.0 : 1.02)
            .onTapGesture { if compact && canOpen { Haptics.hf1(scope: .lock); go(.expanded) } }
            .scaleEffect(morph, anchor: .topLeading)
    }

    // MARK: - Card

    private func card(compact: Bool) -> some View {
        let frosted = compact || sliderVisible
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                // In the small card the first 40 pt (plus the gap) are left free for the artwork thumbnail.
                VStack(alignment: compact ? .leading : .center, spacing: 1) {
                    Text(track?.title ?? "Not Playing")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    if let artist = track?.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                // Clicking the song name turns lyrics on (and off again).
                // v398: the tap area is the whole name block (full width, full row height), not just the letters:
                // the frame comes BEFORE the content shape, so a click beside or just above a short title counts.
                // Applied before the padding, so the artwork thumbnail keeps its own tap.
                .frame(maxWidth: .infinity, minHeight: 48, alignment: compact ? .leading : .center)
                .contentShape(Rectangle())
                .onTapGesture {
                    IndraLog.crumb("Lock lyrics tap (\(lyrics.phase), mode \(model.mode))")
                    Haptics.hf2(scope: .lock)
                    titleTapped()
                }
                .padding(.leading, compact ? 60 : 0)
                .id(track?.identity ?? "none")
                .transition(.blurReplace)
                .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
                // The same visualizer as the notch (waveform, vibrating circle, or none), in every lock screen view.
                VisualizerView(level: levels,
                               playing: isPlaying,
                               active: model.shown,
                               compact: true,
                               tint: visualizerTint)
            }
            .frame(minHeight: 48)
            // Paused while the card is moving (the bar is hidden then), so the morph has the GPU to itself.
            // v523: also paused while the lock window is not shown. The window stays in place (invisible) all day, and this bar
            // was redrawn up to 60 times a second whenever music played, with nothing on screen to see it.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: (!isPlaying && !sliderRevealing) || !sliderVisible || !model.shown)) { context in
                ProgressRow(track: track, date: context.date, onSeek: media.seek(to:), accent: nil,
                            reveal: sliderReveal(at: context.date), smooth: true)
            }
            .opacity(sliderVisible ? 1 : 0)
            .animation(sliderVisible ? .easeOut(duration: 0.18) : nil, value: sliderVisible)
            .allowsHitTesting(sliderVisible)
            controls
        }
        .animation(.smooth(duration: 0.55), value: track?.identity)
        .padding(16)
        .frame(width: 300)
        .background {
            ZStack {
                // While the card is travelling (the progress bar is hidden then) the live blur of what is behind it is
                // swapped for a plain tint, because re-blurring a moving, fading backdrop on every frame is what made
                // the transition lag on the lock screen. It fades back in once the card has settled.
                // The small card (compact) never travels, so it is frosted from its very first frame; the plain tint is
                // only used while the card is moving between the small and the open layout.
                cardGlass(frosted: frosted)
            }
            // The shadow belongs to the background only, so the live progress bar is not re-blurred every tick.
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .overlay(alignment: .top) {
            if noLyricsNote {
                Text(lyricsNoteText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        ZStack {
                            Capsule().fill(Color.black.opacity(0.35))
                            Capsule().fill(.ultraThinMaterial)
                        }
                    }
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    // A bit lower than before (was -36).
                    .offset(y: -22)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.smooth(duration: 0.25), value: noLyricsNote)
    }

    /// The card's glass: pure, fully clear Liquid Glass, always the same. It used to be swapped for a faint tint while
    /// the card travelled and faded back in afterwards, which showed as the card's background and border changing
    /// or arriving late after the vinyl opened or closed. Clear glass has no blur to re-render, so it can stay on.
    @ViewBuilder
    private func cardGlass(frosted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(macOS 26.0, *) {
            Rectangle().fill(Color.clear).glassEffect(.clear, in: shape)
        } else {
            shape.fill(Color.black.opacity(0.04))
        }
    }

    /// Song-name tap: opens (or closes) the lyrics. A song without lyrics ignores the first tap and
    /// answers the second with a small "No lyrics" note.
    private func titleTapped() {
        guard canOpen else { return }
        if model.mode == .lyrics { go(.expanded); return }
        switch lyrics.phase {
        case .found:
            go(.lyrics)
        case .missing:
            // v365: the note shows on this very tap. The lookup is also repeated quietly (a failure earlier from
            // the network or a busy server must not stand as "no lyrics"); if lyrics turn up they open and the
            // note goes away. `noLyricsTaps = 1` marks that this tap already showed the note.
            pendingLyrics = true
            noLyricsTaps = 1
            showNoLyricsNote(retry: true)
        case .idle, .loading:
            // Never slide the vinyl over to make room for lyrics that may not exist: wait for the answer.
            // v418: no "Looking for lyrics…" note any more. The tap is remembered: the lyrics open by themselves if they
            // turn up, and "No lyrics available for this song" shows (within about 2 s) if they do not.
            pendingLyrics = true
            noLyricsTaps = 0
            if lyrics.phase == .idle { prefetchLyrics() }
        }
    }

    private func showNoLyricsNote(retry: Bool, text: String = "No lyrics available for this song", seconds: Double = 1.8) {
        noLyricsTask?.cancel()
        lyricsNoteText = text
        noLyricsNote = true
        if retry { prefetchLyrics() }   // a failed network lookup gets another try
        noLyricsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            noLyricsNote = false
        }
    }

    private func resetNoLyricsNote() {
        pendingLyrics = false
        noLyricsTask?.cancel()
        noLyricsTaps = 0
        noLyricsNote = false
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if media.track?.source == .system {
                Color.clear.frame(width: 32, height: 32)
            } else {
                Button {
                    media.cycleRepeat()
                } label: {
                    Image(systemName: media.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(media.repeatMode == .off ? 0.45 : 1))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.86))
            }
            Spacer(minLength: 0)
            control("backward.fill", size: 23) { media.previousTrack() }
            control(isPlaying ? "pause.fill" : "play.fill", size: 30) { media.togglePlayPause() }
            control("forward.fill", size: 23) { media.nextTrack() }
            Spacer(minLength: 0)
            AirPlayButton()
                .frame(width: 32, height: 32)
        }
        .animation(.snappy(duration: 0.25), value: isPlaying)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.hf1(scope: .lock)   // previous / play / pause / next
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 54, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.86))
        .hoverLift(1.08)
    }

    // MARK: - Visualizer

    /// On the lock screen the visualizer (waveform or vibrating circle) is always white.
    private var visualizerTint: Color { Color.white }

    // MARK: - Lyrics

    @ViewBuilder
    private func lyricsPane(height: CGFloat) -> some View {
        Group {
            switch lyrics.phase {
            case .idle, .loading:
                // v418: only a quiet spinner, never a "Looking for lyrics" text.
                ProgressView().controlSize(.small)
            case .missing:
                Text("No lyrics available for this song")
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.white.opacity(0.55))
                    // A bit lower than the middle of the pane.
                    .offset(y: 28)
            case .found:
                if lyrics.isSynced {
                    SyncedLyrics(lines: lyrics.lines, media: media, height: height)
                        .id(lyrics.generation)
                } else {
                    PlainLyrics(lines: lyrics.lines, media: media)
                        .id(lyrics.generation)
                }
            }
        }
        .frame(width: 440, height: height, alignment: .leading)
        // The lyrics slide in after the artwork has started moving left, and leave quickly.
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(x: 56))
                .animation(.spring(response: 0.5, dampingFraction: 0.96).delay(0.08)),
            removal: .opacity.combined(with: .offset(x: 24))
                .animation(.easeIn(duration: 0.14))))
        .animation(.smooth(duration: 0.4), value: lyrics.phase)
    }
}

// MARK: - Lyric lists

private let lyricsFadeMask = LinearGradient(
    stops: [.init(color: .clear, location: 0),
            .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1)],
    startPoint: .top,
    endPoint: .bottom)

private struct LineHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One step of the "current line" change: how far the line is lifted, how blurred and how faint it is.
private struct LyricLineSwap: ViewModifier {
    let lift: CGFloat
    let blur: CGFloat
    let opacity: Double
    var scale: CGFloat = 1
    var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .shadow(color: Color.white.opacity(glow), radius: 18)
            .scaleEffect(scale, anchor: .leading)
            .offset(y: lift)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// Time-synced lyrics. Every line is placed by hand, so when the song moves to the next line the lines
/// glide up one after another (the ones further down start slightly later), like Apple Music.
/// The current line is bright and full size, the others dimmer and a little smaller (never blurred).
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    @ObservedObject var media: MediaController
    let height: CGFloat
    @State private var heights: [Int: CGFloat] = [:]
    @State private var current: Int?
    /// Line shown while two-finger swiping (before the song actually jumps there).
    @State private var preview: Int?
    @State private var scrubber = LyricScrubber()
    @AppStorage(Preferences.lyricsFontKey) private var lyricsFont = Preferences.lyricsFontDefault
    @AppStorage(Preferences.lyricsDisplayKey) private var lyricsDisplay = Preferences.defaultLyricsDisplay

    init(lines: [LyricLine], media: MediaController, height: CGFloat) {
        self.lines = lines
        _media = ObservedObject(wrappedValue: media)
        self.height = height
        let elapsed = media.track?.elapsed(at: Date()) ?? 0
        _current = State(initialValue: lines.lastIndex(where: { $0.time <= elapsed + 0.2 }))
    }

    /// The lyrics box: wide enough for the magnified current line to stay inside it.
    private let width: CGFloat = 440
    /// How much the line being sung is magnified.
    private let magnify: CGFloat = 1.16
    /// Extra room on both sides so a magnified word or a script swash is never cut off.
    private let pad: CGFloat = 90
    private let gap: CGFloat = 34
    /// Space taken by the "waiting" dots row above the first line.
    private let dotsBlock: CGFloat = 42

    var body: some View {
        content
            .background(ticker)
            .offset(x: -pad)
            .onHover { scrubber.hovering = $0 }
            .onAppear {
                scrubber.configure(lines: lines, media: media, synced: true) { preview = $0 }
                scrubber.start()
            }
            .onDisappear { scrubber.stop() }
    }

    /// Only the line being sung (the default), or all the lyrics.
    @ViewBuilder
    private var content: some View {
        if lyricsDisplay == "line" {
            singleLine(current: preview ?? current)
        } else {
            stack(current: preview ?? current)
                .mask(lyricsFadeMask)
        }
    }

    /// "Current line" view: only the line being sung is shown. When the song moves on, the old line lifts away
    /// and blurs out while the next one rises into its place and comes into focus.
    private func singleLine(current: Int?) -> some View {
        ZStack(alignment: .leading) {
            if let shown = current, lines.indices.contains(shown) {
                let line = lines[shown]
                styled(line.text)
                    .frame(width: width / magnify, alignment: .leading)
                    .scaleEffect(magnify, anchor: .leading)
                    .padding(.leading, pad)
                    .id(line.id)
                    .contentShape(Rectangle())
                    .onTapGesture { Haptics.hf2(scope: .lock); media.seek(to: line.time) }
                    // The new line pops: it rises from a little below and slightly small, overshoots a touch
                    // as it settles, and a soft glow flashes and fades. The old line is quick: it lifts
                    // away, shrinks and blurs out so it never lingers under the new one.
                    .transition(.asymmetric(
                        insertion: .modifier(active: LyricLineSwap(lift: 26, blur: 12, opacity: 0, scale: 0.82, glow: 0.9),
                                             identity: LyricLineSwap(lift: 0, blur: 0, opacity: 1, scale: 1, glow: 0))
                            .animation(.spring(response: 0.46, dampingFraction: 0.58).delay(0.06)),
                        removal: .modifier(active: LyricLineSwap(lift: -22, blur: 14, opacity: 0, scale: 0.94, glow: 0),
                                           identity: LyricLineSwap(lift: 0, blur: 0, opacity: 1, scale: 1, glow: 0))
                            .animation(.easeIn(duration: 0.22))))
            } else {
                dots(active: true)
                    .padding(.leading, pad)
                    .transition(.opacity)
            }
        }
        .frame(width: width + pad * 2, height: height, alignment: .leading)
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: current)
    }

    private func index(at date: Date) -> Int? {
        let elapsed = media.track?.elapsed(at: date) ?? 0
        return lines.lastIndex(where: { $0.time <= elapsed + 0.2 })
    }

    /// Watches the song position and only updates `current` when the line really changes.
    private var ticker: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { context in
            Color.clear
                .onChange(of: index(at: context.date)) { _, new in current = new }
        }
    }

    private func tops() -> [CGFloat] {
        var result: [CGFloat] = []
        var y = dotsBlock
        for line in lines {
            result.append(y)
            y += (heights[line.id] ?? 36) + gap
        }
        return result
    }

    /// Lines already sung step aside at once; the ones still to come follow one after another.
    private func motion(_ distance: Int) -> Animation {
        if distance <= 0 { return .spring(response: 0.42, dampingFraction: 0.9) }
        return .spring(response: 0.5, dampingFraction: 0.86).delay(Double(min(distance, 6)) * 0.03)
    }

    private func stack(current: Int?) -> some View {
        let positions = tops()
        let anchor = height * 0.38
        let shift = anchor - (current.map { positions[$0] } ?? 0)
        return ZStack(alignment: .topLeading) {
            dots(active: current == nil)
                .offset(x: pad, y: shift)
                .animation(motion(0), value: current)
            ForEach(lines) { line in
                let distance = current.map { line.id - $0 } ?? (line.id + 1)
                row(line, distance: distance)
                    .offset(x: pad, y: positions[line.id] + shift)
                    .animation(abs(distance) > 8 ? nil : motion(distance), value: current)
            }
            if LockFX.breakDots, preview == nil, let shown = current, shown + 1 < lines.count {
                breakDots(after: shown, top: positions[shown] + shift)
                    .animation(motion(0), value: current)
            }
        }
        .frame(width: width + pad * 2, height: height, alignment: .topLeading)
        .opacity(heights.isEmpty ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: heights.isEmpty)
        .onPreferenceChange(LineHeightKey.self) { heights = $0 }
    }

    private func row(_ line: LyricLine, distance: Int) -> some View {
        let isCurrent = distance == 0
        let opacity: Double = isCurrent ? 1 : (distance < 0 ? max(0.18, 0.46 - 0.12 * Double(-distance - 1))
                                                              : max(0.18, 0.5 - 0.14 * Double(distance - 1)))
        // Lines far above or below the visible part are not drawn at all (they only keep their place),
        // so a line change animates a handful of rows instead of the whole song.
        let far = abs(distance) > 7
        return styled(line.text)
            // Lines wrap at the box width divided by the magnification, so the magnified line fills the box
            // but never goes past it.
            .frame(width: width / magnify, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: LineHeightKey.self, value: [line.id: proxy.size.height])
            })
            // The line being sung is magnified; the others sit back.
            .scaleEffect(isCurrent ? magnify : depthScale(distance), anchor: .leading)
            .rotation3DEffect(.degrees(depthTilt(distance)), axis: (x: 1, y: 0, z: 0), anchor: .leading, perspective: 0.4)
            .opacity(far ? 0 : opacity)
            .animation(far ? nil : motion(distance), value: distance)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.hf2(scope: .lock)
                media.seek(to: line.time)
            }
    }

    // MARK: Line text and depth

    private func styled(_ text: String) -> some View {
        Text(text)
            .font(LyricsFont.resolve(lyricsFont).font(size: 28))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func depthScale(_ distance: Int) -> CGFloat {
        guard LockFX.lyricDepth else { return 0.92 }
        return max(0.8, 0.94 - 0.03 * CGFloat(max(abs(distance) - 1, 0)))
    }

    private func depthTilt(_ distance: Int) -> Double {
        guard LockFX.lyricDepth, distance != 0 else { return 0 }
        return -Double(distance.signum()) * Double(min(abs(distance), 4)) * 3.5
    }

    /// Three dots in the gap after a line, filling up one by one while the music plays without lyrics.
    private func breakDots(after index: Int, top: CGFloat) -> some View {
        let y = top + (heights[index] ?? 36) + (gap - 9) / 2
        return TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !(media.track?.isPlaying ?? false))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let elapsed = media.track?.elapsed(at: context.date) ?? 0
            let start = lines[index].time + 6
            let end = lines[index + 1].time - 1.2
            let length = end - start
            let progress = length > 2 ? min(max((elapsed - start) / length, 0), 1) : 0
            let showing = length > 2 && elapsed > start && elapsed < lines[index + 1].time
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { dot in
                    let fill = min(max(progress * 3 - Double(dot), 0), 1)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .scaleEffect(0.6 + 0.4 * fill + 0.06 * sin(t * 2.4 + Double(dot)))
                        .opacity(0.25 + 0.7 * fill)
                }
            }
            .opacity(showing ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: showing)
        }
        .offset(x: pad + 4, y: y)
        .allowsHitTesting(false)
    }

    private func dots(active: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .scaleEffect(active ? 0.8 + 0.25 * sin(t * 3 + Double(i) * 0.7) : 0.7)
                        .opacity(active ? 0.95 : 0.35)
                }
            }
        }
        .frame(height: 20)
    }
}

/// Lyrics without timing: a plain scrolling list.
private struct PlainLyrics: View {
    let lines: [LyricLine]
    let media: MediaController
    @State private var scrubber = LyricScrubber()
    @AppStorage(Preferences.lyricsFontKey) private var lyricsFont = Preferences.lyricsFontDefault

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 27) {
                ForEach(lines) { line in
                    Text(line.text)
                        .font(LyricsFont.resolve(lyricsFont).font(size: 28))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 60)
            // Room on both sides so swashes of script fonts are never cut off.
            .padding(.horizontal, 90)
        }
        .frame(width: 440 + 180)
        .mask(lyricsFadeMask)
        .offset(x: -90)
        .onHover { scrubber.hovering = $0 }
        .onAppear {
            scrubber.configure(lines: lines, media: media, synced: false) { _ in }
            scrubber.start()
        }
        .onDisappear { scrubber.stop() }
    }
}

/// Two-finger swipes over the lyrics move the song. Synced lyrics: swipe up / down to move line by line,
/// swipe left / right to skip 5 seconds per step. Plain lyrics: left / right only (up / down scrolls).
/// The song jumps when the fingers lift.
@MainActor
private final class LyricScrubber {
    var hovering = false {
        didSet { LockGesture.overLyrics = hovering }
    }
    private var lines: [LyricLine] = []
    private var media: MediaController?
    private var synced = true
    private var onPreview: ((Int?) -> Void)?
    private var monitor: Any?
    private var settle: Task<Void, Never>?
    private var active = false
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var baseIndex = -1
    private var baseTime: TimeInterval = 0
    private var lastIndex: Int?
    private var lastStep = 0
    private var wasAtEdge = false
    private var pendingTime: TimeInterval = 0

    func configure(lines: [LyricLine], media: MediaController, synced: Bool, onPreview: @escaping (Int?) -> Void) {
        self.lines = lines
        self.media = media
        self.synced = synced
        self.onPreview = onPreview
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let used = MainActor.assumeIsolated { self.handle(event) }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        settle?.cancel()
        onPreview?(nil)
        active = false
        LockGesture.overLyrics = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard hovering, !lines.isEmpty, let media else { return false }
        // Inertia after the fingers lift is swallowed so it cannot start another swipe.
        if !event.momentumPhase.isEmpty { return true }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale
        // Plain lyrics: let up / down scroll the list normally.
        if !synced, !active, abs(dy) >= abs(dx) { return false }
        if !active {
            active = true
            accX = 0
            accY = 0
            lastStep = 0
            wasAtEdge = false
            lastIndex = nil
            baseTime = media.track?.elapsed(at: Date()) ?? 0
            baseIndex = lines.lastIndex(where: { $0.time <= baseTime + 0.2 }) ?? -1
            pendingTime = baseTime
        }
        accX += dx
        accY += dy
        var previewIndex: Int?
        var step = 0
        var atEdge = false
        let horizontal = abs(accX) > abs(accY)
        if horizontal {
            // Swipe left = forward, right = back; 40 pt = 5 seconds.
            step = Int((-accX / 40).rounded())
            let wanted = baseTime + Double(step) * 5
            let target = min(max(wanted, 0), max((media.track?.duration ?? 0) - 1, 0))
            atEdge = target != wanted
            pendingTime = target
            if synced { previewIndex = lines.lastIndex(where: { $0.time <= target }) ?? 0 }
        } else if synced {
            // Swipe up = next lines, down = previous lines; 38 pt = one line.
            step = Int((-accY / 38).rounded())
            let target = min(max(baseIndex + step, 0), lines.count - 1)
            atEdge = target != baseIndex + step
            pendingTime = lines[target].time
            previewIndex = target
        }
        if step != lastStep {
            lastStep = step
            wasAtEdge = atEdge
        }
        if synced, previewIndex != lastIndex {
            if previewIndex != (lastIndex ?? baseIndex) { Haptics.hf2(lockout: 0.03, scope: .lock) }   // a new lyric comes into focus
            lastIndex = previewIndex
            onPreview?(previewIndex)
        }
        let ended = event.phase == .ended || event.phase == .cancelled
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ended ? 120_000_000 : 380_000_000)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
        return true
    }

    private func finish() {
        guard active, let media else { return }
        active = false
        if lastStep != 0 {
            media.seek(to: pendingTime)
        }
        // Keep showing the chosen line until the song has caught up.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.active else { return }
            self.onPreview?(nil)
        }
    }
}

/// Date and time text for the lock screen clock.
enum LockClock {
    // Tuning knobs for matching the system lock screen clock (outlined digits).
    static let dateSize: CGFloat = 22
    static let dateWeight: Font.Weight = .semibold
    static let timeSize: CGFloat = 132
    /// Digits are narrowed a little and pulled together to match the system clock.
    static let timeWidthScale: CGFloat = 0.86
    static let timeTracking: CGFloat = -3
    static let outlineWidth: CGFloat = 2.4

    // v366: the clock asks for its text every second (every frame in the animated styles). Two DateFormatters used to be
    // built and configured on EVERY call, which is by far the most expensive thing a formatter does. They are now
    // built once and rebuilt only when the language / region, the 12 / 24-hour setting or the calendar changes.
    // The time zone follows the system (`autoupdatingCurrent`), so travelling does not leave a stale clock.
    private static let formatterLock = NSLock()
    private static var formatterKey = ""
    private static var dateFormatter = DateFormatter()
    private static var timeFormatter = DateFormatter()

    private static func formatters() -> (date: DateFormatter, time: DateFormatter) {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let locale = Locale.autoupdatingCurrent
        let key = "\(locale.identifier)|\(String(describing: locale.hourCycle))|\(Calendar.autoupdatingCurrent.identifier)"
        if key != formatterKey {
            formatterKey = key
            let day = DateFormatter()
            day.locale = locale
            day.timeZone = .autoupdatingCurrent
            day.setLocalizedDateFormatFromTemplate("EEEdMMM")
            let clock = DateFormatter()
            clock.locale = locale
            clock.timeZone = .autoupdatingCurrent
            clock.setLocalizedDateFormatFromTemplate("jmm")
            var format = clock.dateFormat ?? "h:mm"
            format = format.replacingOccurrences(of: "a", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .trimmingCharacters(in: .whitespaces)
            clock.dateFormat = format
            dateFormatter = day
            timeFormatter = clock
        }
        return (dateFormatter, timeFormatter)
    }

    static func date(_ date: Date) -> String {
        formatters().date.string(from: date).replacingOccurrences(of: ",", with: "")
    }

    static func time(_ date: Date) -> String {
        var text = formatters().time.string(from: date)
        if text.hasPrefix("0") { text.removeFirst() }
        return text
    }
}

/// Watches the battery for the lock screen: it is re-read the moment macOS reports a power change (the charger being
/// plugged in or out, the percentage moving), and once more shortly after, because "charging" is reported a beat later.
@MainActor
private final class LockBatteryWatcher: ObservableObject {
    @Published private(set) var info: BatteryInfo?
    private var source: CFRunLoopSource?
    private var followUp: Task<Void, Never>?

    init() {
        info = BatteryInfo.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let watcher = Unmanaged<LockBatteryWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }
        if let created = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            // Common modes: the update also arrives while the screen is busy animating.
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
            source = created
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func refresh() {
        let new = BatteryInfo.read()
        if new != info { info = new }
    }

    private func changed() {
        refresh()
        followUp?.cancel()
        followUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}

/// Battery, drawn in the menu bar strip because the lyrics / artwork gradient covers the real one.
private struct LockStatusIcons: View {
    @StateObject private var watcher = LockBatteryWatcher()

    var body: some View {
        Group {
            if let battery = watcher.info {
                LockBatteryView(info: battery)
            }
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.25), value: watcher.info)
        // A slow re-read as a safety net, in case a notification is ever missed.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                watcher.refresh()
            }
        }
    }
}

/// Menu-bar style battery: percentage, outlined capsule with a level fill, and a small terminal.
/// The fill is green while charging, red at 20% or less, white otherwise.
private struct LockBatteryView: View {
    let info: BatteryInfo

    private var level: CGFloat { CGFloat(max(0, min(100, info.percent))) / 100 }

    private var fill: Color {
        if info.charging { return Color(red: 0.30, green: 0.85, blue: 0.39) }
        if info.percent <= 20 { return Color(red: 1.0, green: 0.27, blue: 0.23) }
        return Color.white.opacity(0.92)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text("\(info.percent)%")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.92))
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(fill)
                        .frame(width: max(5, 21 * level), height: 9)
                        .padding(.leading, 2)
                    Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                }
                .frame(width: 25, height: 13)
                .overlay {
                    if info.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.45), radius: 1)
                    }
                }
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 2, height: 5)
            }
        }
    }
}


/// The cover picture. A new cover dissolves in over the old one while it settles from slightly larger and
/// the old one eases back; an empty cover while the next song loads never flashes the placeholder.
struct ArtworkLayers: View {
    let image: NSImage?
    let size: CGFloat
    @State private var current: NSImage?
    @State private var previous: NSImage?
    @State private var latest: NSImage?
    @State private var fade: CGFloat = 1
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let previous {
                // v418: the old cover stays exactly as it is while the new one dissolves in over it. It used to shrink 4 %
                // and dim to 70 % the instant the change began (a visible jump and a dark pulse), then come back.
                picture(previous)
            }
            if let current {
                picture(current)
                    .scaleEffect(1.08 - 0.08 * fade)
                    .opacity(fade)
            } else {
                // v401: nothing is playing: a plain black album (it used to be a pale square with a note).
                Color.black
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear {
            current = image
            latest = image
        }
        .onChange(of: image) { _, new in
            latest = new
            settleTask?.cancel()
            if let new {
                // v416: the new cover comes in over the old one in 0.42 s (it was 0.9 s, which felt slow).
                previous = current
                current = new
                fade = 0
                withAnimation(.smooth(duration: 0.42)) { fade = 1 }
                settleTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 520_000_000)
                    guard !Task.isCancelled else { return }
                    previous = nil
                }
            } else {
                // The next song has no cover yet: the old cover stays until the new one arrives (v416: up to 3 s, it was
                // 0.6 s, after which the black placeholder showed and the new cover then dissolved in over black).
                settleTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, latest == nil else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        previous = nil
                        current = nil
                    }
                }
            }
        }
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
    }
}

/// Colours of songs already seen, so a song that comes back (a loop, a skip back) is coloured at once.
@MainActor
final class PaletteCache {
    static let shared = PaletteCache()
    private var entries: [String: [Color]] = [:]
    private var dominants: [String: NSColor] = [:]
    private var order: [String] = []

    func tones(for identity: String) -> [Color]? { entries[identity] }
    func dominant(for identity: String) -> NSColor? { dominants[identity] }

    func store(_ tones: [Color], dominant: NSColor? = nil, for identity: String) {
        guard !identity.isEmpty else { return }
        if entries[identity] == nil { order.append(identity) }
        entries[identity] = tones
        dominants[identity] = dominant
        while order.count > 30 {
            let old = order.removeFirst()
            entries[old] = nil
            dominants[old] = nil
        }
    }
}
