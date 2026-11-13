import AppKit
import CryptoKit
import Network
import SwiftUI

/// Reads playback from Apple Music and Spotify through their public
/// distributed notifications and controls them through Apple Events.
/// Event-driven: no polling.
@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var track: TrackInfo? {
        didSet {
            scheduleEndWatch()
            if track?.identity != oldValue?.identity {
                Trace.log("TRACK \(track.map { "\($0.source.rawValue) | \($0.title) | \($0.artist) | \($0.album)" } ?? "none")")
            }
            if let now = track, let id = MediaController.appID(of: now) { lastPlayingAppID = id }
            // Each player keeps its own list: the moment the song moves to another kind of player (Spotify to a
            // YouTube video, say), the old player's list goes, so it can never show next to the new song.
            if let now = track, let before = oldValue, now.source != before.source {
                queueToken += 1
                queue = []
                queueCurrentEntry = nil
                queueNote = nil
            }
            if track?.identity != oldValue?.identity {
                trackChangedAt = Date()
                // A different song than the one before (not playback starting or stopping, and not the very first
                // song): the closed notch can show its title and artist for a moment.
                if let now = track {
                    if let previous = lastSongIdentity, previous != now.identity,
                       !MediaController.isRefinement(from: oldValue, to: now) {
                        pendingSongChange?.cancel()
                        pendingSongChange = nil
                        // v563: the card used to appear at once with whatever the player had reported so far, and when a song
                        // ends by itself the player reports its new song in steps (the album, the artist, then the title): the
                        // card showed the song that had just finished and swapped to the new one a moment later. Now:
                        //  - while the TITLE is still the old song's (only the artist, the album or the source changed), the
                        //    card waits for the real title; if none comes it is a genuinely different release of the same song;
                        //  - once the title is new, the card waits a short moment for the rest of the steps. Every further step
                        //    starts the wait again, so exactly one card appears, for the song that is playing.
                        let identity = now.identity
                        let titleStillOld = oldValue?.title == now.title
                        let wait: UInt64 = titleStillOld ? 1_500_000_000 : 350_000_000
                        pendingSongChange = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: wait)
                            guard !Task.isCancelled, let self, self.track?.identity == identity else { return }
                            self.pendingSongChange = nil
                            self.onSongChange?()
                        }
                    }
                    lastSongIdentity = now.identity
                }
                // A song change nobody asked Indra for (a media key, the player itself): if the new song is one of the
                // songs just before this one in the playlist, it went backward.
                if Date().timeIntervalSince(skipAt) > 6, let now = track,
                   queue.contains(where: { $0.id < 0 && $0.title == now.title && $0.artist == now.artist }) {
                    noteSkip(.backward)
                }
                // Apple Music: the strip is refreshed by itself, so it is right before the pointer reaches it.
                if track?.source == .music { scheduleQueueRefresh() }
            }
        }
    }
    /// The identity of the last song that was playing, so a song change is told apart from playback merely resuming.
    private var lastSongIdentity: String?
    /// v564: the same song from the same app with its artist or album filled in or changed (a browser tab announcing its
    /// metadata in steps): not a new song, so no song card and no new cover.
    private static func isRefinement(from old: TrackInfo?, to new: TrackInfo) -> Bool {
        guard let old, old.source == .system, new.source == .system,
              old.appBundleID == new.appBundleID, sameTitle(old.title, new.title) else { return false }
        // The artist may be missing at first (the app's name stands in for it): that counts as "not announced yet". Two different
        // artists with the same title are two different songs.
        let app = old.appBundleID.flatMap { SystemNowPlaying.appName(for: $0) } ?? ""
        func blank(_ text: String) -> Bool { text.isEmpty || sameTitle(text, app) }
        return blank(old.artist) || blank(new.artist) || sameTitle(old.artist, new.artist)
    }
    /// The picture that is showing for a system track, so the same bytes are not decoded again at every update.
    private var lastSystemArtData: Data?
    /// The app that was last seen playing (Music, Spotify, Safari ...), so a click on the song name still has somewhere to
    /// go when the track has no app of its own (a recognised song) or nothing is playing at the moment.
    private var lastPlayingAppID: String?
    /// A song-change card held back until the new title arrives (see `track`).
    private var pendingSongChange: Task<Void, Never>?
    /// Called when a different song starts (skip, next song, a new pick). The notch uses it for the song-change card.
    var onSongChange: (() -> Void)?
    /// When the current song started showing (the self-check waits a while before calling a missing cover a problem).
    private var trackChangedAt = Date()
    /// v418: whether the Mac is online. A cover that cannot be downloaded offline is asked for again the moment the
    /// connection is back, and a missing cover is not reported as a fault while there is no connection.
    private var pathMonitor: NWPathMonitor?
    private(set) var networkUp = true
    /// Which way the person last skipped, so the cover in the open notch flips the right way: forward (next song) or
    /// backward (previous song). It only counts for a few seconds; a song that simply ends moves forward.
    enum SkipDirection { case forward, backward }
    private var skipDirection = SkipDirection.forward
    private var skipAt = Date.distantPast
    var recentSkipDirection: SkipDirection { Date().timeIntervalSince(skipAt) < 6 ? skipDirection : .forward }
    private func noteSkip(_ direction: SkipDirection) {
        skipDirection = direction
        skipAt = Date()
    }
    /// Set while the browser's YouTube page could be read, so the self-check knows an empty strip is a real problem.
    private var youtubeReadable = false
    @Published private(set) var artwork: NSImage?
    /// A small picture of the cover, known before the real one has loaded (from the queue): only used so the
    /// colours of the lock screen can change the moment a song changes. Nil when there is none.
    @Published private var hintImage: NSImage?
    private var hintKey: String?
    /// Only valid for the song that is current (a hint left over from an earlier song is never used).
    var colourHint: NSImage? { hintKey != nil && hintKey == artworkKey ? hintImage : nil }
    /// Covers of the songs played in this session: a song that comes back shows its cover at once.
    private let artworkByTrack = BoundedImageCache<String>(limit: 80)
    /// v413: the cover macOS "Now Playing" reported most recently (Music / Spotify included). macOS has it the moment the
    /// song starts, long before the player's scripting interface (slow, one call at a time) or a download hands it
    /// over, so it is what the cover is taken from first.
    private var systemCover: (title: String, artist: String, image: NSImage)?
    private var lastSystemCoverData: Data?
    @Published private(set) var repeatMode: RepeatMode = .off
    /// Songs around the current one in the Apple Music playlist (up to three before and three after).
    @Published private(set) var queue: [QueueEntry] = []
    /// Position of the current song in that playlist.
    @Published private(set) var queueCurrent = 0
    /// The song playing now, as a card in the middle of the row.
    @Published private(set) var queueCurrentEntry: QueueEntry?
    /// Why the queue is empty, when the user can do something about it.
    @Published private(set) var queueNote: String?
    private let queueImages = BoundedImageCache<String>(limit: 120)
    /// One shared "recently played" list for Spotify songs and YouTube videos, oldest first, so a song played in
    /// Spotify shows up in the strip while YouTube plays and the other way round.
    private var playedHistory: [PlayedItem] = MediaController.loadPlayedHistory()
    /// The Spotify song / YouTube video that is playing now (it joins the history once something else starts).
    private var playedNow: PlayedItem?
    private var spotifyNow: PlayedItem? { playedNow?.isSpotify == true ? playedNow : nil }
    private var youtubeNow: PlayedItem? { playedNow?.isSpotify == false ? playedNow : nil }
    private var queueRefreshTask: Task<Void, Never>?
    private var queueToken = 0
    private let queueScriptQueue = DispatchQueue(label: "indra.media.queue", qos: .utility)
    private let youtubeQueue = DispatchQueue(label: "indra.media.youtube", qos: .utility)
    private var repeatLockUntil = Date.distantPast
    /// Spotify's repeat button has three steps (off, playlist / album, this song), but not every setup honours the
    /// middle one: it can be refused or silently ignored (a song with no playlist behind it, a player that keeps
    /// reporting "off"). The app checks what Spotify really did after each press, remembers a context where the
    /// middle step does nothing, and skips it there, so the button never lands on a step that does not work.
    private var spotifyContextKey = "unknown"
    private var contextRepeatBlocked = Set<String>()
    private var repeatTask: Task<Void, Never>?
    /// Waits for the end of the song that is playing and checks what the player does next.
    private var endWatch: Task<Void, Never>?
    private var endAttempts = 0
    private var endIdentity = ""

    private let scriptQueue = DispatchQueue(label: "indra.media.script")
    /// Everything else that plays on the Mac (browsers, YouTube, VLC ...), from macOS "Now Playing".
    private let system = SystemNowPlaying.shared
    private var observers: [NSObjectProtocol] = []
    private var artworkKey: String?
    private var hadTrack = false
    private var accentCache: (image: NSImage, color: NSColor?)?
    private var lastPlaying = false
    private var identifiedExpiry: Task<Void, Never>?
    /// Throttle for refreshes triggered by the macOS Now Playing feed (see applySystem).
    private var lastSystemHintRefresh = Date.distantPast
    /// v400: what macOS says is playing in Music / Spotify, and when. A player's scripting interface keeps answering with
    /// the PREVIOUS song for a moment after a change; an answer that disagrees with this is not trusted (see
    /// `applyScriptResult`), and the hint asks the player again only a few times per song, not for ever.
    private var systemHintTitle = ""
    private var systemHintAt = Date.distantPast
    private var hintAsks = 0
    private var scriptRechecks = 0
    private var scriptRecheckTask: Task<Void, Never>?

    /// Fired when a track appears or disappears (not on every position update).
    var onPresenceChange: (() -> Void)?

    /// Accent colour of the current artwork (nil without artwork, or for grey artwork).
    var accentNSColor: NSColor? {
        guard let artwork else { return nil }
        if let cache = accentCache, cache.image === artwork { return cache.color }
        let color = AccentColor.extract(from: artwork)
        accentCache = (artwork, color)
        return color
    }

    private var gradientCache: (image: NSImage, colors: [Color]?)?

    /// v440: the album's own colours, left to right, for the slider and the visualizer (nil without artwork or for
    /// colourless artwork).
    var accentGradient: [Color]? {
        guard let artwork else { return nil }
        if let cache = gradientCache, cache.image === artwork { return cache.colors }
        let colors = ArtworkPalette.gradient(from: artwork)
        gradientCache = (artwork, colors)
        return colors
    }

    /// A pale shade of the artwork's main colour for the notch's record (nil for grey artwork or none).
    var vinylTintNSColor: NSColor? {
        guard let accent = accentNSColor?.usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.08 else { return nil }
        return NSColor(hue: hue, saturation: min(saturation, 0.7) * 0.42, brightness: 0.94, alpha: 1)
    }

    // MARK: - Start

    func start() {
        let center = DistributedNotificationCenter.default()
        observe(center, name: "com.apple.Music.playerInfo", source: .music)
        observe(center, name: "com.spotify.client.PlaybackStateChanged", source: .spotify)
        system.onPlayback = { [weak self] playback in
            self?.applySystem(playback)
        }
        system.start()
        registerHealthChecks()
        startNetworkWatch()
        DispatchQueue.global(qos: .utility).async { CoverDiskCache.prune() }
        HealthMonitor.shared.start()
        // Music that was already playing before Indra started sends no notification, so ask once
        // at launch (twice, in case the first try is held up by the automation permission prompt).
        Task { @MainActor [weak self] in
            for delay: UInt64 in [1_000_000_000, 3_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.track == nil else { return }
                self.refresh()
            }
        }
    }

    private func observe(_ center: DistributedNotificationCenter, name: String, source: MediaSource) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
            guard let raw = MediaController.parse(note.userInfo, source: source) else { return }
            Task { @MainActor [weak self] in
                self?.apply(raw)
            }
        }
        observers.append(token)
    }

    nonisolated private static func parse(_ info: [AnyHashable: Any]?, source: MediaSource) -> RawPlayback? {
        guard let info else { return nil }
        let durationKey = source == .music ? "Total Time" : "Duration"
        return RawPlayback(
            source: source,
            state: info["Player State"] as? String ?? "",
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            durationMs: (info[durationKey] as? NSNumber)?.doubleValue,
            positionSec: (info["Playback Position"] as? NSNumber)?.doubleValue
        )
    }

    // MARK: - Self-check

    private func registerHealthChecks() {
        // A song that has been playing for a while but has no cover.
        HealthMonitor.shared.register(id: "media-artwork") { [weak self] in
            guard let self, let track = self.track, track.isPlaying, track.source != .identified,
                  self.networkUp,
                  // v486: video players (QuickTime Player ...) have no album cover by design, so that is not a fault.
                  track.appBundleID != "com.apple.QuickTimePlayerX",
                  self.artwork == nil, Date().timeIntervalSince(self.trackChangedAt) > 20 else { return nil }
            return (title: "The album cover is not loading",
                    detail: "\"\(track.title)\" has been playing for over 20 seconds without a cover (source: \(track.source)).",
                    fix: nil)
        }
        // The side album bar stays empty although the player can fill it.
        HealthMonitor.shared.register(id: "media-queue-empty") { [weak self] in
            guard let self, let track = self.track, track.isPlaying,
                  Date().timeIntervalSince(self.trackChangedAt) > 15,
                  self.queue.isEmpty, self.queueCurrentEntry == nil, self.queueNote == nil else { return nil }
            let canFill = track.source == .music
                || (YouTubeBrowsers.browser(forBundleID: track.appBundleID) != nil && self.youtubeReadable)
            guard canFill else { return nil }
            return (title: "The side album bar is empty",
                    detail: "\"\(track.title)\" is playing but no songs could be read around it (source: \(track.source)).",
                    fix: nil)
        }
    }

    // MARK: - End of the song

    /// A song that loops (repeat one, or one song on repeat) or a player that moves on without telling anyone leaves
    /// the position stuck at the end of the song: the slider and the stylus would stay there. So when the end is
    /// reached, the player is asked where it is now (a few times, a little apart), and a looping song is restarted.
    private func scheduleEndWatch() {
        endWatch?.cancel()
        endWatch = nil
        guard let current = track, current.isPlaying, current.duration > 2, current.source != .identified else {
            endAttempts = 0
            return
        }
        let remaining = current.duration - current.elapsed(at: Date())
        if remaining > 1.5 || current.identity != endIdentity { endAttempts = 0 }
        endIdentity = current.identity
        let wait: Double = remaining > 0.05 ? remaining + 0.35 : min(0.8 + Double(endAttempts) * 0.7, 3.5)
        endWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait.sleepNanoseconds)
            guard !Task.isCancelled, let self, let now = self.track, now.isPlaying, now.duration > 0,
                  now.elapsed(at: Date()) >= now.duration - 0.6 else { return }
            self.endAttempts += 1
            guard self.endAttempts <= 6 else { return }
            if self.endAttempts >= 2, now.source != .system, self.repeatMode == .one {
                // The same song started again and the player said nothing: start the bar and the stylus over.
                var looped = now
                looped.position = 0
                looped.positionDate = Date()
                self.track = looped
                return
            }
            self.refresh()
        }
    }

    // MARK: - Apply state

    private func apply(_ raw: RawPlayback) {
        applyPlayback(raw)
        notifyPresence()
    }

    private func notifyPresence() {
        let hasTrack = track != nil
        let playing = track?.isPlaying ?? false
        if hasTrack != hadTrack || playing != lastPlaying {
            hadTrack = hasTrack
            lastPlaying = playing
            onPresenceChange?()
        }
    }

    // MARK: - Any app (macOS Now Playing)

    /// v426: a browser (Safari + YouTube) reports "nothing is playing" for a moment while the song is being changed from
    /// the lock screen / a media key / the page itself, before the next song is announced. Clearing the track at that
    /// instant made the widget vanish and the open vinyl close. The track is now only dropped when nothing has
    /// been announced for `systemClearDelay` seconds; any new report cancels the wait.
    private var systemClearTask: Task<Void, Never>?
    private let systemClearDelay: UInt64 = 6_000_000_000

    private func applySystem(_ playback: SystemPlayback?) {
        guard let playback else {
            // Nothing is registered as playing any more (or the helper ended).
            guard track?.source == .system else { return }
            guard systemClearTask == nil else { return }
            Trace.log("SYSTEM nothing playing reported: keeping the card for a few seconds")
            systemClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: self?.systemClearDelay ?? 6_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.systemClearTask = nil
                guard self.track?.source == .system else { return }
                self.track = nil
                self.artwork = nil
                self.artworkKey = nil
                self.notifyPresence()
            }
            return
        }
        // Something is playing again (the next song, or the same one): the pending clear is void.
        systemClearTask?.cancel()
        systemClearTask = nil

        // Apple Music and Spotify have their own, richer feed (queue, repeat, lyrics). When macOS says one
        // of them is now playing, a browser card that is still showing has to give way.
        if playback.bundleID == MediaSource.music.bundleID || playback.bundleID == MediaSource.spotify.bundleID {
            // v413: macOS has the cover first; keep it / show it now (see noteSystemCover).
            noteSystemCover(playback)
            if track?.source == .system {
                track = nil
                artwork = nil
                artworkKey = nil
                notifyPresence()
                refresh()
            } else if playback.isPlaying {
                // v393: the player's own notification is late (or never comes) when a song ends and the next one
                // starts by itself, and the notch then kept the old title, cover and card until something else
                // refreshed it, often half way through the new song. macOS reports the change at once: it is not
                // used for the data (the player's feed is richer) but as the signal to ask the player right now.
                if !MediaController.sameTitle(playback.title, systemHintTitle) {
                    hintAsks = 0
                    scriptRechecks = 0
                    Trace.log("HINT macOS says \(playback.bundleID) plays \"\(playback.title)\"")
                }
                systemHintTitle = playback.title
                systemHintAt = Date()
                let changed: Bool
                if let current = track, current.source == .music || current.source == .spotify {
                    changed = !playback.title.isEmpty && !MediaController.sameTitle(playback.title, current.title)
                } else {
                    changed = true   // Music / Spotify is playing but nothing is shown yet
                }
                // At most a few times per song: when the two feeds name a song differently for good (a feature tag, a
                // remaster suffix) this used to ask the player every 1.2 seconds, for as long as the song played.
                if changed, hintAsks < 3, Date().timeIntervalSince(lastSystemHintRefresh) > 1.2 {
                    lastSystemHintRefresh = Date()
                    hintAsks += 1
                    refresh()
                }
            }
            return
        }

        // A paused page must not push away a song that is playing in Music / Spotify.
        if let current = track, current.source == .music || current.source == .spotify,
           current.isPlaying, !playback.isPlaying {
            return
        }

        let appName = SystemNowPlaying.appName(for: playback.bundleID)
        let title = playback.title.isEmpty ? (appName ?? "Playing") : playback.title
        let artist = playback.artist.isEmpty ? (appName ?? "") : playback.artist

        var info = TrackInfo(source: .system,
                             title: title,
                             artist: artist,
                             album: playback.album,
                             duration: playback.duration.sanitizedSeconds,
                             isPlaying: playback.isPlaying,
                             position: playback.position,
                             positionDate: Date())
        info.appBundleID = playback.bundleID

        let sameTrack = track?.identity == info.identity
        let trackBefore = track
        // Every song, video or audio that macOS reports as playing can open the vinyl.
        info.vinyl = true
        if sameTrack, let current = track {
            // The same track again: only touch the published value when something really moved,
            // so the notch is not redrawn by every re-sync.
            let drift = abs(current.elapsed(at: Date()) - info.position)
            if current.isPlaying == info.isPlaying, current.duration == info.duration, drift < 1.5 {
                applySystemArtwork(playback, key: info.identity)
                return
            }
            if drift < 1.5, current.isPlaying == info.isPlaying {
                info.position = current.position
                info.positionDate = current.positionDate
            }
        }
        track = info

        if !sameTrack {
            // v564: the same song announcing more of its details (artist, album) keeps its cover.
            if !MediaController.isRefinement(from: trackBefore, to: info) { artwork = nil }
            artworkKey = info.identity
        }
        applySystemArtwork(playback, key: info.identity)
        notifyPresence()
        if !sameTrack, let browser = YouTubeBrowsers.browser(forBundleID: playback.bundleID) {
            // v486: any browser (Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera ...), not only Safari.
            YouTubeBrowsers.remember(browser)
            // Remember the video and learn what comes around it once the page has settled.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.refreshYouTubeQueue()
            }
        }
    }

    // MARK: - Covers when the connection is bad

    private func startNetworkWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBack = up && !self.networkUp
                self.networkUp = up
                if cameBack { self.retryMissingArtwork() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "indra.media.path"))
        pathMonitor = monitor
    }

    /// The connection is back: a song that is still without its cover asks for it again at once.
    private func retryMissingArtwork() {
        guard artwork == nil, let current = track, let key = artworkKey else { return }
        Trace.log("COVER connection is back: asking for the missing cover again")
        switch current.source {
        case .spotify: fetchSpotifyArtwork(key: key)
        case .music: fetchMusicArtwork(key: key)
        default: break
        }
    }

    /// A cover that could not be downloaded (no connection, a busy server): asked again, further apart each time, for
    /// about a minute. (It used to give up after the first failed download, so a song started while offline never got
    /// its cover.)
    private func retryDownload(_ attempt: Int, _ again: @escaping @MainActor () -> Void) {
        guard attempt < 14 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(min(2.0 + Double(attempt) * 2.0, 10.0) * 1_000_000_000))
            again()
        }
    }

    /// Covers are kept on disk, so a song heard before has its cover at once, with or without a connection.
    private func saveCoverToDisk(_ image: NSImage, for info: TrackInfo?) {
        guard let info else { return }
        let file = CoverDiskCache.file(for: "\(info.title)|\(info.artist)|now")
        Task.detached(priority: .utility) {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return }
            try? jpeg.write(to: file, options: .atomic)
        }
    }

    private func coverFromDisk(for info: TrackInfo) -> NSImage? {
        let file = CoverDiskCache.file(for: "\(info.title)|\(info.artist)|now")
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        // v419: a cover that is used is marked as used, so it does not expire while it matters (it used to be removed 45
        // days after it was first saved, however often it was shown).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return MediaController.decoded(data)
    }

    // MARK: - Artwork

    /// v413: takes the cover macOS reports for a Music / Spotify song and shows it at once when it belongs to the song on
    /// screen; when the song on screen is still the previous one, it is kept for `applyPlayback`, which uses it the
    /// moment the new song appears.
    private func noteSystemCover(_ playback: SystemPlayback) {
        guard let data = playback.artwork, !data.isEmpty else { return }
        // v419: the same picture arrives again with every re-sync: it is decoded only once.
        let image: NSImage
        if let held = systemCover, data == lastSystemCoverData, held.title == playback.title {
            image = held.image
        } else {
            guard let decoded = MediaController.decoded(data) else { return }
            image = decoded
            lastSystemCoverData = data
            systemCover = (playback.title, playback.artist, decoded)
        }
        guard let current = track, current.source == .music || current.source == .spotify,
              MediaController.sameTitle(playback.title, current.title),
              artworkKey == current.identity else { return }
        useCover(image, for: current.identity, current: current)
    }

    /// Shows a cover for the song `key`, remembers it and keeps it on disk. Only when none is showing yet: a second
    /// copy of the same picture would make the cover flip twice, and would be written to disk again at every re-sync.
    private func useCover(_ image: NSImage, for key: String, current: TrackInfo? = nil) {
        guard artwork == nil else { return }
        artworkByTrack[key] = image
        artwork = image
        Trace.log("COVER system ready")
        shareWithQueue(image)
        saveCoverToDisk(image, for: current)
    }

    /// The song on screen is also the middle card of the lock screen's row: it gets the cover as soon as there is one.
    private func shareWithQueue(_ image: NSImage) {
        guard let current = track, let entry = queueCurrentEntry, entry.image == nil,
              MediaController.sameTitle(entry.title, current.title) else { return }
        assignQueueImage(image, key: entry.key)
    }

    /// The cover macOS reported for exactly this song, if it has reported one.
    private func coverReported(for info: TrackInfo) -> NSImage? {
        guard let held = systemCover, MediaController.sameTitle(held.title, info.title) else { return nil }
        if !held.artist.isEmpty, !info.artist.isEmpty, !MediaController.sameTitle(held.artist, info.artist) { return nil }
        return held.image
    }

    /// Decodes the picture now, so the first frame that draws it does not (a big cover decoded while the notch or the
    /// lock screen is animating is what made the cover appear a beat late).
    nonisolated private static func decoded(_ data: Data) -> NSImage? {
        guard let source = NSImage(data: data) else { return nil }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let longest = CGFloat(max(cg.width, cg.height))
        guard longest > 900 else { return NSImage(cgImage: cg, size: source.size) }
        // Covers are never drawn bigger than the lock screen's record; larger ones are brought down to 900 px.
        let scale = 900 / longest
        let width = Int((CGFloat(cg.width) * scale).rounded()), height = Int((CGFloat(cg.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return source }
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
    }

    private func applySystemArtwork(_ playback: SystemPlayback, key: String) {
        guard artworkKey == key, let data = playback.artwork, !data.isEmpty else { return }
        // v564: the cover arrives with every update now; the one that is already showing is not decoded again.
        if artwork != nil, data == lastSystemArtData { return }
        guard let image = MediaController.decoded(data) else { return }
        lastSystemArtData = data
        artwork = image
    }

    // MARK: - Identified songs (from system audio)

    func showIdentified(_ song: IdentifiedSong, artwork image: NSImage?) {
        let info = TrackInfo(source: .identified,
                             title: song.title,
                             artist: song.artist,
                             album: "",
                             duration: 0,
                             isPlaying: true,
                             position: 0,
                             positionDate: Date())
        track = info
        artwork = image
        artworkKey = info.identity
        notifyPresence()

        identifiedExpiry?.cancel()
        identifiedExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled, let self, self.track?.source == .identified else { return }
            self.track = nil
            self.artwork = nil
            self.artworkKey = nil
            self.notifyPresence()
        }
    }

    func clearIdentified() {
        guard track?.source == .identified else { return }
        identifiedExpiry?.cancel()
        track = nil
        artwork = nil
        artworkKey = nil
        notifyPresence()
    }

    func setIdentifiedArtwork(_ image: NSImage, for song: IdentifiedSong) {
        guard let current = track, current.source == .identified, current.title == song.title else { return }
        artwork = image
    }

    private func applyPlayback(_ raw: RawPlayback) {
        let state = raw.state.lowercased()
        if state == "stopped" || raw.title.isEmpty {
            if track?.source == raw.source {
                track = nil
                artwork = nil
                artworkKey = nil
            }
            return
        }

        var info = TrackInfo(source: raw.source,
                             title: raw.title,
                             artist: raw.artist,
                             album: raw.album,
                             duration: ((raw.durationMs ?? 0) / 1000).sanitizedSeconds,
                             isPlaying: state == "playing",
                             position: 0,
                             positionDate: Date())
        let sameTrack = track?.identity == info.identity
        if let position = raw.positionSec {
            info.position = position
        } else if sameTrack, let current = track {
            info.position = current.elapsed(at: Date())
        }
        track = info

        if !sameTrack {
            artworkKey = info.identity
            // v413: the cover macOS already reported for this song is shown at once; only when there is none (and none
            // from an earlier play) the player is asked, and that answer is slower.
            let known = artworkByTrack[info.identity] ?? coverReported(for: info) ?? coverFromDisk(for: info)
            if let known { artworkByTrack[info.identity] = known }
            artwork = known
            hintKey = info.identity
            hintImage = known == nil
                ? queue.first(where: { $0.title == info.title && $0.artist == info.artist })?.image
                : nil
            if raw.source == .music {
                if known == nil { fetchMusicArtwork(key: info.identity) }
            } else if raw.source == .spotify {
                if known == nil { fetchSpotifyArtwork(key: info.identity) }
            }
        }
        if raw.positionSec == nil { fetchPosition(source: raw.source, key: info.identity) }
        if !sameTrack { refreshRepeat() }
    }

    // MARK: - Refresh (on notch open)

    func refresh() {
        system.send("refresh")
        refreshRepeat()
        refreshScripts()
    }

    /// Asks Music and Spotify themselves what they are playing.
    private func refreshScripts() {
        for source in [MediaSource.music, .spotify] where isRunning(source) {
            let script = MediaController.stateScript(for: source)
            scriptQueue.async {
                guard let text = MediaController.run(script)?.stringValue else { return }
                Task { @MainActor [weak self] in
                    self?.applyScriptResult(text, source: source)
                }
            }
        }
    }

    /// The app a track plays in: Music or Spotify, or the app macOS reports for anything else.
    private static func appID(of track: TrackInfo) -> String? {
        if let id = track.appBundleID, !id.isEmpty { return id }
        let id = track.source.bundleID
        return id.isEmpty ? nil : id
    }

    /// Clicking a song or artist name: brings the app that is playing to the front, and opens it when it is not
    /// running. It always lands somewhere: if the track names no app, the last app seen playing is used, then
    /// whatever macOS says is playing, and in the end Apple Music.
    func openSourceApp() {
        var candidates: [String] = []
        if let current = track, let id = MediaController.appID(of: current) { candidates.append(id) }
        if let id = SystemNowPlaying.shared.current?.bundleID, !id.isEmpty { candidates.append(id) }
        if let id = lastPlayingAppID { candidates.append(id) }
        candidates.append(MediaSource.music.bundleID)
        for id in candidates {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            // Opening by URL brings a running app forward (and unhides it) even when Indra is not the active app.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
    }

    func refreshRepeat() {
        if track?.source == .system {
            repeatMode = .off
            return
        }
        guard let source = activeSource() else { return }
        // Spotify's own scripting only knows repeat on / off, and calls repeating one song "on" too. When the
        // Web API is signed in it says which of the three it really is.
        if source == .spotify, SpotifyWebAPI.shared.canSetRepeat {
            Task { @MainActor [weak self] in
                guard let info = await SpotifyWebAPI.shared.repeatInfo() else {
                    self?.refreshRepeatByScript(source)
                    return
                }
                guard let self else { return }
                self.spotifyContextKey = info.contextKey
                guard Date() >= self.repeatLockUntil else { return }
                self.repeatMode = MediaController.repeatMode(fromSpotify: info.state)
            }
            return
        }
        refreshRepeatByScript(source)
    }

    private func refreshRepeatByScript(_ source: MediaSource) {
        let script = source == .music
            ? "tell application id \"com.apple.Music\" to return song repeat"
            : "tell application id \"com.spotify.client\" to return repeating"
        scriptQueue.async {
            guard let result = MediaController.run(script) else { return }
            let mode: RepeatMode
            if source == .music {
                switch result.enumCodeValue {
                case 0x6B52_7031: mode = .one
                case 0x6B41_6C6C: mode = .all
                default: mode = .off
                }
            } else {
                mode = result.booleanValue ? .all : .off
            }
            Task { @MainActor [weak self] in
                guard let self, Date() >= self.repeatLockUntil else { return }
                self.repeatMode = mode
            }
        }
    }

    func cycleRepeat() {
        guard track?.source != .system, let source = activeSource() else { return }
        let previous = repeatMode
        let next: RepeatMode
        let script: String
        if source == .music {
            switch repeatMode {
            case .off: next = .all
            case .all: next = .one
            case .one: next = .off
            }
            let code = next == .off ? "kRpO" : (next == .all ? "kAll" : "kRp1")
            script = "tell application id \"com.apple.Music\" to set song repeat to \u{00AB}constant ****\(code)\u{00BB}"
        } else if SpotifyWebAPI.shared.canSetRepeat {
            // Spotify's real three steps (off, playlist / album, this song), as in its own button. Only the Web API
            // can set the last one; if it refuses, the on / off switch in Spotify's scripting takes over.
            // The middle step is skipped where it is known (or seen) not to work, see `spotifyContextKey`.
            let key = spotifyContextKey
            let contextUsable = key != "none" && !contextRepeatBlocked.contains(key)
            switch repeatMode {
            case .off: next = contextUsable ? .all : .one
            case .all: next = .one
            case .one: next = .off
            }
            repeatMode = next
            repeatLockUntil = Date().addingTimeInterval(8)
            repeatTask?.cancel()
            repeatTask = Task { @MainActor [weak self] in
                await self?.applySpotifyRepeat(next, previous: previous, key: key)
            }
            return
        } else {
            next = repeatMode == .off ? .all : .off
            script = "tell application id \"com.spotify.client\" to set repeating to \(next == .all ? "true" : "false")"
        }
        repeatMode = next
        // Don't let a refresh that was already running put the old value back.
        repeatLockUntil = Date().addingTimeInterval(1.5)
        scriptQueue.async {
            _ = MediaController.run(script)
        }
    }

    nonisolated private static func repeatMode(fromSpotify state: String) -> RepeatMode {
        state == "track" ? .one : (state == "context" ? .all : .off)
    }

    private static func spotifyRepeatCode(_ mode: RepeatMode) -> String {
        mode == .one ? "track" : (mode == .all ? "context" : "off")
    }

    /// Sets Spotify's repeat and checks that it took. Spotify can answer "done" and still not change anything
    /// (and its state is slow to update), so the state is read back a few times before it is believed.
    /// When the playlist step does not take, Spotify's own on / off switch is tried; if that fails too, the
    /// step is remembered as broken for this context and the press moves on to repeat one.
    private func applySpotifyRepeat(_ wanted: RepeatMode, previous: RepeatMode, key: String) async {
        let api = SpotifyWebAPI.shared
        func finish(_ mode: RepeatMode) {
            repeatMode = mode
            repeatLockUntil = Date().addingTimeInterval(2)
        }
        func confirmed(_ mode: RepeatMode) async -> Bool? {
            let code = MediaController.spotifyRepeatCode(mode)
            var answered = false
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return nil }
                if let info = await api.repeatInfo() {
                    answered = true
                    if info.state == code { return true }
                }
            }
            // Spotify never answered (no active player): nothing to check against, so believe the request.
            return answered ? false : true
        }

        guard await api.setRepeat(MediaController.spotifyRepeatCode(wanted)) else {
            if Task.isCancelled { return }
            // Refused (no Premium, no sign-in permission): Spotify's on / off switch is all that is left.
            let fallback: RepeatMode = previous == .off ? .all : .off
            finish(fallback)
            let script = "tell application id \"com.spotify.client\" to set repeating to \(fallback == .all ? "true" : "false")"
            scriptQueue.async { _ = MediaController.run(script) }
            return
        }
        guard let ok = await confirmed(wanted) else { return }
        if ok { finish(wanted); return }

        if wanted == .all {
            // The Web API said yes but nothing changed: try the switch in Spotify's own scripting.
            scriptQueue.async { _ = MediaController.run("tell application id \"com.spotify.client\" to set repeating to true") }
            if let ok = await confirmed(.all) {
                if ok { finish(.all); return }
            } else { return }
            contextRepeatBlocked.insert(key)
            if await api.setRepeat("track"), let ok = await confirmed(.one), ok { finish(.one); return }
        }
        if Task.isCancelled { return }
        // Nothing worked: show what Spotify really has, never a step that did not happen.
        if let info = await api.repeatInfo() {
            finish(MediaController.repeatMode(fromSpotify: info.state))
        } else {
            finish(previous)
        }
    }

    private func applyScriptResult(_ text: String, source: MediaSource) {
        let parts = text.components(separatedBy: "\u{1F}")
        let state = (parts.first ?? "").lowercased()
        guard state == "playing" || state == "paused", parts.count >= 6 else {
            if state == "stopped", track?.source == source { apply(RawPlayback(source: source, state: "stopped", title: "", artist: "", album: "", durationMs: nil, positionSec: nil)) }
            return
        }
        let isPlaying = state == "playing"
        if let current = track, current.source != source, current.isPlaying, !isPlaying { return }
        // v400: right after a song change the player's scripting interface still answers with the PREVIOUS song. When
        // macOS has just said another song is playing, that answer is stale: using it put the old song (name, cover,
        // lyrics, animated cover) back for a second or two and restarted every lookup, each time. It is ignored, and
        // the player is asked again shortly (a few times at most).
        if isPlaying, scriptRechecks < 6, Date().timeIntervalSince(systemHintAt) < 8, !systemHintTitle.isEmpty,
           !MediaController.sameTitle(parts[1], systemHintTitle),
           let current = track, current.source == source,
           MediaController.sameTitle(current.title, systemHintTitle) || MediaController.sameTitle(current.title, parts[1]) {
            scriptRechecks += 1
            Trace.log("STALE \(source.rawValue) script said \"\(parts[1])\", macOS says \"\(systemHintTitle)\": ignored (\(scriptRechecks))")
            scriptRecheckTask?.cancel()
            scriptRecheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshScripts()
            }
            return
        }
        apply(RawPlayback(source: source,
                          state: state,
                          title: parts[1],
                          artist: parts[2],
                          album: parts[3],
                          durationMs: Double(parts[4]),
                          positionSec: Double(parts[5]).map { $0 / 1000 }))
    }

    nonisolated private static func stateScript(for source: MediaSource) -> String {
        let duration = source == .music ? "(round ((duration of t) * 1000))" : "(duration of t)"
        return """
        tell application id "\(source.bundleID)"
            set s to player state as text
            if s is "stopped" then return s
            set t to current track
            set sep to character id 31
            return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & \(duration) & sep & (round (player position * 1000))
        end tell
        """
    }

    private func fetchPosition(source: MediaSource, key: String) {
        guard isRunning(source) else { return }
        let script = "tell application id \"\(source.bundleID)\" to return (round (player position * 1000))"
        scriptQueue.async {
            guard let ms = MediaController.run(script)?.int32Value else { return }
            Task { @MainActor [weak self] in
                guard let self, var current = self.track, current.identity == key else { return }
                current.position = Double(ms) / 1000
                current.positionDate = Date()
                self.track = current
            }
        }
    }

    /// Titles are compared loosely: the notification and the scripting interface can differ in case or spacing.
    nonisolated private static func sameTitle(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return norm(a) == norm(b)
    }

    /// Spotify only exposes an artwork URL, so the picture is downloaded (outbound network is allowed).
    ///
    /// v393: right after a song change Spotify's scripting interface keeps answering with the PREVIOUS song for a
    /// moment. The cover used to be read from "current track" without asking whose cover it was, so the old cover
    /// was stored under the new song (and cached, so it came back every time). The script now returns the title
    /// together with the URL, and a cover that belongs to another song is never used: it waits and asks again.
    private func fetchSpotifyArtwork(key: String, attempt: Int = 0) {
        guard isRunning(.spotify), let wanted = track?.title else { return }
        scriptQueue.async {
            let script = """
            tell application id "com.spotify.client"
                set t to current track
                return (artwork url of t) & "§§" & (spotify url of t) & "§§" & (name of t)
            end tell
            """
            let reply = MediaController.run(script)?.stringValue
            let parts = reply?.components(separatedBy: "§§") ?? []
            let text = parts.first
            let uri = parts.count > 1 ? parts[1] : nil
            let playerTitle = parts.count > 2 ? parts[2] : nil
            Task { @MainActor [weak self] in
                guard let self, self.artworkKey == key else { return }
                // The player is still on another song: nothing it says belongs to this one yet.
                guard let playerTitle, MediaController.sameTitle(playerTitle, wanted) else {
                    self.retryArtwork(attempt) { self.fetchSpotifyArtwork(key: key, attempt: attempt + 1) }
                    return
                }
                if let uri, uri.hasPrefix("spotify:") {
                    self.recordSpotify(uri: uri, imageURL: text, key: key)
                }
                guard let text, let url = URL(string: text) else {
                    self.retryArtwork(attempt) { self.fetchSpotifyArtwork(key: key, attempt: attempt + 1) }
                    return
                }
                guard self.artwork == nil, self.artworkKey == key else { return }
                let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
                guard let result = try? await URLSession.shared.data(for: request),
                      let image = await Task.detached(priority: .userInitiated, operation: { MediaController.decoded(result.0) }).value else {
                    // No connection (or a busy server): asked again, and at once when the connection returns.
                    self.retryDownload(attempt) { self.fetchSpotifyArtwork(key: key, attempt: attempt + 1) }
                    return
                }
                guard self.artwork == nil, self.artworkKey == key else { return }
                self.artworkByTrack[key] = image
                self.artwork = image
                self.shareWithQueue(image)
                self.saveCoverToDisk(image, for: self.track)
                Trace.log("COVER spotify ready")
            }
        }
    }

    /// Asks again shortly (a few times, a little further apart each time) while a player is still catching up.
    private func retryArtwork(_ attempt: Int, _ again: @escaping @MainActor () -> Void) {
        guard attempt < 8 else { return }
        Task { @MainActor in
            // v413: first ask again after 0.15 s (was 0.4 s), then a little further apart each time.
            try? await Task.sleep(nanoseconds: UInt64(150_000_000 + attempt * 250_000_000))
            again()
        }
    }

    /// v393: same rule as Spotify: Music's "current track" can still be the previous song right after a change, so
    /// the cover is only taken when the player's current track has the title of the song being shown.
    private func fetchMusicArtwork(key: String, attempt: Int = 0) {
        guard isRunning(.music), let wanted = track?.title else { return }
        scriptQueue.async {
            let name = MediaController.run("tell application id \"com.apple.Music\" to return name of current track")?.stringValue
            let matched = name.map { MediaController.sameTitle($0, wanted) } ?? false
            let data: Data? = matched
                ? MediaController.run("tell application id \"com.apple.Music\" to return data of artwork 1 of current track")?.data
                : nil
            Task { @MainActor [weak self] in
                guard let self, self.artworkKey == key else { return }
                if let data, let image = MediaController.decoded(data) {
                    self.artworkByTrack[key] = image
                    if self.artwork == nil {
                        self.artwork = image
                        Trace.log("COVER music ready")
                    }
                    self.shareWithQueue(image)
                    self.saveCoverToDisk(image, for: self.track)
                } else {
                    // Either the player is still on the previous song, or the cover is not ready yet.
                    self.retryArtwork(attempt) { self.fetchMusicArtwork(key: key, attempt: attempt + 1) }
                }
            }
        }
    }

    // MARK: - Queue (Apple Music)

    nonisolated private static let queueScript = """
    tell application id "com.apple.Music"
        if player state is stopped then return ""
        set pl to current playlist
        set n to count of tracks of pl
        set cur to index of current track
        set out to (cur as text) & "§§" & ((name of current track) as text) & "§§" & ((artist of current track) as text) & linefeed
        repeat with k from (cur - 3) to (cur + 3)
            if k >= 1 and k <= n and k is not cur then
                set t to track k of pl
                set out to out & (k as text) & "§§" & ((name of t) as text) & "§§" & ((artist of t) as text) & linefeed
            end if
        end repeat
        return out
    end tell
    """

    func refreshQueue() {
        switch track?.source {
        case .music?: refreshMusicQueue()
        case .spotify?: refreshSpotifyQueue()
        case .system?: refreshYouTubeQueue()
        default:
            queue = []
            queueCurrentEntry = nil
            queueNote = nil
        }
    }

    private func refreshYouTubeQueue() {
        guard let current = track, let browser = YouTubeBrowsers.browser(forBundleID: current.appBundleID) else {
            youtubeReadable = false
            for known in YouTubeBrowsers.all {
                HealthMonitor.shared.resolve(id: "browser-automation-\(known.id)")
                HealthMonitor.shared.resolve(id: "browser-javascript-\(known.id)")
            }
            queue = []
            queueCurrentEntry = nil
            queueNote = nil
            return
        }
        queueToken += 1
        let token = queueToken
        let hint = current.title
        let browserID = browser.id
        youtubeQueue.async {
            let result = YouTubeProbe.snapshot(titleHint: hint, browserID: browserID)
            Task { @MainActor [weak self] in self?.applyYouTubeQueue(result, token: token, browser: browser) }
        }
    }

    private func applyYouTubeQueue(_ result: YouTubeProbeResult, token: Int, browser: YouTubeBrowser) {
        guard token == queueToken, let playing = track else { return }
        guard case .snapshot(let snapshot) = result else {
            // Setup help for the queue lives in Settings; the lock screen stays clean.
            youtubeReadable = false
            if case .denied = result {
                HealthMonitor.shared.report(id: "browser-automation-\(browser.id)",
                                            title: "Indra is not allowed to control \(browser.name)",
                                            detail: "The side album bar and song switching for YouTube need Privacy & Security ▸ Automation ▸ Indra ▸ \(browser.name).",
                                            fix: .reauthorizeAutomation)
            }
            queue = []
            queueCurrentEntry = nil
            queueNote = nil
            return
        }
        HealthMonitor.shared.resolve(id: "browser-automation-\(browser.id)")
        if snapshot.scriptable {
            youtubeReadable = true
            HealthMonitor.shared.resolve(id: "browser-javascript-\(browser.id)")
        } else {
            youtubeReadable = false
            HealthMonitor.shared.report(id: "browser-javascript-\(browser.id)",
                                        title: "\(browser.name) does not let Indra read the YouTube page",
                                        detail: "\(browser.javascriptHint) Until then the side album bar cannot list or switch YouTube videos.",
                                        fix: .browserJavaScript(bundle: browser.id))
        }
        let items = snapshot.items
        var index = snapshot.current
        if index < 0 || index >= items.count {
            let wanted = playing.title.lowercased()
            index = items.firstIndex { $0.title.lowercased() == wanted }
                ?? items.firstIndex { !$0.title.isEmpty && wanted.contains($0.title.lowercased()) }
                ?? -1
        }
        guard index >= 0, items.count >= 2 else {
            // Not in a playlist: last three videos played here, this one, and the three suggested next.
            applyYouTubeAround(snapshot, playing: playing)
            return
        }

        // A video from a playlist (YouTube Music for example) also goes into the shared history.
        recordPlayed(PlayedItem(uri: "yt:" + snapshot.url, title: playing.title, artist: playing.artist,
                                imageURL: YouTubeProbe.thumbnail(forVideoURL: snapshot.url)))

        func entry(_ position: Int) -> QueueEntry {
            let item = items[position]
            return QueueEntry(id: position, title: item.title, artist: item.artist, image: nil,
                              imageURL: item.imageURL.flatMap { URL(string: $0) }, uri: nil)
        }
        let low = max(0, index - 3)
        let high = min(items.count - 1, index + 3)
        let around = (low...high).filter { $0 != index }.map(entry)
        let now = entry(index)
        // The big cover Indra already has beats the small queue thumbnail.
        if let artwork { queueImages[now.key] = artwork }
        showQueue(around, current: index, now: now)
    }

    private func applyYouTubeAround(_ snapshot: YouTubeSnapshot, playing: TrackInfo) {
        guard let nowID = YouTubeProbe.videoID(snapshot.url) else {
            queue = []
            queueCurrentEntry = nil
            queueNote = nil
            return
        }
        let nowItem = PlayedItem(uri: "yt:" + snapshot.url, title: playing.title, artist: playing.artist,
                                 imageURL: YouTubeProbe.thumbnail(forVideoURL: snapshot.url))
        recordPlayed(nowItem)

        // The last three videos played here: songs played in Spotify never show up in the YouTube list.
        let before = playedHistory.filter { $0.videoID != nil && $0.videoID != nowID && $0.uri != nowItem.uri }.suffix(3)
        var entries: [QueueEntry] = before.enumerated().map { offset, item in
            item.entry(id: offset - before.count)
        }
        var next = 0
        for item in snapshot.upNext {
            guard next < 3, let link = item.url, YouTubeProbe.videoID(link) != nowID else { continue }
            next += 1
            entries.append(QueueEntry(id: next, title: item.title, artist: item.artist, image: nil,
                                      imageURL: item.imageURL.flatMap { URL(string: $0) }, uri: "yt:" + link))
        }
        let now = nowItem.entry(id: 0)
        if let artwork { queueImages[now.key] = artwork }
        showQueue(entries, current: 0, now: now)
    }

    // MARK: Played history (kept in one list, but each player only ever shows its own entries)

    struct PlayedItem: Codable, Equatable {
        var uri: String
        var title: String
        var artist: String
        var imageURL: String?

        var isSpotify: Bool { uri.hasPrefix("spotify:") }
        var videoID: String? { uri.hasPrefix("yt:") ? YouTubeProbe.videoID(String(uri.dropFirst(3))) : nil }

        func entry(id: Int) -> QueueEntry {
            QueueEntry(id: id, title: title, artist: artist, image: nil,
                       imageURL: imageURL.flatMap { URL(string: $0) }, uri: uri)
        }
    }

    private static let playedHistoryKey = "playedHistory"

    private static func loadPlayedHistory() -> [PlayedItem] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: playedHistoryKey),
           let list = try? JSONDecoder().decode([PlayedItem].self, from: data) { return list }
        // First start after the update: carry over what the two older lists knew.
        struct OldSpotify: Codable { var uri: String; var title: String; var artist: String; var imageURL: String? }
        struct OldYouTube: Codable { var url: String; var title: String; var artist: String; var imageURL: String? }
        var list: [PlayedItem] = []
        if let data = defaults.data(forKey: "spotifyHistory"),
           let old = try? JSONDecoder().decode([OldSpotify].self, from: data) {
            list += old.map { PlayedItem(uri: $0.uri, title: $0.title, artist: $0.artist, imageURL: $0.imageURL) }
        }
        if let data = defaults.data(forKey: "youtubeHistory"),
           let old = try? JSONDecoder().decode([OldYouTube].self, from: data) {
            list += old.map { PlayedItem(uri: "yt:" + $0.url, title: $0.title, artist: $0.artist, imageURL: $0.imageURL) }
        }
        return list
    }

    /// Makes `item` the song playing now; the one that was playing before moves into the history.
    private func recordPlayed(_ item: PlayedItem) {
        if let previous = playedNow, previous.uri != item.uri,
           !(previous.videoID != nil && previous.videoID == item.videoID) {
            playedHistory.removeAll { $0.uri == previous.uri || ($0.videoID != nil && $0.videoID == previous.videoID) }
            playedHistory.append(previous)
            if playedHistory.count > 24 { playedHistory.removeFirst(playedHistory.count - 24) }
            if let data = try? JSONEncoder().encode(playedHistory) {
                UserDefaults.standard.set(data, forKey: MediaController.playedHistoryKey)
            }
        }
        playedNow = item
    }

    private func refreshSpotifyQueue() {
        queueToken += 1
        let token = queueToken
        guard SpotifyWebAPI.shared.connected else {
            showSpotifyHistory()
            return
        }
        Task { @MainActor [weak self] in
            let entries = await SpotifyWebAPI.shared.window()
            guard let self, token == self.queueToken else { return }
            if let entries {
                self.showQueue(entries, current: 0, now: self.spotifyNowEntry())
            } else {
                self.showSpotifyHistory()
            }
        }
    }

    /// Without Spotify Premium there is no way to read Spotify's queue, so the strip shows the songs
    /// Indra has seen Spotify play (previous songs only).
    private func showSpotifyHistory() {
        let nowURI = spotifyNow?.uri
        // Only songs Spotify played: videos watched in a browser never show up in Spotify's list.
        let recent = playedHistory.filter { $0.isSpotify && $0.uri != nowURI }.suffix(5)
        let entries = recent.enumerated().map { offset, item in
            item.entry(id: offset - recent.count)
        }
        showQueue(entries, current: 0, now: spotifyNowEntry())
        if entries.isEmpty { queueNote = "Play a few songs and they will show up here" }
    }

    private func spotifyNowEntry() -> QueueEntry? {
        guard let now = spotifyNow else { return nil }
        return now.entry(id: 0)
    }

    private func showQueue(_ entries: [QueueEntry], current: Int, now: QueueEntry?) {
        queueNote = nil
        let withImages = entries.map { entry -> QueueEntry in
            var copy = entry
            copy.image = queueImages[entry.key]
            return copy
        }
        var currentEntry = now
        currentEntry?.image = now.flatMap { queueImages[$0.key] }
        withAnimation(NotchMotion.queue) {
            queueCurrent = current
            queue = withImages
            queueCurrentEntry = currentEntry
        }
        for entry in withImages + (currentEntry.map { [$0] } ?? []) where entry.image == nil {
            if let url = entry.imageURL { fetchSpotifyQueueImage(url, key: entry.key) }
        }
    }

    /// Stores a downloaded cover and puts it on every card that shows that song.
    private func assignQueueImage(_ image: NSImage, key: String) {
        queueImages[key] = image
        if let position = queue.firstIndex(where: { $0.key == key }) {
            queue[position].image = image
        }
        if queueCurrentEntry?.key == key {
            queueCurrentEntry?.image = image
        }
    }

    private func recordSpotify(uri: String, imageURL: String?, key: String) {
        guard let current = track, current.identity == key else { return }
        recordPlayed(PlayedItem(uri: uri, title: current.title, artist: current.artist, imageURL: imageURL))
        scheduleQueueRefresh()
    }

    /// Keeps the strip up to date on its own (and the history complete) whenever the song changes, so the list is
    /// already right when the pointer reaches the strip, not only after it has been hovered.
    private func scheduleQueueRefresh() {
        queueRefreshTask?.cancel()
        queueRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)   // v413: was 0.9 s, so the side row of covers fills sooner
            guard !Task.isCancelled, let self, self.track != nil else { return }
            self.refreshQueue()
        }
    }

    private func fetchSpotifyQueueImage(_ url: URL, key: String) {
        Task { @MainActor [weak self] in
            var found = await SpotifyWebAPI.shared.image(for: url)
            if found == nil {
                // One more try a moment later (the network may still be waking up).
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                found = await SpotifyWebAPI.shared.image(for: url)
            }
            guard let image = found, let self else { return }
            self.assignQueueImage(image, key: key)
        }
    }

    private func refreshMusicQueue() {
        queueNote = nil
        guard isRunning(.music) else {
            queue = []
            queueCurrentEntry = nil
            return
        }
        queueToken += 1
        let token = queueToken
        queueScriptQueue.async {
            let text = MediaController.run(MediaController.queueScript)?.stringValue ?? ""
            Task { @MainActor [weak self] in self?.applyQueue(text, token: token) }
        }
    }

    private func applyQueue(_ text: String, token: Int) {
        guard token == queueToken else { return }
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let first = lines.first,
              let head = Optional(first.components(separatedBy: "§§")),
              let current = Int(head[0].trimmingCharacters(in: .whitespaces)) else {
            queue = []
            queueCurrentEntry = nil
            return
        }
        var now: QueueEntry?
        if head.count >= 3 {
            var entry = QueueEntry(id: current, title: head[1], artist: head[2], image: nil)
            entry.image = queueImages[entry.key]
            if entry.image == nil, track?.title == head[1] { entry.image = artwork }
            now = entry
        }
        var entries: [QueueEntry] = []
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: "§§")
            guard parts.count >= 3, let index = Int(parts[0]) else { continue }
            var entry = QueueEntry(id: index, title: parts[1], artist: parts[2], image: nil)
            entry.image = queueImages[entry.key]
            entries.append(entry)
        }
        withAnimation(NotchMotion.queue) {
            queueCurrent = current
            queue = entries
            queueCurrentEntry = now
        }
        for entry in entries + (now.map { [$0] } ?? []) where entry.image == nil {
            fetchQueueArtwork(for: entry)
        }
    }

    private func fetchQueueArtwork(for entry: QueueEntry) {
        let index = entry.id
        let key = entry.key
        let title = entry.title
        let artist = entry.artist
        // The online lookup starts at once and runs beside the (slow, one at a time) Music script,
        // so covers do not wait for Music to hand over each picture.
        Task { @MainActor [weak self] in
            await self?.fetchCatalogCover(title: title, artist: artist, key: key)
        }
        queueScriptQueue.async {
            let source = "with timeout of 4 seconds\ntell application id \"com.apple.Music\" to return data of artwork 1 of track \(index) of current playlist\nend timeout"
            let data = MediaController.run(source)?.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Songs that are not downloaded yet (the next ones in the queue) have no cover in Music's
                // library; for those the online lookup above provides it.
                if let image = data.flatMap({ NSImage(data: $0) }) {
                    self.assignQueueImage(image, key: key)
                }
            }
        }
    }

    private func fetchCatalogCover(title: String, artist: String, key: String) async {
        if queueImages[key] != nil { return }
        // v413: covers found before are kept on disk, so the side row of covers is filled at once the next time.
        let file = CoverDiskCache.file(for: "\(title)|\(artist)")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            assignQueueImage(image, key: key)
            return
        }
        guard var parts = URLComponents(string: "https://itunes.apple.com/search") else { return }
        parts.queryItems = [URLQueryItem(name: "term", value: "\(title) \(artist)"),
                            URLQueryItem(name: "media", value: "music"),
                            URLQueryItem(name: "entity", value: "song"),
                            URLQueryItem(name: "limit", value: "1")]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let small = first["artworkUrl100"] as? String,
              let big = URL(string: small.replacingOccurrences(of: "100x100", with: "300x300")),
              let (pictureData, _) = try? await URLSession.shared.data(from: big),
              let image = NSImage(data: pictureData) else { return }
        try? pictureData.write(to: file, options: .atomic)
        assignQueueImage(image, key: key)
    }

    /// Plays the chosen song: a song of the current playlist, a YouTube video, or a Spotify song, whichever player
    /// is playing now. Choosing a song of the other player stops the one that is playing.
    func playQueueEntry(_ entry: QueueEntry) {
        noteSkip(entry.id < 0 ? .backward : .forward)
        let playingInBrowser = track?.source == .system
        let hint = playingInBrowser ? (track?.title ?? "") : ""
        // v486: the browser that is playing (any browser), else the one that played last.
        let playingBrowser = YouTubeBrowsers.browser(forBundleID: track?.appBundleID)
        let browserID = playingBrowser?.id
        let browserName = (playingBrowser ?? YouTubeBrowsers.last)?.name ?? "the browser"
        if let uri = entry.uri, uri.hasPrefix("yt:") {
            let target = String(uri.dropFirst(3))
            let coming = track?.source
            youtubeQueue.async { [weak self] in
                let worked = YouTubeProbe.open(url: target, titleHint: hint, browserID: browserID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if worked {
                        HealthMonitor.shared.resolve(id: "queue-switch")
                        // Coming from Spotify or Music: they must not keep playing under the video.
                        if let coming, coming == .spotify || coming == .music { self.pauseNativePlayers() }
                    } else {
                        HealthMonitor.shared.report(id: "queue-switch",
                                                    title: "A YouTube video could not be started from the side album bar",
                                                    detail: "\(browserName) did not move to \"\(entry.title)\". Check that it is open with a YouTube tab and that Indra is allowed to control it (Privacy & Security ▸ Automation).",
                                                    fix: .reauthorizeAutomation)
                    }
                }
            }
        } else if playingInBrowser, entry.uri == nil {
            youtubeQueue.async {
                let worked = YouTubeProbe.play(index: entry.id, titleHint: hint, browserID: browserID)
                Task { @MainActor in
                    if worked {
                        HealthMonitor.shared.resolve(id: "queue-switch")
                    } else {
                        HealthMonitor.shared.report(id: "queue-switch",
                                                    title: "A song could not be started from the side album bar",
                                                    detail: "The YouTube page did not react when \"\(entry.title)\" was chosen.",
                                                    fix: .browserJavaScript(bundle: browserID ?? YouTubeBrowsers.safari.id))
                    }
                }
            }
        } else if let uri = entry.uri, uri.hasPrefix("spotify:") {
            // A Spotify song, maybe chosen while a YouTube video plays: the video stops first.
            if playingInBrowser { youtubeQueue.async { _ = YouTubeProbe.pauseAll(browserID: browserID) } }
            playSpotify(uri: uri, title: entry.title)
        } else if let uri = entry.uri {
            send("play track \"\(uri)\"")
        } else {
            send("play track \(entry.id) of current playlist")
        }
        slideRow(to: entry)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.refreshQueue()
        }
    }

    /// Starts a Spotify song by its address, whatever is playing now (Spotify is opened if it is not running:
    /// the person has just chosen it).
    private func playSpotify(uri: String, title: String) {
        guard !uri.contains("\""), !uri.contains("\\") else { return }
        let script = "tell application id \"com.spotify.client\" to play track \"\(uri)\""
        scriptQueue.async {
            let worked = MediaController.run(script) != nil
            Task { @MainActor in
                if worked {
                    HealthMonitor.shared.resolve(id: "queue-switch")
                } else {
                    HealthMonitor.shared.report(id: "queue-switch",
                                                title: "A Spotify song could not be started from the side album bar",
                                                detail: "Spotify did not start \"\(title)\". Check that Indra is allowed to control Spotify (Privacy & Security ▸ Automation).",
                                                fix: .reauthorizeAutomation)
                }
            }
        }
    }

    /// Pauses Apple Music and Spotify when they are running and playing.
    private func pauseNativePlayers() {
        for source in [MediaSource.music, .spotify] where isRunning(source) {
            let script = "tell application id \"\(source.bundleID)\" to pause"
            scriptQueue.async { _ = MediaController.run(script) }
        }
    }

    /// Moves the row at once: the chosen card takes the middle, the old current card and its neighbours
    /// slide over, and the cards that fall out of range leave. New cards arrive with the next refresh.
    private func slideRow(to chosen: QueueEntry) {
        var all = queue
        if let current = queueCurrentEntry { all.append(current) }
        let shift = chosen.id
        let relative = chosen.uri != nil          // Spotify ids are relative to the current song
        var next: [QueueEntry] = []
        for entry in all where entry.id != shift && abs(entry.id - shift) <= 5 {
            next.append(relative ? entry.moved(to: entry.id - shift) : entry)
        }
        next.sort { $0.id < $1.id }
        withAnimation(NotchMotion.queue) {
            queue = next
            queueCurrent = relative ? 0 : shift
            queueCurrentEntry = relative ? chosen.moved(to: 0) : chosen
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        if track?.source == .system {
            // Show the new state at once; the real state follows from macOS a moment later.
            if var current = track {
                current.position = current.elapsed(at: Date())
                current.positionDate = Date()
                current.isPlaying.toggle()
                track = current
                notifyPresence()
            }
            system.send("toggle")
            return
        }
        send("playpause")
    }

    /// A skip starts the new song at 0: the bar and the stylus move there at once, not when the player answers.
    private func restartPosition() {
        guard var current = track, current.source != .identified else { return }
        current.position = 0
        current.positionDate = Date()
        track = current
    }

    func nextTrack() {
        noteSkip(.forward)
        restartPosition()
        if track?.source == .system { system.send("next"); return }
        send("next track")
    }

    func previousTrack() {
        noteSkip(.backward)
        restartPosition()
        if track?.source == .system { system.send("prev"); return }
        send("previous track")
    }

    func seek(to seconds: TimeInterval) {
        guard var current = track else { return }
        current.position = seconds
        current.positionDate = Date()
        track = current
        if current.source == .system {
            system.send("seek \(seconds)")
            return
        }
        send("set player position to \(seconds.finiteInt)")
    }

    private func send(_ command: String) {
        guard track?.source != .identified, track?.source != .system, let source = activeSource() else { return }
        let script = "tell application id \"\(source.bundleID)\" to \(command)"
        let bundle = source.bundleID
        scriptQueue.async {
            let result = MediaController.run(script)
            // v426: when macOS refuses Indra control of the player (Automation, error -1743), play / pause / next /
            // previous / seek still work through macOS Now Playing (the same thing the keyboard media keys use), so the
            // buttons never go dead because of a refusal. The side bar and the song list still need the permission.
            guard result == nil, HealthMonitor.automationStatus(bundle: bundle) == OSStatus(-1743),
                  let fallback = MediaController.nowPlayingCommand(for: command) else { return }
            Task { @MainActor in
                Trace.log("CONTROL \(bundle) refused Apple events: \"\(fallback)\" sent through macOS Now Playing")
                SystemNowPlaying.shared.send(fallback)
            }
        }
    }

    /// The Now Playing helper's word for an Apple Music / Spotify AppleScript command (nil: it has no equivalent).
    nonisolated private static func nowPlayingCommand(for command: String) -> String? {
        switch command {
        case "playpause": return "toggle"
        case "next track": return "next"
        case "previous track": return "prev"
        default:
            let prefix = "set player position to "
            if command.hasPrefix(prefix) { return "seek " + String(command.dropFirst(prefix.count)) }
            return nil
        }
    }

    private func activeSource() -> MediaSource? {
        if let source = track?.source, isRunning(source) { return source }
        return [MediaSource.music, .spotify].first { isRunning($0) }
    }

    /// Never launch a player just to talk to it.
    private func isRunning(_ source: MediaSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        // v419: NSAppleScript is not safe to run on several threads at once, and Indra ran scripts from the state queue,
        // the playlist queue, the cover fetches and the YouTube probe at the same time. One at a time, always.
        guard AppleScriptGate.acquire() else { return nil }
        defer { AppleScriptGate.lock.unlock() }
        guard let script = NSAppleScript(source: AppleScriptGate.bounded(source)) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

/// One song in the playlist around the current one.
struct QueueEntry: Identifiable, Equatable {
    /// Position in the current playlist.
    let id: Int
    let title: String
    let artist: String
    var image: NSImage?
    /// Spotify songs: where to download the cover, and the song to play.
    var imageURL: URL? = nil
    var uri: String? = nil

    /// Stays the same while the card moves along the row.
    var key: String { uri ?? "\(id)|\(title)|\(artist)" }

    func moved(to newID: Int) -> QueueEntry {
        QueueEntry(id: newID, title: title, artist: artist, image: image, imageURL: imageURL, uri: uri)
    }
}


/// Small on-disk store for the covers of songs in the lock screen's side row (in the app's Caches folder; macOS may
/// clear it, then the covers are simply fetched again).
enum CoverDiskCache {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("IndraCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".img")
    }

    /// Covers not used for 45 days are removed (a cover that is used is not touched, so it never expires while it matters).
    static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-45 * 24 * 3600)
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if date < limit { try? fm.removeItem(at: file) }
        }
    }
}


/// Every AppleScript Indra runs goes through this one lock (see `MediaController.run`).
enum AppleScriptGate {
    static let lock = NSLock()

    /// v491: how long a script may run, and how long a caller may wait for its turn. Without limits one hung player (Music
    /// or a browser that stops answering Apple events keeps a script waiting for two minutes) kept the lock, every other
    /// script queued behind it, and the now-playing, queue and lyrics features all stopped together.
    static let scriptSeconds = 5
    static let waitSeconds: TimeInterval = 8

    /// The script wrapped in an Apple events timeout (unless it already has one).
    static func bounded(_ source: String) -> String {
        source.contains("with timeout") ? source : "with timeout of \(scriptSeconds) seconds\n\(source)\nend timeout"
    }

    /// Takes the lock, giving up after `waitSeconds` (the caller then treats the script as failed).
    static func acquire() -> Bool { lock.lock(before: Date().addingTimeInterval(waitSeconds)) }
}
