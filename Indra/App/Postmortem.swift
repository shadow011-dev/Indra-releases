import Foundation

/// v547: after a run that ended abruptly (a hard shutdown after a freeze), saves what the system itself logged around the last moment
/// Indra was alive: errors, faults and hang / watchdog / timeout words from Indra, Blip, the window server and the kernel. The file is
/// ~/Library/Application Support/Indra/Problems/previous-run-system-log.txt. It is made in the background, 30 s after launch, at the
/// lowest priority, with a limit of 90 s and about 400 KB, and nothing waits for it. Best effort: macOS shows another process's
/// log lines only to an administrator.
enum Postmortem {
    private static var started = false

    static func capture(lastActivity: Date?) {
        guard !started else { return }
        started = true
        let last = lastActivity ?? Date().addingTimeInterval(-10 * 60)
        let start = last.addingTimeInterval(-2 * 60)
        let end = min(Date(), last.addingTimeInterval(12 * 60))
        guard end > start else { return }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { run(from: start, to: end) }
    }

    private static func run(from start: Date, to end: Date) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Indra/Problems", isDirectory: true)
        let out = dir.appendingPathComponent("previous-run-system-log.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: out) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let words = ["watchdog", "hang", "timed out", "stuck", "not responding", "unresponsive", "deadlock", "Indra", "Blip"]
            .map { "eventMessage CONTAINS[c] \"\($0)\"" }.joined(separator: " OR ")
        let predicate = "(process == \"Indra\" OR process == \"Blip\" OR process == \"WindowServer\" OR process == \"kernel\" "
            + "OR process == \"watchdogd\" OR process == \"launchd\") AND (messageType == fault OR messageType == error OR \(words))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "19", "/usr/bin/log", "show", "--style", "compact",
                             "--start", formatter.string(from: start), "--end", formatter.string(from: end),
                             "--predicate", predicate]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in
            try? handle.close()
            trim(out)
            Trace.log("POSTMORTEM: the system log around the last run's end is in previous-run-system-log.txt")
        }
        guard (try? process.run()) != nil else { try? handle.close(); return }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 90) {
            if process.isRunning { process.terminate() }
        }
    }

    /// Keeps the END of a big file (the lines nearest the freeze).
    private static func trim(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 400_000,
              let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(300_000).write(to: url)
    }
}
