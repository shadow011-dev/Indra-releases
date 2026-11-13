import AppKit
import Foundation
import MetricKit

/// One saved problem.
struct ProblemEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    /// "Crash", "Freeze", "Unexpected exit", "Error" or "System report".
    var kind: String
    var title: String
    var detail: String
    /// The same problem repeating within ten minutes is counted instead of listed again.
    var count: Int = 1
    /// What Indra was doing just before (newest last).
    var recent: String = ""
}

/// The problem log. Everything that goes wrong (a crash, an uncaught exception, a frozen window, an unexpected
/// exit, a failed task) is written to disk, so it is still there after a restart. Settings > About shows it and
/// builds a report to copy or email.
enum IndraLog {
    static let supportEmail = "shadow.kira011@gmail.com"
    static let changed = Notification.Name("indraProblemLogChanged")

    private static let maxEntries = 500
    private static let queue = DispatchQueue(label: "com.indra.problemlog")
    private static var started = false
    private static var cache: [ProblemEntry] = []
    private static var loaded = false
    private static var crumbs: [String] = []
    private static var termSource: DispatchSourceSignal?
    private static var metrics: MetricsListener?

    // MARK: Files

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Indra/Problems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static var logURL: URL { directory.appendingPathComponent("problems.json") }
    private static var crashURL: URL { directory.appendingPathComponent("crash-pending.txt") }
    private static var sessionURL: URL { directory.appendingPathComponent("session-open") }
    private static var crumbsURL: URL { directory.appendingPathComponent("recent-actions.txt") }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    // MARK: Start

    /// Call once, as early as possible.
    static func start() {
        guard !started else { return }
        started = true
        recoverPreviousSession()
        installCrashHandlers()
        try? appBuild.write(to: sessionURL, atomically: true, encoding: .utf8)
        listenForTermination()
        metrics = MetricsListener()
        if let metrics { MXMetricManager.shared.add(metrics) }
        startWatchdog()
        crumb("Indra started (build \(appBuild))")
    }

    /// Call when Indra quits normally, so the next launch knows it was not a crash.
    static func cleanExit() {
        try? FileManager.default.removeItem(at: sessionURL)
    }

    // MARK: Recording

    /// Saves a problem.
    static func record(_ kind: String, _ title: String, detail: String = "") {
        let now = Date()
        queue.async {
            append(ProblemEntry(date: now, kind: kind, title: title, detail: detail,
                                recent: recentActions(8)))
        }
    }

    /// Saves a handled error (something failed but Indra carried on).
    static func error(_ context: String, _ error: Error? = nil, detail: String = "") {
        if let error {
            if error is CancellationError { return }
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
        }
        var lines: [String] = []
        if let error {
            let ns = error as NSError
            lines.append("\(error.localizedDescription)")
            lines.append("(\(ns.domain) code \(ns.code))")
        }
        if !detail.isEmpty { lines.append(detail) }
        record("Error", context, detail: lines.joined(separator: "\n"))
    }

    /// A short note of what Indra is doing; the last few are saved with every problem.
    static func crumb(_ text: String) {
        let now = Date()
        queue.async {
            let stamp = clockText(now)
            if let last = crumbs.last, last.hasSuffix("  " + text) { return }
            crumbs.append("\(stamp)  \(text)")
            if crumbs.count > 30 { crumbs.removeFirst(crumbs.count - 30) }
            try? crumbs.joined(separator: "\n").write(to: crumbsURL, atomically: false, encoding: .utf8)
        }
    }

    // MARK: Reading

    static func entries() -> [ProblemEntry] {
        queue.sync {
            loadIfNeeded()
            return cache
        }
    }

    static func clear() {
        queue.sync {
            loadIfNeeded()
            cache = []
            save()
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// The text the person copies or emails.
    static func report() -> String {
        let all = entries()
        var out = "Indra problem report\n"
        out += header() + "\n"
        out += "Saved problems: \(all.count)\n"
        for (index, entry) in all.reversed().prefix(60).enumerated() {
            out += "\n──────────────\n"
            out += "#\(index + 1)  [\(entry.kind)]  \(dateText(entry.date))"
            if entry.count > 1 { out += "  (happened \(entry.count) times, last time shown)" }
            out += "\n\(entry.title)\n"
            if !entry.detail.isEmpty { out += "\n\(String(entry.detail.prefix(6000)))\n" }
            if !entry.recent.isEmpty { out += "\nJust before:\n\(entry.recent)\n" }
        }
        if all.isEmpty { out += "\nNo problems saved.\n" }
        return out
    }

    /// App, system and Mac details.
    static func header() -> String {
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        let access = SensoryDiagnostics.isSandboxed ? "Standard" : "Full access"
        return """
        App: \(AppBrand.name) \(appVersion) (build \(appBuild)), \(access)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        \(SigningDiagnostics.summary)
        Mac: \(sysctlString("hw.model")), \(chip)
        Haptics: \(TrackpadActuator.shared.statusLine)
        Report date: \(dateText(Date()))
        """
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    // MARK: Storage (call on `queue`)

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: logURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cache = (try? decoder.decode([ProblemEntry].self, from: data)) ?? []
    }

    private static func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cache) {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private static func append(_ new: ProblemEntry) {
        loadIfNeeded()
        if var last = cache.last, last.kind == new.kind, last.title == new.title,
           new.date >= last.date, new.date.timeIntervalSince(last.date) < 600 {
            last.count += 1
            last.date = new.date
            last.recent = new.recent
            cache[cache.count - 1] = last
        } else {
            cache.append(new)
        }
        if cache.count > maxEntries { cache.removeFirst(cache.count - maxEntries) }
        save()
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    private static func recentActions(_ count: Int) -> String {
        crumbs.suffix(count).joined(separator: "\n")
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: Last session

    /// A crash leaves a note on disk (written by the handlers below); turn it into a saved problem on the next launch.
    private static func recoverPreviousSession() {
        let fm = FileManager.default
        var crashed = false

        if let text = try? String(contentsOf: crashURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            crashed = true
            let lines = text.components(separatedBy: "\n")
            let exception = lines.first { $0.hasPrefix("EXCEPTION ") }
            let signalLine = lines.first { $0.hasPrefix("CRASH ") }
            var title = "Indra crashed"
            var when = Date()
            if let signalLine {
                let parts = signalLine.components(separatedBy: " t=")
                title = "Indra crashed: " + String(parts[0].dropFirst("CRASH ".count))
                if parts.count > 1, let epoch = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)) {
                    when = Date(timeIntervalSince1970: epoch)
                }
            }
            if let exception {
                title = "Indra crashed: " + String(exception.dropFirst("EXCEPTION ".count).prefix(200))
            }
            let before = ((try? String(contentsOf: crumbsURL, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n").suffix(8).joined(separator: "\n")
            queue.sync {
                append(ProblemEntry(date: when, kind: "Crash", title: title,
                                    detail: String(text.prefix(9000)), recent: before))
            }
        }
        try? fm.removeItem(at: crashURL)

        // The marker is removed on a normal quit. If it is still there (and Indra was not just reinstalled),
        // the last session ended some other way.
        if let marker = try? String(contentsOf: sessionURL, encoding: .utf8) {
            if !crashed && marker.trimmingCharacters(in: .whitespacesAndNewlines) == appBuild {
                let before = ((try? String(contentsOf: crumbsURL, encoding: .utf8)) ?? "")
                    .components(separatedBy: "\n").suffix(8).joined(separator: "\n")
                // v547: the last steps the previous run wrote to the freeze trail (fsync'ed one by one), and, in the background, the
                // system log around that moment (Problems/previous-run-system-log.txt): what the window server and the kernel said.
                let trail = FreezeTrail.previousRunTail(14)
                var detail = "It was force-quit, stopped by the system, or the Mac lost power or restarted."
                if !trail.text.isEmpty { detail += "\n\nLast steps written to the freeze trail:\n" + trail.text }
                queue.sync {
                    append(ProblemEntry(date: Date(), kind: "Unexpected exit",
                                        title: "Indra did not close normally last time",
                                        detail: detail,
                                        recent: before))
                }
                Postmortem.capture(lastActivity: trail.at)
                // v543: a Mac that froze (cursor, keyboard and display dead, hard shutdown) leaves exactly this trace. The one part
                // of Indra that talks to a driver shared with the keyboard and the cursor is the trackpad motor, so after an abrupt
                // end it stays off until the person switches "Full-strength haptics" on again.
                if Preferences.strongHaptics {
                    UserDefaults.standard.set(false, forKey: Preferences.strongHapticsKey)
                    crumb("Last run ended abruptly: full-strength haptics (private trackpad driver) switched off")
                    Trace.log("SAFETY: the last run did not end normally; full-strength haptics are off")
                }
            }
            try? fm.removeItem(at: sessionURL)
        }
    }

    // MARK: Crash capture

    private static func installCrashHandlers() {
        let fm = FileManager.default
        fm.createFile(atPath: crashURL.path, contents: nil)
        crashFD = open(crashURL.path, O_WRONLY | O_APPEND)

        // Touch the lazily created globals now, so the handlers never have to allocate.
        _ = crashFrames
        _ = crashClock
        _ = backtrace(crashFrames, 64)

        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "no reason given"
            var text = "EXCEPTION \(name): \(reason)\n"
            text += exception.callStackSymbols.prefix(40).joined(separator: "\n") + "\n"
            if crashFD >= 0, let data = text.data(using: .utf8) {
                data.withUnsafeBytes { raw in
                    _ = write(crashFD, raw.baseAddress, data.count)
                }
            }
        }

        // Crashes on a thread whose stack is gone still get a place to run the handler.
        let altSize = 64 * 1024
        var altStack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: altSize, alignment: 16),
                               ss_size: altSize, ss_flags: 0)
        sigaltstack(&altStack, nil)

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_ONSTACK
            sigaction(sig, &action, nil)
        }
    }

    /// Being stopped by `kill` / `pkill` (what an installer does) is a normal way to end.
    private static func listenForTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
        source.setEventHandler {
            IndraLog.cleanExit()
            exit(0)
        }
        source.resume()
        termSource = source
    }

    // MARK: Freeze watchdog

    /// A helper thread asks the main thread to answer; if it does not within a few seconds, the freeze is saved.
    /// v547: (1) a stall that is really the Mac having slept (the wall clock jumped, the monotonic one did not) is not a freeze;
    /// (2) while the main thread is stuck, the system's `sample` tool writes down what it is doing, and the busiest lines of the main
    /// thread go into the saved problem, so a freeze from another Mac says WHERE Indra waited, not only that it did.
    private static func startWatchdog() {
        Thread.detachNewThread {
            Thread.current.name = "Indra watchdog"
            Thread.sleep(forTimeInterval: 10)   // launching can be slow; not a freeze
            while true {
                let napStart = Date()
                Thread.sleep(forTimeInterval: 2)
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                let askedAt = Date()
                if answered.wait(timeout: .now() + 6) == .timedOut {
                    let wall = Date().timeIntervalSince(askedAt)
                    let slept = wall > 12 || Date().timeIntervalSince(napStart) > 14
                    if slept {
                        answered.wait()
                        continue
                    }
                    var detail = "The window or notch did not respond for more than 6 seconds."
                    if answered.wait(timeout: .now() + 0.2) == .timedOut, let stack = sampleMainThread() {
                        detail += "\n\nWhat the main thread was doing:\n" + stack
                    }
                    IndraLog.record("Freeze", "Indra stopped responding", detail: detail)
                    answered.wait()   // until it recovers, so one freeze is one entry
                }
            }
        }
    }

    /// The busiest call stack of the main thread, from `/usr/bin/sample` (1 second, at most 8 s of waiting); nil when unavailable.
    private static func sampleMainThread() -> String? {
        let tool = "/usr/bin/sample"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("indra-freeze-sample.txt")
        try? FileManager.default.removeItem(at: out)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "1", "10", "-file", out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { process.terminate() }
        defer { try? FileManager.default.removeItem(at: out) }
        guard let text = try? String(contentsOf: out, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else { return nil }
        var kept: [String] = []
        for line in lines[start...] {
            if kept.count > 0, line.contains("Thread_") || line.hasPrefix("Total number in stack") { break }
            kept.append(String(line.prefix(150)))
            if kept.count >= 28 { break }
        }
        return kept.joined(separator: "\n")
    }
}

// MARK: - Signal handler (kept free of anything that allocates)

private var crashFD: Int32 = -1
private var crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
private var crashClock = UnsafeMutablePointer<CChar>.allocate(capacity: 40)

private func crashWrite(_ text: StaticString) {
    _ = write(crashFD, text.utf8Start, text.utf8CodeUnitCount)
}

private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        switch sig {
        case SIGSEGV: crashWrite("CRASH SIGSEGV (invalid memory access)")
        case SIGBUS: crashWrite("CRASH SIGBUS (bad memory access)")
        case SIGILL: crashWrite("CRASH SIGILL (illegal instruction)")
        case SIGFPE: crashWrite("CRASH SIGFPE (arithmetic error)")
        case SIGTRAP: crashWrite("CRASH SIGTRAP (Swift runtime trap: nil unwrapped, index out of range, fatalError or similar)")
        default: crashWrite("CRASH SIGABRT (aborted)")
        }
        crashWrite(" t=")
        var value = Int(time(nil))
        var digits = 0
        var probe = value
        repeat { digits += 1; probe /= 10 } while probe > 0
        var index = digits - 1
        repeat {
            crashClock[index] = CChar(48 + value % 10)
            value /= 10
            index -= 1
        } while value > 0 && index >= 0
        crashClock[digits] = 10
        _ = write(crashFD, crashClock, digits + 1)
        crashWrite("STACK\n")
        let count = backtrace(crashFrames, 64)
        backtrace_symbols_fd(crashFrames, count, crashFD)
    }
    // Hand over to the system, so the normal crash report is still made.
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - macOS diagnostic reports

/// macOS itself sends crash, hang and CPU reports on a later launch; they go in the log too.
private final class MetricsListener: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var parts: [String] = []
            if let list = payload.crashDiagnostics, !list.isEmpty { parts.append("\(list.count) crash") }
            if let list = payload.hangDiagnostics, !list.isEmpty { parts.append("\(list.count) hang") }
            if let list = payload.cpuExceptionDiagnostics, !list.isEmpty { parts.append("\(list.count) high CPU") }
            if let list = payload.diskWriteExceptionDiagnostics, !list.isEmpty { parts.append("\(list.count) heavy disk writes") }
            guard !parts.isEmpty else { continue }
            let json = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? ""
            IndraLog.record("System report", "macOS report: " + parts.joined(separator: ", "),
                            detail: String(json.prefix(7000)))
        }
    }
}
