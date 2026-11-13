import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

/// v424: shared by every lyrics request. After a 429 / 503 the server's wish for quiet applies to all of them.
private actor LyricsGate {
    private var blockedUntil = Date.distantPast
    func block(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(min(max(seconds, 0), 60))
        if until > blockedUntil { blockedUntil = until }
    }
    func remaining() -> TimeInterval { max(0, blockedUntil.timeIntervalSinceNow) }
}
private let lyricsGate = LyricsGate()

/// Looks up lyrics for the current song from the free LRCLIB service (time-synced when available).
@MainActor
final class LyricsStore: ObservableObject {
    enum Phase { case idle, loading, found, missing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var isSynced = false
    /// Changes whenever a new set of lyrics is shown, so the list is rebuilt instead of animated from the old song.
    @Published private(set) var generation = 0

    /// The lyrics as they were found; `lines` is these, or the Latin-letter version when that setting is on.
    private var original: [LyricLine] = []
    private var latin = Preferences.lyricsLatin
    private var loadedKey: String?
    private var task: Task<Void, Never>?
    /// v418: after 2 s without an answer the song is shown as "no lyrics" (the lookup carries on in the background and the
    /// lyrics still appear if they turn up). `missingKey` is the song that stands as "no lyrics" right now.
    private var softTask: Task<Void, Never>?
    private var missingKey: String?
    /// Songs already looked up this session open instantly the next time.
    private static var cache: [String: (synced: String?, plain: String?)] = [:]
    private static var cacheOrder: [String] = []
    /// Songs the server clearly answered "no lyrics" for, for one minute: unlocking or tapping again does not ask again.
    private static var recentMisses: [String: Date] = [:]

    // MARK: Lyrics kept on disk

    private struct SavedLyrics: Codable {
        var synced: String?
        var plain: String?
        var at: Double
        /// The song's length when it was saved (nil in older files): a different recording is not given these lyrics.
        var duration: Double?
    }

    private static let diskURL: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Indra", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("lyrics.json")
    }()

    /// Every song found so far (up to 300): the lyrics of a song heard before never need the network again.
    private static var disk: [String: SavedLyrics] = {
        guard let url = diskURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: SavedLyrics].self, from: data) else { return [:] }
        return saved
    }()

    private static func saveToDisk(_ key: String, _ result: (synced: String?, plain: String?), duration: Double) {
        disk[key] = SavedLyrics(synced: result.synced, plain: result.plain, at: Date().timeIntervalSince1970,
                                duration: duration > 0 ? duration : nil)
        if disk.count > 300 {
            let oldest = disk.sorted { $0.value.at < $1.value.at }.prefix(disk.count - 300).map(\.key)
            for old in oldest { disk[old] = nil }
        }
        guard let url = diskURL else { return }
        let snapshot = disk
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// v522: kept so it can be removed. It had no handle, so every store that was ever made stayed registered for good and was
    /// called on every write to the app's settings.
    private var defaultsObserver: NSObjectProtocol?

    init() {
        // Switching the setting changes the lyrics on screen straight away.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLatin() }
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private func refreshLatin() {
        let wanted = Preferences.lyricsLatin
        guard wanted != latin else { return }
        latin = wanted
        guard phase == .found else { return }
        lines = display(original)
        generation &+= 1   // the list is rebuilt, so the new letters appear cleanly
    }

    private func display(_ source: [LyricLine]) -> [LyricLine] {
        guard latin else { return source }
        return source.map { LyricLine(id: $0.id, time: $0.time, text: LyricsRomanizer.latin($0.text)) }
    }

    func load(for track: TrackInfo?) {
        guard let track, track.source != .identified else {
            task?.cancel()
            softTask?.cancel()
            missingKey = nil
            loadedKey = nil
            phase = .idle
            original = []
            lines = []
            return
        }
        let key = track.identity
        guard key != loadedKey else { return }
        loadedKey = key
        task?.cancel()
        softTask?.cancel()
        // v424: lyrics are kept under the song (cleaned title + main artist), not under the source and album, so the same
        // song found again through another player, or with a different album tag, is a hit. The old key is still read.
        let artist = LyricsStore.plainArtist(track.artist)
        let title = track.title, album = track.album, duration = track.duration
        let songKey = LyricsStore.lookupKey(title: title, artist: artist)
        let sameRecording: (Double?) -> Bool = { saved in
            guard duration > 0, let saved, saved > 0 else { return true }
            return abs(saved - duration) <= 20
        }
        for candidate in [songKey, key] {
            if let hit = LyricsStore.cache[candidate] {
                _ = apply(hit)
                return
            }
            if let saved = LyricsStore.disk[candidate], sameRecording(saved.duration) {
                let hit = (synced: saved.synced, plain: saved.plain)
                if apply(hit) {
                    LyricsStore.cache[songKey] = hit
                    if !LyricsStore.cacheOrder.contains(songKey) { LyricsStore.cacheOrder.append(songKey) }   // so it can be evicted too
                    return
                }
            }
        }
        // A song the server clearly said "no lyrics" for a moment ago is not asked again at once.
        if let until = LyricsStore.recentMisses[songKey], until > Date() {
            original = []
            lines = []
            missingKey = key
            phase = .missing
            loadedKey = nil
            return
        }
        // A song that already stands as "no lyrics" and is looked up again (a tap, the screen coming up) stays that way
        // while the quiet retry runs, instead of flipping back to a loading state.
        if !(phase == .missing && missingKey == key) {
            phase = .loading
            original = []
            lines = []
        }
        softTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.loadedKey == key, self.phase == .loading else { return }
            Trace.log("LYRICS no answer after 2 s: shown as no lyrics while the lookup goes on")
            self.missingKey = key
            self.phase = .missing
        }
        let startedAt = Date()
        Trace.log("LYRICS looking for \"\(track.title)\" by \(track.artist) (album \"\(track.album)\", \(track.duration.finiteInt) s)")
        task = Task { [weak self] in
            // v424: a short pause first: skipping through songs only looks up the one that stays, so a burst of skips is
            // not a burst of requests (the server answers 429 to those).
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            // A lookup that failed because the network or LRCLIB hiccuped (a timeout, a busy server, no connection
            // yet right after waking) is not "no lyrics": every request already retries with backoff (see `json`), and
            // the whole lookup is tried again after 5 s and 15 s, quietly, while the view still says "looking".
            // Only a clear "not found" ends as missing straight away.
            var result: (synced: String?, plain: String?) = (nil, nil)
            var definitive = false
            for (attempt, wait) in [0.0, 5.0, 15.0].enumerated() {
                if wait > 0 { try? await Task.sleep(nanoseconds: wait.sleepNanoseconds) }
                guard !Task.isCancelled else { return }
                let reply = await LyricsStore.fetch(title: title, artist: artist, album: album, duration: duration)
                result = (reply.synced, reply.plain)
                definitive = reply.definitive
                if reply.synced != nil || reply.plain != nil || reply.definitive || attempt == 2 { break }
            }
            guard !Task.isCancelled, let self, self.loadedKey == key else {
                Trace.log("LYRICS lookup dropped (song changed or cancelled) after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
                return
            }
            self.softTask?.cancel()
            Trace.log("LYRICS answer after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms: \(result.synced != nil ? "synced" : result.plain != nil ? "plain" : (definitive ? "none (server said so)" : "none (server or network failed)"))")
            if self.apply(result) {
                // Keep only the most recent songs; lyrics of a whole day of listening add up.
                if LyricsStore.cache.count >= 60, let oldest = LyricsStore.cacheOrder.first {
                    LyricsStore.cache[oldest] = nil
                    LyricsStore.cacheOrder.removeFirst()
                }
                if LyricsStore.cache[songKey] == nil { LyricsStore.cacheOrder.append(songKey) }
                LyricsStore.cache[songKey] = result
                LyricsStore.recentMisses[songKey] = nil
                LyricsStore.saveToDisk(songKey, result, duration: duration)
            } else {
                // Not found (or the network failed): allow another try the next time lyrics are asked for.
                if definitive { LyricsStore.recentMisses[songKey] = Date().addingTimeInterval(60) }
                self.loadedKey = nil
            }
        }
    }

    /// Shows a lookup result. Returns false when it holds no usable lyrics.
    private func apply(_ result: (synced: String?, plain: String?)) -> Bool {
        generation &+= 1
        if let synced = result.synced, case let parsed = LyricsStore.parseSynced(synced), !parsed.isEmpty {
            original = parsed
            lines = display(parsed)
            isSynced = true
            missingKey = nil
            phase = .found
            return true
        } else if let plain = result.plain, case let parsed = LyricsStore.parsePlain(plain), !parsed.isEmpty {
            original = parsed
            lines = display(parsed)
            isSynced = false
            missingKey = nil
            phase = .found
            return true
        }
        original = []
        lines = []
        missingKey = loadedKey
        phase = .missing
        return false
    }

    // MARK: - Network

    nonisolated private static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        // LRCLIB asks every app to say who it is; an honest, stable name is what keeps a client off block lists.
        return "Indra/\(version) (build \(build); macOS lyrics lookup)"
    }()

    nonisolated private static func request(_ path: String, _ items: [URLQueryItem]) -> URLRequest? {
        var components = URLComponents(string: "https://lrclib.net/api/" + path)
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `failed` is a network error or a server that could not answer (not a clean "nothing found").
    private enum Reply {
        case ok(Any?)
        case notFound
        case failed
    }

    private enum Kind { case exact, fields, free, titleOnly }

    /// Seconds to wait before try number `attempt + 1`: 2, 4, 8 ... with jitter, so parallel lookups do not retry in step.
    nonisolated private static func backoff(_ attempt: Int) -> TimeInterval {
        2.0 * pow(2.0, Double(attempt)) * Double.random(in: 0.75...1.25)
    }

    /// The server's own wish ("Retry-After": seconds or a date) when it sent one.
    nonisolated private static func retryAfter(_ response: URLResponse?) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    /// v424: one request, with the recovery a busy public server needs. 429 / 500 / 502 / 503 / 504 and network errors
    /// are tried again (up to 3 tries) after the server's Retry-After, or an exponential, jittered 2 s, 4 s; a 429 or 503
    /// also holds back every other lyrics request for that time, so a burst (skipping through songs) cannot turn
    /// one "slow down" into a block. Before, any such answer counted as a failure straight away.
    nonisolated private static func json(_ request: URLRequest?) async -> Reply {
        guard let request else { return .failed }
        var lastCode = 0
        for attempt in 0..<3 {
            let hold = await lyricsGate.remaining()
            if hold > 15 {
                Trace.log("LYRICS server asked for \(Int(hold)) s of quiet: this lookup waits for a later try")
                return .failed
            }
            if hold > 0 { try? await Task.sleep(nanoseconds: hold.sleepNanoseconds) }
            if Task.isCancelled { return .failed }
            var retryIn: TimeInterval = 0
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .failed }
                let code = http.statusCode
                if code == 200 { return .ok(try? JSONSerialization.jsonObject(with: data)) }
                // v398: 404 is "nothing found", and so is 400 (LRCLIB answers 400 to an exact lookup that lacks a field).
                if code == 404 || code == 400 { return .notFound }
                lastCode = code
                guard [429, 500, 502, 503, 504].contains(code) else { return .failed }
                retryIn = retryAfter(response) ?? backoff(attempt)
                if code == 429 || code == 503 { await lyricsGate.block(for: retryIn) }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .failed }
                lastCode = -1
                retryIn = backoff(attempt)
            }
            if attempt == 2 { break }
            Trace.log("LYRICS answer \(lastCode == -1 ? "network error" : String(lastCode)): trying again in \(String(format: "%.1f", min(retryIn, 15))) s")
            try? await Task.sleep(nanoseconds: min(retryIn, 15).sleepNanoseconds)
        }
        Trace.log("LYRICS gave up on a request (last answer \(lastCode == -1 ? "network error" : String(lastCode)))")
        return .failed
    }

    // MARK: Cleaning and matching

    /// Lower case, no accents, letters and digits only, single spaces: "Beyoncé - Halo (Live)" and "beyonce halo live" meet.
    nonisolated static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The title without the tags streaming services add ("(feat. X)", "- Remastered 2011", "[Official Audio]", "| Lyrics").
    nonisolated static func cleaned(_ title: String) -> String {
        var text = title
        let patterns = [
            "\\s*[\\(\\[（【][^\\)\\]）】]*[\\)\\]）】]",
            "\\s+[-–—]\\s+(\\d{4}\\s+)?(remaster\\w*|live|mono|stereo|single|radio|version|from|edit|mix|acoustic|demo|deluxe|bonus|explicit|clean)\\b.*$",
            "\\s+[-–—]\\s+\\d{4}\\s*$",
            "\\s+(feat\\.?|ft\\.?|featuring)\\s+.*$",
            "\\s*[|｜]\\s*.*$",
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// "A, B", "A & B", "A feat. B", "A x B" -> "A": LRCLIB knows one artist name per song.
    nonisolated static func primaryArtist(_ artist: String) -> String {
        let marked = artist.replacingOccurrences(of: "\\s*(,|;|&|\\s[x×]\\s|\\sfeat\\.?\\s|\\sft\\.?\\s|\\sfeaturing\\s|\\swith\\s)\\s*",
                                                 with: "\u{1}", options: [.regularExpression, .caseInsensitive])
        let first = marked.split(separator: "\u{1}").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? artist : first
    }

    /// YouTube auto-generated channels are named "Artist - Topic"; lyrics sites only know "Artist".
    nonisolated static func plainArtist(_ artist: String) -> String {
        artist.hasSuffix(" - Topic") ? String(artist.dropLast(8)) : artist
    }

    /// The key lyrics are kept under: the same song reached through Spotify, Music, a browser or the system player,
    /// with or without an album, with "(Remastered)" or without, is one key. (The old key held the source and the album,
    /// so the same song looked "new" whenever either changed, and its saved lyrics were never found again.)
    nonisolated static func lookupKey(title: String, artist: String) -> String {
        normalized(cleaned(title)) + "|" + normalized(primaryArtist(plainArtist(artist)))
    }

    private struct Candidate {
        var synced: String?
        var plain: String?
        var title: String
        var artist: String
        var duration: Double
    }

    /// What the song is, worked out once per lookup, to rank what the server returns.
    private struct Target {
        let title: String
        let tokens: [String]
        let artistText: String
        let duration: Double

        init(title: String, artist: String, duration: Double) {
            let stop: Set<String> = ["the", "and", "feat", "ft", "with", "a", "of"]
            let text = LyricsStore.normalized(artist)
            self.title = LyricsStore.normalized(LyricsStore.cleaned(title))
            self.artistText = text
            self.tokens = text.split(separator: " ").map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
            self.duration = duration
        }

        func titleScore(_ c: Candidate) -> Double {
            let other = LyricsStore.normalized(LyricsStore.cleaned(c.title))
            guard !title.isEmpty, !other.isEmpty else { return 0 }
            if other == title { return 4 }
            if min(other.count, title.count) >= 3, other.contains(title) || title.contains(other) { return 2 }
            return 0
        }

        func artistScore(_ c: Candidate) -> Double {
            guard !tokens.isEmpty else { return 0 }
            let other = LyricsStore.normalized(c.artist)
            if tokens.contains(where: { other.contains($0) }) { return 3 }
            if other.split(separator: " ").contains(where: { $0.count >= 3 && artistText.contains($0) }) { return 3 }
            return 0
        }

        func score(_ c: Candidate) -> Double {
            var total = titleScore(c) + artistScore(c) + (c.synced != nil ? 1 : 0)
            if duration > 0, c.duration > 0 {
                let d = abs(duration - c.duration)
                total += d <= 2 ? 3 : d <= 5 ? 2 : d <= 10 ? 1 : d <= 30 ? 0 : -3
            }
            return total
        }
    }

    nonisolated private static func candidates(_ reply: Reply) -> [Candidate] {
        guard case .ok(let object) = reply else { return [] }
        func make(_ dict: [String: Any]) -> Candidate? {
            let synced = (dict["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let plain = (dict["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if synced == nil && plain == nil { return nil }
            return Candidate(synced: synced, plain: plain,
                             title: (dict["trackName"] as? String) ?? (dict["name"] as? String) ?? "",
                             artist: (dict["artistName"] as? String) ?? "",
                             duration: (dict["duration"] as? Double) ?? Double((dict["duration"] as? Int) ?? 0))
        }
        if let list = object as? [[String: Any]] { return list.compactMap(make) }
        if let dict = object as? [String: Any], let one = make(dict) { return [one] }
        return []
    }

    /// Runs the lookups of one round together. The exact lookup (when it is there) settles the round the moment it hits.
    nonisolated private static func run(_ jobs: [(Kind, URLRequest?)]) async -> (replies: [(Kind, Reply)], exactHit: Candidate?) {
        await withTaskGroup(of: (Kind, Reply).self, returning: (replies: [(Kind, Reply)], exactHit: Candidate?).self) { group in
            for job in jobs { group.addTask { (job.0, await json(job.1)) } }
            var replies: [(Kind, Reply)] = []
            for await item in group {
                replies.append(item)
                if item.0 == .exact, let hit = candidates(item.1).first {
                    group.cancelAll()
                    return (replies, hit)
                }
            }
            return (replies, nil)
        }
    }

    /// `definitive` is true when every lookup got a real answer, so an empty result truly means "no lyrics".
    ///
    /// v424: two rounds instead of three lookups at once. Round 1 is the exact lookup (when the song has an album and a
    /// duration) plus one search with the cleaned title and the main artist. Only when that finds nothing does round 2
    /// ask the looser questions. Every answer is ranked (title, artist, length, synced) and a wrong song is refused,
    /// so a song is no longer given the lyrics of a neighbour, and an ordinary hit costs 1 to 2 requests, not 3.
    nonisolated private static func fetch(title: String, artist: String, album: String,
                                          duration: TimeInterval) async -> (synced: String?, plain: String?, definitive: Bool) {
        let clean = cleaned(title)
        let lead = primaryArtist(artist)
        let target = Target(title: title, artist: artist, duration: duration)
        var failedAny = false

        func note(_ replies: [(Kind, Reply)]) {
            for (_, reply) in replies { if case .failed = reply { failedAny = true } }
        }
        func best(_ replies: [(Kind, Reply)]) -> Candidate? {
            var top: (Candidate, Double)?
            for (kind, reply) in replies {
                for c in candidates(reply) {
                    let score = target.score(c)
                    switch kind {
                    case .exact: break
                    case .fields: if score < 5 { continue }
                    case .free: if score < 6 || (target.artistScore(c) == 0 && !target.tokens.isEmpty) { continue }
                    case .titleOnly: if score < 7 || target.titleScore(c) < 2 || target.artistScore(c) == 0 { continue }
                    }
                    if top == nil || score > top!.1 { top = (c, score) }
                }
            }
            return top?.0
        }

        // Round 1
        var first: [(Kind, URLRequest?)] = []
        if !album.isEmpty && duration > 0 {
            first.append((.exact, request("get", [URLQueryItem(name: "track_name", value: title),
                                                  URLQueryItem(name: "artist_name", value: artist),
                                                  URLQueryItem(name: "album_name", value: album),
                                                  URLQueryItem(name: "duration", value: String(duration.rounded().finiteInt))])))
        }
        first.append((.fields, request("search", [URLQueryItem(name: "track_name", value: clean),
                                                  URLQueryItem(name: "artist_name", value: lead)])))
        let one = await run(first)
        if let hit = one.exactHit { Trace.log("LYRICS found by the exact lookup"); return (hit.synced, hit.plain, true) }
        note(one.replies)
        if let hit = best(one.replies) { Trace.log("LYRICS found by round 1"); return (hit.synced, hit.plain, true) }

        // Round 2: looser questions, at the same time.
        var second: [(Kind, URLRequest?)] = [
            (.free, request("search", [URLQueryItem(name: "q", value: clean + " " + artist)])),
            (.titleOnly, request("search", [URLQueryItem(name: "q", value: clean)])),
        ]
        if clean != title {
            // A title whose brackets belong to it ("(I Can't Get No) Satisfaction") only matches as written.
            second.append((.fields, request("search", [URLQueryItem(name: "track_name", value: title),
                                                       URLQueryItem(name: "artist_name", value: lead)])))
        }
        let two = await run(second)
        note(two.replies)
        if let hit = best(two.replies) { Trace.log("LYRICS found by round 2"); return (hit.synced, hit.plain, true) }
        return (nil, nil, !failedAny)
    }

    // MARK: - Parsing

    nonisolated static func parseSynced(_ text: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2}(?:\\.\\d{1,3})?)\\]") else { return [] }
        var found: [(TimeInterval, String)] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                found.append((minutes * 60 + seconds, body))
            }
        }
        found.sort { $0.0 < $1.0 }
        return found.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    nonisolated static func parsePlain(_ text: String) -> [LyricLine] {
        let rows = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return rows.enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) }
    }
}
