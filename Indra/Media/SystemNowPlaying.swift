import AppKit

/// What macOS says is playing right now, from any app.
struct SystemPlayback: Sendable, Equatable {
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    /// Cover picture; only present on the update where it changed.
    var artwork: Data?

    /// v564: macOS reports a browser's media in steps, and a report can arrive with parts missing (no title, no artist or album,
    /// no length, no cover), most often right when the slider is moved or a video buffers. Taken as it came, such a report looked
    /// like a different, nameless song: the cover was dropped, the length went to 0 and the slider went blank. The parts a report
    /// lacks are taken from the one before, from the same app, for the same song. A different song borrows nothing.
    func completed(from previous: SystemPlayback) -> SystemPlayback {
        guard previous.bundleID == bundleID, !previous.title.isEmpty else { return self }
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var next = self
        if next.title.isEmpty || normalized(next.title) == normalized(previous.title) {
            // Two different songs can share a title: with two different artists nothing is borrowed.
            let sameSong = next.artist.isEmpty || previous.artist.isEmpty || normalized(next.artist) == normalized(previous.artist)
            guard sameSong else { return next }
            if next.title.isEmpty { next.title = previous.title }
            if next.artist.isEmpty { next.artist = previous.artist }
            if next.album.isEmpty { next.album = previous.album }
            if next.duration <= 0 { next.duration = previous.duration }
            if next.artwork == nil { next.artwork = previous.artwork }
        }
        return next
    }
}

/// Collects bytes from a pipe and hands back complete lines. Used from the pipe's reader queue only.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        // A helper that never ends a line must not make this grow without limit.
        if buffer.count > 16_000_000 { buffer.removeAll() }
        return lines
    }
}

/// System-wide "Now Playing": Safari, Chrome, YouTube, Spotify, VLC, anything that reports to macOS.
/// Runs the perl helper (see NowPlayingHelper) and keeps it alive. Event driven: the helper only
/// speaks when something changes (plus a light re-sync every few seconds).
@MainActor
final class SystemNowPlaying: ObservableObject {
    static let shared = SystemNowPlaying()

    enum Status: Equatable {
        case off
        case preparing
        case running
        case unavailable(String)
    }

    @Published private(set) var status: Status = .off
    /// The most recent report, nil when nothing is registered as playing.
    @Published private(set) var current: SystemPlayback?

    /// Called on every report (nil: nothing playing, or the helper ended).
    var onPlayback: ((SystemPlayback?) -> Void)?

    private enum Event: Sendable {
        case ready
        case error(String)
        case nothing
        case playback(SystemPlayback)
    }

    private var wantsRun = false
    private var process: Process?
    private var input: FileHandle?
    private var paths: NowPlayingHelper.Paths?
    private var restarts = 0
    private var integrityRetries = 0
    private var launchedAt = Date.distantPast
    private var retryTask: Task<Void, Never>?
    /// v564: when the last report came (a report completes itself from the one before only while that one is recent).
    private var currentAt = Date.distantPast
    private var lastCompletionLog = Date.distantPast

    private init() {}

    // MARK: - Start / stop

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    func start() {
        guard Preferences.systemNowPlaying else {
            status = .off
            return
        }
        guard !wantsRun else { return }
        wantsRun = true
        restarts = 0
        // Writing to a helper that just quit must not take the app down.
        signal(SIGPIPE, SIG_IGN)
        status = .preparing

        Task.detached(priority: .utility) { [weak self] in
            let result = NowPlayingHelper.prepare()
            await MainActor.run {
                guard let self, self.wantsRun else { return }
                switch result {
                case .success(let paths):
                    self.paths = paths
                    self.launch()
                case .failure(.sandboxed):
                    self.wantsRun = false
                    self.status = .unavailable("Needs the full-access build (indra-install --full)")
                case .failure(.failed(let message)):
                    self.wantsRun = false
                    self.status = .unavailable(message)
                }
            }
        }
    }

    func stop() {
        wantsRun = false
        retryTask?.cancel()
        retryTask = nil
        teardown()
        status = .off
        report(nil)
    }

    private func teardown() {
        if let process {
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            try? input?.close()
            if process.isRunning { process.terminate() }
        }
        process = nil
        input = nil
    }

    // MARK: - Launch

    private func launch() {
        guard wantsRun, let paths else { return }
        teardown()

        // Never hand a changed file to perl: if the helper's files are not the ones Indra wrote, build them again.
        guard NowPlayingHelper.verify(paths) else {
            integrityRetries += 1
            NowPlayingHelper.log("helper files changed on disk (check \(integrityRetries)); rebuilding")
            self.paths = nil
            wantsRun = false
            if integrityRetries > 2 {
                status = .unavailable("The Now Playing helper's files keep changing; see nowplaying.log")
            } else {
                start()
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [paths.script.path, paths.library.path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let splitter = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in splitter.feed(data) {
                guard let event = SystemNowPlaying.parse(line) else { continue }
                Task { @MainActor in self?.handle(event) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            NowPlayingHelper.log("perl: " + String(decoding: data, as: UTF8.self))
        }
        proc.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            let bySignal = ended.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.ended(ended, code: code, bySignal: bySignal) }
        }

        do {
            try proc.run()
        } catch {
            NowPlayingHelper.log("could not start perl: \(error.localizedDescription)")
            IndraLog.error("Now-playing: could not start the helper", error)
            status = .unavailable("Could not start the helper (\(error.localizedDescription))")
            wantsRun = false
            return
        }
        process = proc
        input = stdin.fileHandleForWriting
        launchedAt = Date()
        status = .preparing
    }

    private func ended(_ finished: Process, code: Int32, bySignal: Bool) {
        guard finished === process else { return }
        // v490: say HOW it ended. A crash (signal) and a quiet exit were both just "status N" before, which made the
        // reports from other Macs impossible to read.
        NowPlayingHelper.log(bySignal ? "helper was killed by signal \(code)" : "helper ended with status \(code)")
        process = nil
        input = nil
        report(nil)
        guard wantsRun else { return }

        // Exit codes 2...4 come from the helper itself (load failed / MediaRemote unavailable): retrying cannot help.
        // (A signal number such as 4 = SIGILL is not one of those.)
        if !bySignal, (2...4).contains(code) {
            if case .unavailable = status { return }
            status = .unavailable("macOS refused the Now Playing helper (see nowplaying.log)")
            wantsRun = false
            return
        }
        if Date().timeIntervalSince(launchedAt) > 30 { restarts = 0 }
        restarts += 1
        guard restarts <= 5 else {
            // v490: giving up for good meant that one bad moment (a stream with odd metadata, a Mac just woken up) switched
            // Now Playing off until Indra was reopened. Say so, then keep trying quietly once a minute.
            NowPlayingHelper.log("helper stopped \(restarts - 1) times in a row; trying again in a minute")
            status = .unavailable("The Now Playing helper keeps stopping (see nowplaying.log)")
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self, self.wantsRun, self.process == nil else { return }
                self.restarts = 4   // one more quick attempt, then the minute-long wait again
                self.launch()
            }
            return
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(restarts) * 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    // MARK: - Events

    private func handle(_ event: Event) {
        switch event {
        case .ready:
            status = .running
        case .error(let message):
            NowPlayingHelper.log("helper error: \(message)")
            status = .unavailable(message)
            wantsRun = false
            teardown()
            report(nil)
        case .nothing:
            if status != .running { status = .running }
            report(nil)
        case .playback(let playback):
            if status != .running { status = .running }
            report(playback)
        }
    }

    private func report(_ playback: SystemPlayback?) {
        // Artwork only arrives once per picture; keep it for the repeated updates that follow. v564: and complete a report that
        // arrives with parts missing (see `completed`). What is handed on is the completed report, so the cover also reaches the
        // player again with every update, not only with the one that carried it (a cover that was missed once was never shown).
        var merged = playback
        if let next = playback, let previous = current, Date().timeIntervalSince(currentAt) < 20 {
            let filled = next.completed(from: previous)
            if filled != next, Date().timeIntervalSince(lastCompletionLog) > 5 {
                lastCompletionLog = Date()
                Trace.log("SYSTEM \(next.bundleID): a report with parts missing was completed from the one before (title \(next.title.isEmpty ? "missing" : "ok"), length \(next.duration > 0 ? "ok" : "missing"), cover \(next.artwork == nil ? "missing" : "ok"))")
            }
            merged = filled
        }
        if merged != nil { currentAt = Date() }
        if current != merged { current = merged }
        onPlayback?(merged)
    }

    nonisolated private static func parse(_ line: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["ready"] as? Bool == true { return .ready }
        if let message = object["error"] as? String { return .error(message) }
        guard object["has"] as? Bool == true else { return .nothing }
        let art = (object["art"] as? String).flatMap { Data(base64Encoded: $0) }
        return .playback(SystemPlayback(
            bundleID: object["bundle"] as? String ?? "",
            title: object["title"] as? String ?? "",
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            duration: (object["duration"] as? NSNumber)?.doubleValue ?? 0,
            position: (object["position"] as? NSNumber)?.doubleValue ?? 0,
            isPlaying: object["playing"] as? Bool ?? false,
            artwork: art))
    }

    // MARK: - Commands

    /// play, pause, toggle, stop, next, prev, seek <seconds>
    func send(_ command: String) {
        guard let input, process?.isRunning == true else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: - App names

    /// "Safari", "Google Chrome" ... for a bundle identifier.
    static func appName(for bundleID: String) -> String? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
