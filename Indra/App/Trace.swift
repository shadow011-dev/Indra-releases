import Foundation

/// v400: a millisecond timeline of what the media, lyrics and animated-cover code did, so a slow song change can be
/// read from the file instead of guessed. The file is ~/Library/Application Support/Indra/Problems/timeline.txt
/// (the last 400 lines). It holds song titles and nothing else personal.
enum Trace {
    private static let queue = DispatchQueue(label: "com.indra.trace", qos: .utility)
    private static var lines: [String] = []
    private static var flushPending = false
    private static var stallTimer: Timer?
    private static var lastBeat = Date()
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
        return dir.appendingPathComponent("timeline.txt")
    }()

    static func log(_ text: String) {
        let now = Date()
        queue.async {
            lines.append("\(stamp.string(from: now))  \(text)")
            if lines.count > 400 { lines.removeFirst(lines.count - 400) }
            guard !flushPending else { return }
            flushPending = true
            queue.asyncAfter(deadline: .now() + 1.0) {
                flushPending = false
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Notes every time the main thread (everything you see and click) was held up for more than a third of a second.
    @MainActor
    static func startStallWatch() {
        guard stallTimer == nil else { return }
        lastBeat = Date()
        // v522: every 0.5 s with a little slack (was every 0.2 s for the whole session: five wake-ups a second, idle).
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            let now = Date()
            let late = now.timeIntervalSince(lastBeat) - 0.5
            lastBeat = now
            // v495: a gap of many seconds is the Mac having slept (or the app being napped), not the main thread being busy.
            if late > 0.35, late < 20 { log("MAIN THREAD BLOCKED for \(Int(late * 1000)) ms") }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
        log("Indra started (build \(IndraLog.appBuild)); \(SigningDiagnostics.summary)")
    }
}
