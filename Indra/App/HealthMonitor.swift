import AppKit
import ApplicationServices
import Foundation

/// What the "Fix" button of a detected problem does.
enum HealthFix: Equatable {
    case accessibility
    case automation
    /// Forgets Indra's refusals and asks again (a refusal is otherwise remembered for ever, and a rebuilt app
    /// can inherit an old one).
    case reauthorizeAutomation
    /// v486: "Allow JavaScript from Apple Events" of a browser (Safari or a Chromium browser): opens that browser.
    case browserJavaScript(bundle: String)

    var buttonTitle: String {
        switch self {
        case .accessibility: return "Open Accessibility"
        case .automation: return "Open Automation"
        case .reauthorizeAutomation: return "Allow again"
        case .browserJavaScript: return "How to fix"
        }
    }

    func perform() {
        switch self {
        case .accessibility:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .automation:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .reauthorizeAutomation:
            HealthFix.resetAndAskAgain()
        case .browserJavaScript(let bundle):
            // Safari: Settings ▸ Advanced ▸ "Show features for web developers", then Develop ▸ Allow JavaScript from
            // Apple Events. Chromium browsers: View ▸ Developer ▸ Allow JavaScript from Apple Events.
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.open(app)
            }
        }
    }

    /// Asks macOS for permission to control `bundle` (this is what puts Indra into Privacy & Security ▸ Automation), then
    /// opens that page. An app that is not running is opened first (hidden): macOS can only ask about a running app. A
    /// refusal that is already stored is cleared first, because a stored refusal never asks again.
    static func askThenOpenAutomation(bundle: String) {
        let own = Bundle.main.bundleIdentifier ?? "com.indra.Indra"
        Task.detached {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if HealthMonitor.automationDenied(bundle: bundle) {
                let tool = Process()
                tool.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                tool.arguments = ["reset", "AppleEvents", own]
                tool.standardOutput = FileHandle.nullDevice
                tool.standardError = FileHandle.nullDevice
                if (try? tool.run()) != nil { tool.waitUntilExit() }
                try? await Task.sleep(nanoseconds: 1_200_000_000)   // v426: let the permission database settle
            }
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            // Blocks until the person answers the system prompt.
            _ = HealthMonitor.requestAutomation(bundle: bundle)
            await MainActor.run {
                HealthMonitor.shared.checkNow()
                if let page = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(page)
                }
            }
        }
    }

    /// Clears what macOS remembers about Indra's Automation answers, then asks for every running music app, Safari and the
    /// browser that played last (v486: any browser, not only Safari). If the reset cannot run (the Standard build is
    /// sandboxed) the Automation page is opened instead.
    private static func resetAndAskAgain() {
        let own = Bundle.main.bundleIdentifier ?? "com.indra.Indra"
        var targets = ["com.apple.Music", "com.spotify.client", YouTubeBrowsers.safari.id]
        if let last = YouTubeBrowsers.last, !targets.contains(last.id) { targets.append(last.id) }
        Task.detached {
            var reset = false
            IndraLog.crumb("Automation: clearing the refusal (tccutil) and asking again")
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tool.arguments = ["reset", "AppleEvents", own]
            tool.standardOutput = FileHandle.nullDevice
            tool.standardError = FileHandle.nullDevice
            if (try? tool.run()) != nil {
                tool.waitUntilExit()
                reset = tool.terminationStatus == 0
            }
            // v426: the permission database needs a moment to settle after a reset (asking at once could get the old
            // refusal back and no prompt), and the prompt of an app without a Dock icon appears reliably only while the
            // app is the active one.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            var stillDenied = !reset
            for bundle in targets where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
                // Blocks until the person answers the system prompt.
                if HealthMonitor.requestAutomation(bundle: bundle) != 0 { stillDenied = true }
            }
            IndraLog.crumb("Automation: asked again, \(stillDenied ? "still refused" : "allowed")")
            await MainActor.run {
                HealthMonitor.shared.checkNow()
                if stillDenied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// One thing that is not working right now.
struct HealthIssue: Identifiable, Equatable {
    /// Stable key, so the same problem is never listed twice.
    let id: String
    var title: String
    var detail: String
    var fix: HealthFix?
    var since: Date
}

/// Finds problems by itself. Two ways:
///  - parts of Indra report a failure the moment it happens (a song that could not be started, Safari refusing
///    control ...) with `report`, and clear it with `resolve` as soon as the same thing works again;
///  - a self-check runs every half minute (and from the "Check now" button) over the registered checks
///    plus the built-in ones (permissions, the Now Playing helper).
/// Every new problem is also saved to the problem log, so it ends up in the report that can be copied or emailed.
@MainActor
final class HealthMonitor: ObservableObject {
    static let shared = HealthMonitor()

    @Published private(set) var issues: [HealthIssue] = []
    @Published private(set) var lastCheck: Date?

    private struct Check {
        let id: String
        let run: () -> (title: String, detail: String, fix: HealthFix?)?
    }

    private var checks: [Check] = []
    private var timer: Timer?
    private var started = false

    private init() {}

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        HealthMonitor.askAutomationIfNeeded()
        HealthMonitor.healAutomationOncePerBuild()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.checkNow()
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Adds a check. It returns nil when everything is fine, or the problem it found.
    func register(id: String, _ run: @escaping () -> (title: String, detail: String, fix: HealthFix?)?) {
        checks.removeAll { $0.id == id }
        checks.append(Check(id: id, run: run))
    }

    // MARK: Reporting

    func report(id: String, title: String, detail: String = "", fix: HealthFix? = nil) {
        if let index = issues.firstIndex(where: { $0.id == id }) {
            if issues[index].detail != detail || issues[index].title != title {
                issues[index].title = title
                issues[index].detail = detail
                issues[index].fix = fix
            }
            return
        }
        issues.append(HealthIssue(id: id, title: title, detail: detail, fix: fix, since: Date()))
        IndraLog.record("Detected", title, detail: detail)
        IndraLog.crumb("Problem detected: \(title)")
    }

    func resolve(id: String) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        let gone = issues.remove(at: index)
        IndraLog.crumb("Problem gone: \(gone.title)")
    }

    // MARK: Self-check

    /// Runs every check now.
    func checkNow() {
        runChecks()
        refreshAutomation()
    }

    private var refreshingAutomation = false

    /// v448: macOS's answer about controlling Spotify / Music is read OFF the main thread (the call talks to the permission
    /// service and can take a second or more). It used to run on the main thread every 30 seconds, and while it waited the
    /// volume / brightness key tap (which also runs on the main thread) was switched off by macOS ("Key tap was switched
    /// off", in the problem report, every 15-25 s). The checks only read the last answer; when a new one arrives they run again.
    private func refreshAutomation() {
        guard !refreshingAutomation else { return }
        refreshingAutomation = true
        Task.detached(priority: .utility) { [weak self] in
            for bundle in HealthMonitor.musicBundles {
                HealthMonitor.automationCache.set(bundle, HealthMonitor.currentAutomationStatus(bundle: bundle))
            }
            await MainActor.run {
                guard let self else { return }
                self.refreshingAutomation = false
                self.runChecks()
            }
        }
    }

    private func runChecks() {
        for check in builtIn() + checks {
            if let found = check.run() {
                report(id: check.id, title: found.title, detail: found.detail, fix: found.fix)
            } else {
                resolve(id: check.id)
            }
        }
        lastCheck = Date()
    }

    private func builtIn() -> [Check] {
        var list: [Check] = []

        // The volume / brightness keys can only be replaced with Accessibility access (full-access build).
        list.append(Check(id: "accessibility") {
            let wantsKeys = Preferences.sensoryVolume || Preferences.sensoryBrightness || Preferences.sensoryKeyboard
            guard wantsKeys, !SensoryDiagnostics.isSandboxed, !AXIsProcessTrusted() else { return nil }
            return (title: "Accessibility access is off",
                    detail: "The volume and brightness pop-ups cannot replace the macOS ones until Indra is allowed under Privacy & Security ▸ Accessibility.",
                    fix: .accessibility)
        })

        // The helper that tells Indra what is playing in Safari, Chrome and every other app.
        list.append(Check(id: "now-playing") {
            if case .unavailable(let reason) = SystemNowPlaying.shared.status {
                return (title: "Now Playing is not available",
                        detail: "Music from browsers and other apps will not be detected. \(reason)",
                        fix: nil)
            }
            return nil
        })

        // Control of the music apps (only apps that are running, and only when the person said no).
        for (id, name, bundle) in [("automation-music", "Apple Music", "com.apple.Music"),
                                   ("automation-spotify", "Spotify", "com.spotify.client")] {
            // Safari is not checked here: it only matters while a YouTube song plays in it, and Indra reports a
            // refusal itself at that moment ("safari-automation"). Checking it all the time nagged people who
            // never use that.
            list.append(Check(id: id) {
                guard HealthMonitor.automationCache.status(of: bundle) == OSStatus(-1743) else { return nil }
                HealthMonitor.healAutomationOncePerBuild()
                let what = "The side album bar and picking songs from it need"
                return (title: "Indra is not allowed to control \(name)",
                        detail: "\(what) Privacy & Security ▸ Automation ▸ Indra ▸ \(name). Play, pause and skip keep working through macOS Now Playing. The Allow again button resets the refusal and asks again. "
                            + "(macOS answer \(HealthMonitor.automationCache.status(of: bundle) ?? 0); \(SigningDiagnostics.summary))",
                        fix: .reauthorizeAutomation)
            })
        }
        return list
    }

    nonisolated static let musicBundles = ["com.apple.Music", "com.spotify.client"]

    /// The last answer macOS gave for each music app (nil = not running / not asked yet). Written off the main thread.
    final class AutomationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: OSStatus] = [:]

        func set(_ bundle: String, _ status: OSStatus?) {
            lock.lock()
            answers[bundle] = status
            lock.unlock()
        }

        func status(of bundle: String) -> OSStatus? {
            lock.lock()
            defer { lock.unlock() }
            return answers[bundle]
        }
    }

    nonisolated static let automationCache = AutomationCache()

    /// The answer for a running app, without asking the person anything (nil when the app is not running). Never on main.
    nonisolated static func currentAutomationStatus(bundle: String) -> OSStatus? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return nil }
        return automationStatus(bundle: bundle)
    }

    /// Asks macOS for permission to control the app, showing the system prompt if it has not been answered yet.
    /// 0 = allowed, -1743 = refused, -1744 = would need the prompt. Blocks while the prompt is up: never on main.
    nonisolated static func requestAutomation(bundle: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let pointer = target.aeDesc else { return OSStatus(-1) }
        let status = AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, true)
        if status == 0 { return 0 }
        // v421: the permission call alone did not produce the prompt (or was refused). Sending a real Apple event is the
        // other way macOS is asked, and the one that always makes Indra appear in Privacy & Security > Automation.
        var scriptCode = 0
        // v491: the permission prompt can stay on screen for a long time, so this one waits for the lock only briefly and
        // is not wrapped in a timeout (a timeout would cut the prompt short).
        if AppleScriptGate.acquire() {
            if let script = NSAppleScript(source: "tell application id \"\(bundle)\" to return name") {
                var error: NSDictionary?
                _ = script.executeAndReturnError(&error)
                scriptCode = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            }
            AppleScriptGate.lock.unlock()
        }
        Trace.log("PERMISSION \(bundle): permission call \(status), real Apple event \(scriptCode)")
        return scriptCode == 0 ? 0 : status
    }

    /// What macOS currently answers for this app, without asking the person anything.
    nonisolated static func automationStatus(bundle: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let pointer = target.aeDesc else { return OSStatus(-1) }
        return AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, false)
    }

    /// Runs the prompt for any running music app that has never been asked (so the first launch is not silent).
    static func askAutomationIfNeeded() {
        Task.detached {
            for bundle in ["com.apple.Music", "com.spotify.client"]
            where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
                guard let pointer = target.aeDesc,
                      AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, false) == OSStatus(-1744)
                else { continue }
                _ = HealthMonitor.requestAutomation(bundle: bundle)
            }
        }
    }

    /// v418/v420: macOS sees every rebuilt Indra as a different program, so a refusal left behind by an earlier build (or one
    /// the person never gave) used to stand until "Allow again" was pressed by hand, build after build. When a running
    /// music app turns out to be refused, the refusal is cleared and the question asked again by itself: at most three
    /// times per build and at least ten minutes apart (a person who says no on purpose is not nagged). v420: it used to
    /// try once per build only, so a music app opened after that one try stayed refused.
    nonisolated static func healAutomationOncePerBuild() {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        let countKey = "automationHealCount-\(build)"
        let atKey = "automationHealAt"
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: countKey) < 3,
              Date().timeIntervalSince1970 - defaults.double(forKey: atKey) > 600 else { return }
        Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let refused = ["com.apple.Music", "com.spotify.client"].contains { HealthMonitor.automationDenied(bundle: $0) }
            guard refused,
                  defaults.integer(forKey: countKey) < 3,
                  Date().timeIntervalSince1970 - defaults.double(forKey: atKey) > 600 else { return }
            defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
            defaults.set(Date().timeIntervalSince1970, forKey: atKey)
            Trace.log("PERMISSION a music app was refused: cleared and asked again (build \(build))")
            HealthFix.reauthorizeAutomation.perform()
        }
    }

    /// True only when the person has explicitly refused (never when the question has simply not been asked yet).
    nonisolated static func automationDenied(bundle: String) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let pointer = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, false)
        return status == OSStatus(-1743)
    }
}
