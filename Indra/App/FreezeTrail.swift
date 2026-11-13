import Foundation

/// v544: the black box for a whole-Mac freeze.
///
/// When the whole Mac stops (cursor, keyboard, display) and only a hard shutdown helps, Indra's normal logs are useless: they are
/// written a second later and from memory, so the last seconds before the freeze are never on disk. This file is different:
/// every line is forced all the way to the disk (`F_FULLFSYNC`) before the next thing happens, so after a hard shutdown the LAST
/// line is exactly the last thing Indra did. It only records the few risky moments (a file dropped on the notch, a send to Blip or
/// AirDrop, a private driver call), never anything personal, and keeps the last 300 lines.
///
/// File: ~/Library/Application Support/Indra/Problems/freeze-trail.txt
enum FreezeTrail {
    private static let queue = DispatchQueue(label: "com.indra.freezetrail", qos: .utility)
    private static let maxBytes = 24_000
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Indra/Problems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("freeze-trail.txt")
    }()
    private static var handle: FileHandle?
    private static var lastText = ""
    private static var lastAt = Date.distantPast

    /// v546: a heartbeat while a risky moment lasts. Every 2 s: a line that says whether Indra's main thread still answered (and how
    /// fast) and the load of the Mac. After a freeze the last heartbeat shows which it was: lines that stop at once = the whole
    /// Mac stopped (Indra was not the one waiting); "main thread answered after N s" growing = Indra itself was stuck.
    /// Written without the full disk flush (a plain write), so it adds almost nothing to the disk's work.
    private static var beatTimer: DispatchSourceTimer?
    private static var beatUntil = Date.distantPast

    static func beginHeartbeat(for seconds: TimeInterval, why: String) {
        queue.async {
            let until = Date().addingTimeInterval(seconds)
            if until > beatUntil { beatUntil = until }
            guard beatTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
            timer.setEventHandler {
                if Date() >= beatUntil {
                    timer.cancel()
                    beatTimer = nil
                    return
                }
                let sent = Date()
                // The answer comes back on the main thread; if it is blocked the line below says so when it finally arrives.
                DispatchQueue.main.async {
                    let delay = Date().timeIntervalSince(sent)
                    if delay > 0.5 { mark("heartbeat: main thread answered after \(String(format: "%.1f", delay)) s", flush: false) }
                }
                var loads = [Double](repeating: 0, count: 3)
                _ = getloadavg(&loads, 3)
                mark("heartbeat (\(why)): load \(String(format: "%.1f", loads[0])), thermal \(ProcessInfo.processInfo.thermalState.rawValue)", flush: false)
            }
            beatTimer = timer
            timer.resume()
        }
    }

    /// Writes one line and waits (on a background queue, never the caller) until the disk has it.
    /// `flush: false` is for heartbeats: a plain write, no full flush of the disk.
    static func mark(_ text: String, flush: Bool = true) {
        let now = Date()
        queue.async {
            // The same line again within a second adds nothing.
            if text == lastText, now.timeIntervalSince(lastAt) < 1 { return }
            lastText = text
            lastAt = now
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
            }
            guard let handle else { return }
            let line = "\(stamp.string(from: now))  \(text)\n"
            if let data = line.data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                if flush { _ = fcntl(handle.fileDescriptor, F_FULLFSYNC) } else { fsync(handle.fileDescriptor) }
            }
            trimIfNeeded()
        }
    }

    /// v547: the last lines the PREVIOUS run wrote (read at launch, before this run adds its own marker), and when it last wrote.
    /// After a hard shutdown this is exactly the last thing Indra did; it goes into the "did not close normally" problem.
    static func previousRunTail(_ count: Int) -> (text: String, at: Date?) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let marker = lines.lastIndex(where: { $0.contains("---- Indra started") }) { lines = Array(lines[(marker + 1)...]) }
        let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return (lines.suffix(count).joined(separator: "\n"), at)
    }

    /// Called once at launch: starts a new session in the file and keeps the end of the previous one.
    static func startSession(build: String) {
        mark("---- Indra started (build \(build)); the lines above this one are from the run before ----")
    }

    private static func trimIfNeeded() {
        guard let handle,
              let size = try? handle.seekToEnd(), size > UInt64(maxBytes * 2),
              let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maxBytes)
        // Start at a whole line.
        let text = String(decoding: keep, as: UTF8.self)
        let trimmed = text.drop(while: { $0 != "\n" }).dropFirst()
        try? handle.close()
        Self.handle = nil
        try? String(trimmed).write(to: url, atomically: true, encoding: .utf8)
    }
}
