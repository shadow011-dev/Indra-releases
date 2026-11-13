import SwiftUI
import AVFoundation
import AppKit

/// v532: the intro's only sound is the thunder (IndraThunder.mp3, 5.5 s). It starts at second 1.55 of the video (the video
/// itself has no sound), plays through, and stops at once if the notch is closed under it. The old start chime is gone.
enum IntroSound {
    private static var thunder: NSSound?

    /// Called by the video itself when it reaches its thunder point, so the sound follows the picture and not a timer.
    static func playThunder() {
        guard let url = Bundle.main.url(forResource: "IndraThunder", withExtension: "mp3"),
              let rumble = NSSound(contentsOf: url, byReference: false) else { return }
        thunder?.stop()
        rumble.volume = 0.9
        thunder = rumble
        rumble.play()
    }

    static func stop() {
        thunder?.stop()
        thunder = nil
    }
}

/// v530: what the open notch shows while the intro animation plays: the bundled video (IndraIntro.mp4, a black background,
/// so it melts into the black notch) below the camera housing. It replaces the old "Indra" script greeting.
struct IntroNotchView: View {
    let metrics: NotchMetrics
    /// True once the notch has started to open (the video starts a moment later).
    let playing: Bool
    /// v531: the video has ended: it fades away and the title settles in.
    let outro: Bool
    let onStart: () -> Void
    /// v532: the video reached second 1.55 (the thunder).
    var onThunder: () -> Void = {}
    /// v532: the video is about to end: it fades away (and the title settles in) half a second before its last frame.
    let onEnd: () -> Void

    /// v532: the picture melts in the way it melts out: this long after the video starts, over 0.8 s.
    private static let fadeInDelay: Double = 0.15
    @State private var videoIn = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.introTopInset)
            ZStack {
                IntroVideoView(play: playing, onStart: videoStarted, onThunder: onThunder, onEnd: onEnd)
                    // v534: opacity only. A blur filter over the video layer showed a blank picture on some Macs.
                    .opacity(outro || !videoIn ? 0 : 1)
                    .animation(.easeInOut(duration: 0.8), value: outro)
                IntroTitle(show: outro)
            }
            .frame(width: metrics.introVideoSize.width, height: metrics.introVideoSize.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func videoStarted() {
        onStart()
        withAnimation(.easeInOut(duration: 0.8).delay(IntroNotchView.fadeInDelay)) { videoIn = true }
    }
}

/// v531: after the video: "Indra" in script fades in softly, and "CREATED BY SHADOW" settles in under it.
struct IntroTitle: View {
    let show: Bool
    @State private var name = false
    @State private var credit = false
    private let tint = Color(red: 0.80, green: 0.87, blue: 1.0)

    var body: some View {
        VStack(spacing: 6) {
            Text("Indra")
                .font(.custom("SnellRoundhand-Bold", size: 56))
                .foregroundStyle(LinearGradient(colors: [Color.white, tint.opacity(0.88)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: Color.white.opacity(0.3), radius: 4)
                .opacity(name ? 1 : 0)
                .blur(radius: name ? 0 : 6)
                .scaleEffect(name ? 1 : 0.96)
            Text("CREATED BY SHADOW")
                .font(.system(size: 9, weight: .medium))
                .tracking(2.6)
                .foregroundStyle(Color.white.opacity(0.85))
                .shadow(color: Color.white.opacity(0.5), radius: 3)
                .opacity(credit ? 1 : 0)
                .blur(radius: credit ? 0 : 3)
                .offset(y: credit ? 0 : 6)
        }
        .onChange(of: show) { _, on in
            guard on else { return }
            withAnimation(.easeOut(duration: 1.3).delay(0.45)) { name = true }
            withAnimation(.easeOut(duration: 1.1).delay(1.4)) { credit = true }
        }
    }
}

/// Plays the intro video once. `play` turning true starts it after a short wait (the notch grows meanwhile); `onStart` is
/// called at the moment it really starts, `onThunder` once at second 1.55 of the video and `onEnd` once,
/// 0.5 s before the last frame (or at the last frame if that point was somehow missed).
struct IntroVideoView: NSViewRepresentable {
    let play: Bool
    var onStart: () -> Void = {}
    var onThunder: () -> Void = {}
    var onEnd: () -> Void = {}

    final class Coordinator {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> IntroVideoHostView {
        let view = IntroVideoHostView()
        view.update(play: play, onStart: onStart, onThunder: onThunder, onEnd: onEnd)
        return view
    }

    func updateNSView(_ nsView: IntroVideoHostView, context: Context) {
        nsView.update(play: play, onStart: onStart, onThunder: onThunder, onEnd: onEnd)
    }

    /// The player, its end observer and the pending start are given back when the view leaves the screen.
    static func dismantleNSView(_ nsView: IntroVideoHostView, coordinator: Coordinator) {
        nsView.teardown()
    }
}

final class IntroVideoHostView: NSView {
    /// How long after the notch starts to open the video starts: the notch has then grown, so the first frames are not
    /// spent on a body that is still small.
    private static let startDelay: UInt64 = 350_000_000

    /// v532: second of the video where the thunder starts, and how long before the last frame the video starts to melt away.
    private static let thunderAt: Double = 1.55
    private static let outroLead: Double = 0.5
    /// Used only if the player cannot tell the video's length (IndraIntro.mp4 is 4.01 s).
    private static let fallbackLength: Double = 4.0

    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var loadFailed = false
    private var thunderPlayed = false
    private var startTask: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var onStart: () -> Void = {}
    private var onThunder: () -> Void = {}
    private var onEnd: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        prepare()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    /// The video is loaded and held on its first frame right away, so the notch opens with the picture already in it.
    private func prepare() {
        guard let url = Bundle.main.url(forResource: "IndraIntro", withExtension: "mp4") else {
            Trace.log("Intro: IndraIntro.mp4 is missing from the app")
            return
        }
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .pause
        playerLayer.player = newPlayer
        player = newPlayer
        // v534: a video that cannot be played on this Mac is logged, and the intro moves on to the title instead of a blank box.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown error"
            Task { @MainActor [weak self] in self?.videoFailed(message) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.finish()
        }
    }

    func update(play: Bool, onStart: @escaping () -> Void, onThunder: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onStart = onStart
        self.onThunder = onThunder
        self.onEnd = onEnd
        guard !finished else { return }
        if play {
            guard !started, startTask == nil else { return }
            startTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: IntroVideoHostView.startDelay)
                guard !Task.isCancelled else { return }
                self?.begin()
            }
        } else if started {
            // The notch is closing under it: the picture stops where it is.
            player?.pause()
        } else {
            startTask?.cancel()
            startTask = nil
        }
    }

    private func begin() {
        startTask = nil
        guard !started, !finished else { return }
        started = true
        guard let player, !loadFailed else {
            // No video in the app: the intro is over at once instead of leaving the notch open.
            finish()
            return
        }
        Trace.log("Intro: video playing")
        addBoundaryObserver(to: player)
        onStart()
        player.play()
    }

    /// The thunder and the early end are tied to the video's own clock, so they stay in step with the picture.
    private func addBoundaryObserver(to player: AVPlayer) {
        let seconds = player.currentItem?.duration.seconds ?? 0
        let length = seconds.isFinite && seconds > 1 ? seconds : IntroVideoHostView.fallbackLength
        let thunder = CMTime(seconds: IntroVideoHostView.thunderAt, preferredTimescale: 600)
        let outro = CMTime(seconds: max(length - IntroVideoHostView.outroLead, IntroVideoHostView.thunderAt + 0.1), preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: thunder), NSValue(time: outro)],
                                                          queue: .main) { [weak self, weak player] in
            guard let self, let player else { return }
            if !self.thunderPlayed, player.currentTime().seconds < IntroVideoHostView.thunderAt + 0.5 {
                self.thunderPlayed = true
                Trace.log("Intro: thunder")
                self.onThunder()
            } else {
                self.finish()
            }
        }
    }

    private func videoFailed(_ message: String) {
        Trace.log("Intro: the video cannot be played: \(message)")
        loadFailed = true
        if started { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onEnd()
    }

    func teardown() {
        startTask?.cancel()
        startTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerLayer.player = nil
        player = nil
        onStart = {}
        onThunder = {}
        onEnd = {}
    }
}
