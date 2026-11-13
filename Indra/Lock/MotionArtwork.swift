import AppKit
import AVFoundation
import CoreImage
import QuartzCore
import SwiftUI

/// Finds the animated cover ("motion artwork") of an album, when Apple has made one. It is looked up through the
/// public iTunes search (no key needed) and the album's public Apple Music page, which lists the video stream.
/// Most albums have none; then nothing changes and the still photo stays behind the player.
@MainActor
final class MotionArtworkStore: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var key = ""

    private var cache: [String: URL?] = [:]
    private var task: Task<Void, Never>?
    private var inFlight = false
    /// v415: "artist|title" of the song the video on screen belongs to. A different album spelling of the SAME song (the
    /// two feeds that report a song do not always agree) or a track that is gone for a moment must not tear the video
    /// down: it used to be thrown away and built again, which looked like the video stopping and then restarting.
    private var shownSong = ""
    private var clearTask: Task<Void, Never>?

    init() {
        // An older build kept a test video link here; it is not used any more.
        UserDefaults.standard.removeObject(forKey: "lockMotionTestURL")
    }

    func load(for track: TrackInfo?) {
        // A track that is back (it was only gone for a moment): the video was never taken away.
        clearTask?.cancel()
        clearTask = nil
        // v417: the video belongs to the SONG. While that same song is on, nothing about the video changes, whatever the
        // players report around it (another feed, an album spelled differently, an album missing for a moment).
        if let track, url != nil, shownSong == (track.artist + "|" + track.title).lowercased() {
            key = track.identity
            return
        }
        // Asked again for the song that is already being looked up (or shown): nothing to do.
        if let track, track.identity == key, inFlight || url != nil { return }
        task?.cancel()
        inFlight = false
        guard Preferences.lockMotionArt, let track, track.source != .identified,
              !track.album.isEmpty, !track.artist.isEmpty else {
            if track == nil, url != nil {
                // No track at the moment (a player hiccup between two songs, a refresh): the video is kept for a while
                // and only goes if nothing comes back.
                clearTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.url = nil
                    self.key = ""
                    self.shownSong = ""
                }
            } else {
                url = nil
                key = ""
                shownSong = ""
            }
            return
        }
        let cacheKey = track.identity
        key = cacheKey
        let songKey = (track.artist + "|" + track.title).lowercased()
        // The video belongs to the album, not the song: every song of an album shares one lookup.
        let albumKey = (track.artist + "|" + track.album).lowercased()
        if let known = cache[albumKey] {
            url = known
            shownSong = known == nil ? "" : songKey
            if let known { MotionAssetCache.warm(known) }
            return
        }
        // Found on an earlier day or run: no search at all, the stream is read straight away.
        if let saved = MotionArtworkStore.savedURL(albumKey) {
            if cache.count > 200 { cache.removeAll() }
            cache[albumKey] = saved
            MotionAssetCache.warm(saved)
            url = saved
            shownSong = songKey
            return
        }
        // Another song: its video goes now. The same song under another album spelling: its video keeps playing while
        // the lookup runs.
        if shownSong != songKey { url = nil }
        inFlight = true
        let artist = track.artist
        let album = track.album
        let startedAt = Date()
        Trace.log("VIDEO looking for the animated cover of \"\(album)\" by \(artist)")
        task = Task { [weak self] in
            let found = await MotionArtworkStore.lookup(artist: artist, album: album)
            Trace.log("VIDEO answer after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms: \(found == nil ? "none" : "found")\(Task.isCancelled ? " (cancelled)" : "")")
            guard !Task.isCancelled, let self else { return }
            self.inFlight = false
            if self.cache.count > 200 { self.cache.removeAll() }
            self.cache[albumKey] = found
            // Start reading the stream's playlist now, while the song is just starting, so the video is ready to
            // play the moment it appears behind the player.
            if let found {
                MotionAssetCache.warm(found)
                MotionArtworkStore.save(found, for: albumKey)
            }
            if self.key == cacheKey {
                if let found {
                    if self.url != found { self.url = found }
                    self.shownSong = songKey
                } else if self.shownSong != songKey {
                    self.url = nil
                }
            }
        }
    }

    // MARK: Albums already looked up (kept for a few days)

    private static let savedKey = "lockMotionURLCache"
    private static let savedLifetime: TimeInterval = 3 * 24 * 3600

    private static func savedURL(_ albumKey: String) -> URL? {
        guard let all = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: [String: Any]],
              let entry = all[albumKey],
              let text = entry["url"] as? String,
              let stamp = entry["at"] as? Double,
              Date().timeIntervalSince1970 - stamp < savedLifetime else { return nil }
        return URL(string: text)
    }

    private static func save(_ url: URL, for albumKey: String) {
        var all = (UserDefaults.standard.dictionary(forKey: savedKey) as? [String: [String: Any]]) ?? [:]
        let now = Date().timeIntervalSince1970
        all = all.filter { now - (($0.value["at"] as? Double) ?? 0) < savedLifetime }
        if all.count >= 150,
           let oldest = all.min(by: { (($0.value["at"] as? Double) ?? 0) < (($1.value["at"] as? Double) ?? 0) }) {
            all[oldest.key] = nil
        }
        all[albumKey] = ["url": url.absoluteString, "at": now]
        UserDefaults.standard.set(all, forKey: savedKey)
    }

    nonisolated static func lookup(artist: String, album: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(album)"),
                                  URLQueryItem(name: "entity", value: "album"),
                                  URLQueryItem(name: "limit", value: "5")]
        guard let searchURL = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: searchURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        let wanted = normalize(album)
        let match = results.first { normalize(($0["collectionName"] as? String) ?? "") == wanted }
            ?? results.first { normalize(($0["collectionName"] as? String) ?? "").contains(wanted) }
        guard let page = (match?["collectionViewUrl"] as? String).flatMap({ URL(string: $0) }) else { return nil }

        guard let master = await albumPageVideo(page) else { return nil }
        return await bestVariant(of: master)
    }

    /// v479: reads the album page as it arrives and stops as soon as the video link has been seen (plus a little more, so
    /// the link is complete), instead of waiting for the whole page. The page is large; on a first-time album this was
    /// the slowest step before the video could start.
    nonisolated private static func albumPageVideo(_ page: URL) async -> URL? {
        var request = URLRequest(url: page)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (bytes, _) = try? await URLSession.shared.bytes(for: request) else { return nil }
        var buffer = Data()
        var checkedAt = 0
        var foundAt: Int?
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if let seen = foundAt {
                    if buffer.count >= seen + 4096 { break }
                } else if buffer.count - checkedAt >= 16_384 {
                    checkedAt = buffer.count
                    if videoURL(in: String(decoding: buffer, as: UTF8.self)) != nil { foundAt = buffer.count }
                }
            }
        } catch {
            if buffer.isEmpty { return nil }
        }
        return videoURL(in: String(decoding: buffer, as: UTF8.self))
    }

    /// The sharpest stream of the video. Left to itself the player starts on a low stream and, for a short looping
    /// clip, often never climbs to the better ones, which is why the cover looked soft. The master playlist lists every
    /// size; the one with the most pixels (then the highest bitrate) is played directly. Ordinary SDR streams are
    /// preferred over HDR ones, which would look washed out behind the player. Anything unexpected falls back to the
    /// master playlist, played the old way.
    nonisolated private static func bestVariant(of master: URL) async -> URL {
        var request = URLRequest(url: master)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXT-X-STREAM-INF:") else { return master }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var best: (key: [Double], url: URL)?
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: master)?.absoluteURL else { continue }
            let fields = attributes(of: String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            var pixels = 0.0
            if let size = fields["RESOLUTION"]?.split(separator: "x"), size.count == 2,
               let w = Double(size[0]), let h = Double(size[1]) { pixels = w * h }
            let bandwidth = Double(fields["BANDWIDTH"] ?? "") ?? 0
            let range = (fields["VIDEO-RANGE"] ?? "SDR").uppercased()
            let key: [Double] = [range == "SDR" ? 1 : 0, pixels, bandwidth]
            if let current = best, !current.key.lexicographicallyPrecedes(key) { continue }
            best = (key, url)
        }
        return best?.url ?? master
    }

    /// "A=1,B=\"x,y\",C=3" as a dictionary (commas inside quotes stay in the value).
    nonisolated private static func attributes(of text: String) -> [String: String] {
        var result: [String: String] = [:]
        var name = "", value = ""
        var readingName = true, quoted = false
        func finish() {
            if !name.isEmpty { result[name] = value }
            name = ""; value = ""; readingName = true; quoted = false
        }
        for character in text {
            if readingName {
                if character == "=" { readingName = false } else { name.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "," && !quoted {
                finish()
            } else {
                value.append(character)
            }
        }
        finish()
        return result
    }

    /// The square motion video of the album page: the first stream link after the "motionDetailSquare" entry
    /// (or "motionSquareVideo1x1"), wherever it sits inside that entry.
    nonisolated private static func videoURL(in text: String) -> URL? {
        for key in ["motionDetailSquare", "motionSquareVideo1x1"] {
            guard let hit = text.range(of: key) else { continue }
            let window = String(text[hit.upperBound...].prefix(1500)).replacingOccurrences(of: "\\/", with: "/")
            if let link = window.range(of: "https:[^\"\\s\\\\]+\\.m3u8[^\"\\s\\\\]*", options: .regularExpression),
               let url = URL(string: String(window[link])) {
                return url
            }
        }
        return nil
    }

    nonisolated private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        // "Album (Deluxe Edition)" and "Album - Single" still count as "album".
        let base = lowered.components(separatedBy: " (").first?.components(separatedBy: " - ").first ?? lowered
        return base.filter { $0.isLetter || $0.isNumber }
    }
}

/// Streams whose playlists are already being read (or have been read), so a video starts without waiting for them.
@MainActor
enum MotionAssetCache {
    private static var assets: [(url: URL, asset: AVURLAsset)] = []

    static func asset(for url: URL) -> AVURLAsset {
        if let hit = assets.first(where: { $0.url == url }) { return hit.asset }
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"], completionHandler: nil)
        assets.append((url, asset))
        // Only the latest few are kept.
        if assets.count > 4 { assets.removeFirst(assets.count - 4) }
        return asset
    }

    static func warm(_ url: URL) { _ = asset(for: url) }
}

/// The animated cover as a looping, silent video that fills the screen behind a soft blur.
/// It is a real video layer: the video is decoded and shown by the graphics hardware and SwiftUI does no work
/// per frame, so it neither lags nor slows the vinyl down.
struct MotionVideoBackdrop: NSViewRepresentable {
    let url: URL
    /// The blur for the video, in screen points.
    let blur: Double
    /// False while the song is paused (the video stops with it).
    let playing: Bool
    /// v402: true once the lock screen's blurred album photo is on screen. Until then the video waits, ready, on its
    /// first picture (hidden); then, a moment after the blur screen has arrived, it starts from its beginning while
    /// it slowly comes out of the blur. False again (screen gone, card small): it goes back to its start and waits.
    let reveal: Bool

    func makeNSView(context: Context) -> MotionLayerView {
        let view = MotionLayerView()
        view.setBlur(blur)
        // Decide first whether it plays and shows, then load: a video that is mounted early (screen not up yet) must
        // not start moving behind the scenes, only get ready.
        view.setPlaying(playing)
        view.setRevealed(reveal)
        view.load(url)
        return view
    }

    func updateNSView(_ view: MotionLayerView, context: Context) {
        view.setBlur(blur)
        view.setPlaying(playing)
        view.setRevealed(reveal)
        if view.url != url { view.load(url) }
    }

    static func dismantleNSView(_ view: MotionLayerView, coordinator: ()) {
        view.stop()
    }
}

final class MotionLayerView: NSView {
    /// While the video is blurred it sits in a square of this size, blurred there and then enlarged to cover the
    /// screen (a small blur radius on a 1080 square is cheap). 1080 is the largest size Apple's square cover comes in,
    /// so nothing of the video is thrown away. With no blur the layer is the full screen size and is not scaled at all.
    private let blurredSide: CGFloat = 1080
    private var drawn: CGFloat = 1080
    private let inner = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let player = AVPlayer()
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var retriedFromURL = false
    private var fadeFallbackScheduled = false
    private var endObserver: NSObjectProtocol?
    private(set) var url: URL?
    private var wantsPlay = true
    private var blur: Double = 0
    /// v402: the blurred photo is on screen and the video may arrive (see `MotionVideoBackdrop.reveal`).
    private var revealed = false
    private var revealStarted = false
    private var revealAt: CFTimeInterval = 0
    /// Playing is only allowed from the moment the video arrives (until then it waits on its first picture).
    private var playbackAllowed = false
    private var resetWork: DispatchWorkItem?
    /// How long after the blur screen has arrived the video begins to come out of it.
    private let revealDelay: CFTimeInterval = 0.2
    /// v403: a video that should be playing but has stopped (a stall, the system pausing it) is started again. It used
    /// to stay stopped until something else on the lock screen happened to redraw (on the lyrics page that is every
    /// line, which is why it only stopped on the vinyl page).
    private var watchdog: Timer?
    private var lastWatchTime = -1.0
    private var frozenTicks = 0

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPlayback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Looks once a second whether a video that should be moving really is. It only ever pushes the SAME item (play,
    /// or a small seek); it never swaps the item for another one, because that blanks the video layer for a moment and
    /// the blurred photo shows through.
    private var waitTicks = 0

    private func checkPlayback() {
        guard revealed, playbackAllowed, wantsPlay, player.currentItem != nil else {
            frozenTicks = 0
            waitTicks = 0
            return
        }
        let now = CMTimeGetSeconds(player.currentTime())
        switch player.timeControlStatus {
        case .paused:
            Trace.log("VIDEO had stopped by itself: started again")
            player.play()
            frozenTicks = 0
            waitTicks = 0
        case .waitingToPlayAtSpecifiedRate:
            // A stall normally clears by itself as soon as data arrives. Only one that lasts 8 s gets a nudge.
            frozenTicks = 0
            waitTicks += 1
            if waitTicks >= 8 {
                Trace.log("VIDEO waited 8 s for data: nudged")
                waitTicks = 0
                player.seek(to: player.currentTime())
                player.play()
            }
        case .playing:
            waitTicks = 0
            if abs(now - lastWatchTime) < 0.01 {
                // Says it is playing but the picture has not moved for three seconds.
                frozenTicks += 1
                if frozenTicks >= 3 {
                    Trace.log("VIDEO was frozen: nudged")
                    player.seek(to: player.currentTime())
                    player.play()
                    frozenTicks = 0
                }
            } else {
                frozenTicks = 0
            }
        @unknown default:
            break
        }
        lastWatchTime = now
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        player.isMuted = true
        // (v401 turned the player's own stall handling off to start sooner; v403 puts it back: with it off, a stream
        // that runs out of buffered data stops for good instead of waiting and carrying on. The start is quick anyway,
        // because the stream is opened and primed before the screen appears.)
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        inner.bounds = CGRect(x: 0, y: 0, width: drawn, height: drawn)
        playerLayer.frame = inner.bounds
        inner.opacity = 0
        inner.addSublayer(playerLayer)
        layer?.addSublayer(inner)

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.tryFadeIn() }
        }
        // The video comes out of its blur when it is actually playing, not merely when its first picture exists.
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.tryFadeIn() }
        }
        startWatchdog()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    private var blurTarget: Double = 0
    private var blurRamp: Timer?

    /// Sets the blur. After the first value, changes glide over a third of a second (lyrics opening or the setting
    /// being switched) instead of jumping.
    func setBlur(_ value: Double) {
        guard abs(value - blurTarget) > 0.01 else { return }
        blurTarget = value
        guard window != nil, inner.opacity > 0 else {
            blurRamp?.invalidate()
            blur = value
            updateGeometry()
            return
        }
        glideBlur(duration: 0.35)
    }

    /// Moves the blur from where it is now to the target over `duration` seconds.
    private func glideBlur(duration: Double) {
        blurRamp?.invalidate()
        // A zero length would divide by zero (0 / 0 is NaN, and a NaN blur breaks the layer geometry).
        guard duration > 0.01 else {
            blur = blurTarget
            updateGeometry()
            return
        }
        let from = blur
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min((CACurrentMediaTime() - start) / duration, 1)
                let eased = t * t * (3 - 2 * t)
                self.blur = from + (self.blurTarget - from) * eased
                self.updateGeometry()
                if t >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blurRamp = timer
    }

    /// A light blur, worked out on the small square only (cheap) and then enlarged to the screen by the compositor.
    private func updateGeometry() {
        let side = max(bounds.width, bounds.height, 1)
        // No blur: draw the video at screen size, so it is never stretched (and the stream picked matches the screen).
        drawn = blur > 0.05 ? blurredSide : side
        let radius = CGFloat(blur) * drawn / side
        // A little larger than the screen, so the soft edge of the blur never shows.
        let scale = side / drawn * (1.02 + 2 * radius / drawn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.bounds = CGRect(x: 0, y: 0, width: drawn, height: drawn)
        playerLayer.frame = inner.bounds
        inner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        inner.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        if radius > 0.5, let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) {
            inner.filters = [filter]
        } else {
            inner.filters = nil
        }
        CATransaction.commit()
    }

    func setRevealed(_ on: Bool) {
        guard on != revealed else { return }
        revealed = on
        resetWork?.cancel()
        if on {
            revealAt = CACurrentMediaTime() + revealDelay
            if revealStarted, inner.opacity < 1 { revealStarted = false }
            tryFadeIn()
        } else {
            // The screen is going (or the card got small): once it has faded out, the video returns to its first
            // picture and waits for the next time.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.revealed else { return }
                self.revealStarted = false
                self.playbackAllowed = false
                self.inner.removeAllAnimations()
                self.inner.opacity = 0
                self.player.pause()
                self.player.seek(to: .zero)
            }
            resetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// Starts the arrival once the screen is up (plus a short beat for the blur screen to be seen) and the first
    /// picture is ready: the video jumps to its beginning, starts, and comes out of the blur.
    private func tryFadeIn(force: Bool = false) {
        guard revealed, !revealStarted, inner.opacity < 1, playerLayer.isReadyForDisplay else { return }
        revealStarted = true
        let wait = max(0, revealAt - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.revealed else { return }
            let begin = {
                DispatchQueue.main.async {
                    guard self.revealed else { return }
                    self.playbackAllowed = true
                    if self.wantsPlay { self.player.play() }
                    // v417: the video comes out of the blur once its picture is MOVING (before, it came out at once, and
                    // while the stream was still filling its buffer that was a still picture that started later).
                    self.fadeWhenMoving(from: CMTimeGetSeconds(self.player.currentTime()), since: CACurrentMediaTime())
                }
            }
            if CMTimeGetSeconds(self.player.currentTime()) > 0.05 {
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in begin() }
            } else {
                begin()
            }
        }
    }

    private func fadeWhenMoving(from start: Double, since began: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.revealed, self.inner.opacity < 1 else { return }
            let moved = CMTimeGetSeconds(self.player.currentTime()) - start
            // A paused song keeps its still picture (that is the right picture); a stream that has not started within
            // 12 s comes out anyway.
            if !self.wantsPlay || (self.player.timeControlStatus == .playing && moved > 0.05) || CACurrentMediaTime() - began > 12 {
                self.fadeIn()
            } else {
                self.fadeWhenMoving(from: start, since: began)
            }
        }
    }

    /// The video arrives out of a heavy blur: it starts soft and see-through over the blurred album photo, then
    /// slowly clears up to its normal blur while it becomes fully opaque.
    private func fadeIn() {
        guard inner.opacity < 1 else { return }
        let duration = 1.4
        blurRamp?.invalidate()
        blur = blurTarget + 14
        updateGeometry()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        inner.opacity = 1
        inner.add(fade, forKey: "fade")
        glideBlur(duration: duration)
    }

    func load(_ url: URL) {
        self.url = url
        retriedFromURL = false
        revealStarted = false
        inner.removeAllAnimations()
        inner.opacity = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(asset: MotionAssetCache.asset(for: url))
        item.preferredForwardBufferDuration = 12
        // Full quality: the cover is shown large, so no lower stream is chosen.
        item.preferredMaximumResolution = CGSize(width: 2160, height: 2160)
        item.preferredPeakBitRate = 0
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        if wantsPlay && playbackAllowed { player.play() }
        // If the stream cannot be opened through the early-loaded asset, open it again from its link, once.
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .failed {
                    self.retryFromURL(failed: item)
                } else if item.status == .readyToPlay, !self.playbackAllowed, self.player.currentItem === item, self.player.rate == 0 {
                    // v401: loaded while the video is still waiting (screen not up yet): prime the decoder now, so starting later
                    // shows moving pictures straight away.
                    self.player.preroll(atRate: 1.0) { _ in }
                }
            }
        }
    }

    /// Loops the video: at its end it jumps back to the start.
    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero) { _ in
                    DispatchQueue.main.async {
                        guard let self, self.wantsPlay, self.playbackAllowed else { return }
                        self.player.play()
                    }
                }
            }
        }
    }

    private func retryFromURL(failed: AVPlayerItem) {
        guard player.currentItem === failed, let url, !retriedFromURL else { return }
        retriedFromURL = true
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        item.preferredMaximumResolution = CGSize(width: 2160, height: 2160)
        item.preferredPeakBitRate = 0
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        if wantsPlay && playbackAllowed { player.play() }
    }

    func setPlaying(_ on: Bool) {
        guard on != wantsPlay || player.timeControlStatus == .paused && on else { return }
        wantsPlay = on
        if on { if playbackAllowed { player.play() } } else { player.pause() }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        blurRamp?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        url = nil
    }
}
