import AppKit

@MainActor
final class AppLockController {
    static let shared = AppLockController()

    /// UserDefaults key holding the bundle IDs of locked apps.
    static let lockedKey = "lockedAppBundleIDs"

    /// Set by FaceUnlockCoordinator when it is created.
    weak var faceScanner: FaceUnlockCoordinator?

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var overlays: [pid_t: AppLockOverlay] = [:]
    /// v541: each unlock, tied to the process it was given to (not to the pid alone, see `UnlockSession`).
    private var unlocked: [pid_t: UnlockSession] = [:]
    /// v541: an unlocked app in front that showed nothing on the screen at the last check (closed windows): the time of that
    /// check. A second look a moment later decides (see `recheckClosedWindows`).
    private var closedCandidates: [pid_t: Date] = [:]
    /// v562: the unlocked apps whose windows were SEEN on the screen while they were in front, since they last came to the front.
    /// Only for those can "no window on screen" mean that the person closed it (see watchWindows).
    private var visibleWhileFront: Set<pid_t> = []
    /// v541: after an app is locked again because its windows were closed, a fast watch covers it the moment a window shows up
    /// again (the once-a-second watcher left the reopened app uncovered for up to a second).
    private var quickCoverTasks: [pid_t: Task<Void, Never>] = [:]
    /// When each unlocked app last lost focus.
    private var leftFocusAt: [pid_t: Date] = [:]
    private var started = false
    /// v503: how many checks in a row found an unlocked app with no windows left (it was closed, only the process lives on).
    private var noWindowTicks: [pid_t: Int] = [:]
    private var windowWatchTimer: Timer?
    /// v544: every process of a locked app that the once-a-second look has already seen (pid -> its start time). A process that is
    /// running but not in here is a NEW launch, whatever the launch / activation notifications did or did not say.
    private var seenLockedProcesses: [pid_t: Date?] = [:]
    /// v506: reads the space bar while a cover waits for a face-scan request ("Scan only on notch hover or button").
    private let coverSpaceMonitor = SpaceKeyMonitor()
    /// "Quit Face Lock" from the menu bar: no app is covered until Face Lock is started again.
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            for overlay in overlays.values { overlay.dismiss() }
            overlays.removeAll()
            unlocked.removeAll()
            leftFocusAt.removeAll()
            noWindowTicks.removeAll()
            closedCandidates.removeAll()
            visibleWhileFront.removeAll()
            for task in quickCoverTasks.values { task.cancel() }
            quickCoverTasks.removeAll()
            RingLight.shared.hide()
        } else {
            lockAllNow()
        }
    }
    private var expiryTimer: Timer?

    /// True while an app-lock face scan owns the camera and the notch.
    var isFaceScanActive: Bool { overlays.values.contains { $0.isScanning } }
    /// True only while some locked app's blur cover is on screen and scanning. The edge light depends on this.
    var isCoverScanning: Bool { overlays.values.contains { $0.isCoverScanning } }
    /// v543: the screen of the blur cover that is on screen AND scanning right now (nil when there is none). The edge light is
    /// drawn on this screen and nowhere else.
    var scanningCoverScreen: NSScreen? {
        overlays.values.first { $0.isCoverScanning && $0.isCoverShown }?.coverScreen
    }
    /// v477: true while any locked app's blur cover is on screen (scanning or not).
    var isCoverShown: Bool { overlays.values.contains { $0.isCoverShown } }
    /// v477: the same, for one screen only (nil asks about any screen).
    func isCoverShown(on screen: NSScreen?) -> Bool {
        overlays.values.contains { overlay in
            guard overlay.isCoverShown else { return false }
            guard let screen, let covered = overlay.coverScreen else { return true }
            return covered == screen
        }
    }

    private var lockedBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.lockedKey) ?? [])
    }
    private var relockMinutes: Int {
        UserDefaults.standard.integer(forKey: "appLockRelockMinutes")
    }
    private var idleMinutes: Int {
        UserDefaults.standard.integer(forKey: "appLockIdleMinutes")
    }
    private var relockOnLock: Bool {
        (UserDefaults.standard.object(forKey: "appLockRelockOnLock") as? Bool) ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        RingLightGuard.start()
        // Building the recolor table takes a moment; do it now (in the background) so the first notch animation is not delayed.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            ScanAnimationHostView.prewarmStill()
        }
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let regular = app.activationPolicy == .regular
            MainActor.assumeIsolated { self?.handleActivation(pid: pid, bundleID: bundleID, regular: regular) }
        }

        // v541: a freshly launched app can never inherit an unlock: whatever is still filed under its pid (a missed quit
        // notification, a reused pid) is dropped the moment the launch is announced.
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let launch = app.launchDate
            let bundleID = app.bundleIdentifier
            MainActor.assumeIsolated { self?.appLaunched(pid: pid, launch: launch, bundleID: bundleID) }
        }

        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.forget(pid: pid) }
        }

        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLockedOrSleeping() }
        }
        // v503: display sleep, fast user switching and the screen saver also end a session. Before, only the lock screen and
        // system sleep did, so a locked app stayed open after the display went to sleep.
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLockedOrSleeping() }
        }
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLockedOrSleeping() }
        }
        // v503: hiding an unlocked app (Cmd+H) counts as closing it: coming back asks again.
        center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                if self?.unlocked[pid] != nil { Trace.log("APPLOCK: pid \(pid) was hidden (Cmd+H): locked again") }
                self?.relockClosedApp(pid: pid)
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLockedOrSleeping() }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLockedOrSleeping() }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Give the desktop a moment to come back before looking at what is in front.
                try? await Task.sleep(for: .milliseconds(600))
                self?.checkFrontmost()
            }
        }

        expiryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.relockExpired() }
        }
        // v503: an unlocked app whose windows were all closed (the process keeps running) is closed as far as the user is
        // concerned. Opening it again must ask again. Before, the unlock stayed valid for as long as the process lived.
        coverSpaceMonitor.onSpaceKeyDown = { [weak self] in self?.spacePressedOnCover() }
        NotificationCenter.default.addObserver(forName: .indraAppLockCoverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCoverSpaceMonitor() }
        }
        let watch = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchWindows() }
        }
        RunLoop.main.add(watch, forMode: .common)
        windowWatchTimer = watch

        // v503: when Indra starts or the Mac wakes with a locked app already in front, cover it. Before, it stayed open until
        // the user switched away and back.
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                self?.checkFrontmost()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.checkFrontmost()
        }
    }

    // MARK: - Closed apps

    private func relockClosedApp(pid: pid_t) {
        guard unlocked[pid] != nil else { return }
        dropSession(pid: pid)
    }

    /// v541: forgets only the unlock of `pid` (the cover, if any, is not touched).
    private func dropSession(pid: pid_t) {
        unlocked[pid] = nil
        leftFocusAt[pid] = nil
        noWindowTicks[pid] = nil
        closedCandidates[pid] = nil
        visibleWhileFront.remove(pid)
    }

    /// v541: true only while `pid` is still the SAME process that was unlocked. An unlock that belongs to a process that has quit
    /// (or to an older process that had this pid) is removed here, so a locked app that was quit and opened again is always asked
    /// again, whatever happened to the quit notification.
    private func isUnlocked(pid: pid_t) -> Bool {
        guard let session = unlocked[pid] else { return false }
        let app = NSRunningApplication(processIdentifier: pid)
        if AppLockSessionRules.isSameProcess(storedLaunch: session.launch, currentLaunch: app?.launchDate, isTerminated: app?.isTerminated ?? true) {
            return true
        }
        Trace.log("APPLOCK: the unlock of pid \(pid) is dropped: that process is gone (the app was quit, or the pid was reused)")
        dropSession(pid: pid)
        return false
    }

    private func appLaunched(pid: pid_t, launch: Date?, bundleID: String?) {
        if unlocked[pid] != nil {
            Trace.log("APPLOCK: pid \(pid) was launched again: the old unlock under that pid is dropped")
            dropSession(pid: pid)
        }
        if let existing = overlays[pid], !AppLockSessionRules.isSameProcess(storedLaunch: existing.launchDate, currentLaunch: launch, isTerminated: false) {
            existing.dismiss()
            overlays[pid] = nil
        }
        // v542: a locked app that was just opened is covered as soon as it is in front, whatever the activation notification
        // said or did not say (see `armLaunchCover`).
        if let bundleID, lockedBundleIDs.contains(bundleID) {
            Trace.log("APPLOCK: locked app launched (pid \(pid)): watching until it is in front")
            armLaunchCover(pid: pid, bundleID: bundleID)
        }
    }

    /// v542: after a locked app is launched, looks every 0.1 s (at most 20 s) and covers it the moment it is the app in front. The
    /// activation notification alone was the only way a freshly opened locked app got its cover (plus a once-a-second fallback that
    /// needed a window on screen): an app whose activation was announced while it still reported itself as a background process, or
    /// whose notification did not name it, was shown without asking.
    private func armLaunchCover(pid: pid_t, bundleID: String) {
        quickCoverTasks[pid]?.cancel()
        quickCoverTasks[pid] = Task { @MainActor [weak self] in
            for _ in 0..<200 {
                guard let self, !Task.isCancelled, !self.isPaused,
                      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { break }
                if self.overlays[pid] != nil || self.isUnlocked(pid: pid) { break }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    Trace.log("APPLOCK: the launched locked app (pid \(pid)) is in front: covering it")
                    self.lockIfNeeded(pid: pid, bundleID: bundleID)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.quickCoverTasks[pid] = nil
        }
    }

    /// v504: the windows of each wanted app, from ONE look at the window list (the whole list once per check, never once per app).
    /// v541: counted twice: `total` (on screen or not: minimized, closed-but-kept, other-Space windows) and `onScreen`. The v503/v504
    /// rule only looked at the total, and a window that is closed (not minimized) is very often NOT gone from the list: many apps
    /// keep it, off screen, for as long as they live. So an app whose window was closed with the red button kept its unlock
    /// forever, and reopening it from the Dock showed it without asking. Windows above the menu bar's level (status items,
    /// pop-overs) never count, but floating windows do. Nil when the list cannot be read (the caller then does nothing).
    private static func windowCounts(for pids: Set<pid_t>) -> [pid_t: AppLockWindowCounts]? {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let screenSizes = NSScreen.screens.map { $0.frame.size }
        var counts: [pid_t: AppLockWindowCounts] = [:]
        for pid in pids { counts[pid] = AppLockWindowCounts() }
        for window in list {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int,
                  var entry = counts[pid_t(owner)],
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= 0, layer < 24,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 120, rect.height > 80 else { continue }
            entry.total += 1
            if (window[kCGWindowIsOnscreen as String] as? Bool) == true { entry.onScreen += 1 }
            if screenSizes.contains(where: { rect.width >= $0.width - 2 && rect.height >= $0.height - 80 }) {
                entry.hasFullScreenWindow = true
            }
            counts[pid_t(owner)] = entry
        }
        return counts
    }

    /// v506: the space bar reader runs exactly while some cover waits for a face-scan request (and the Mac is not locked: the
    /// lock screen has its own reader in FaceUnlockCoordinator).
    private func syncCoverSpaceMonitor() {
        let wanted = !isPaused && !LockMonitor.isScreenLockedCached() && overlays.values.contains { $0.wantsSpaceBar }
        if wanted { coverSpaceMonitor.start() } else { coverSpaceMonitor.stop() }
    }

    /// v520: a space press that arrived while the lock screen's unlock animation was still playing.
    private var pendingSpaceScan = false
    private var pendingSpaceTask: Task<Void, Never>?

    /// v520: space presses during the unlock animation (success, then the collapse) are only recorded: nothing on the cover
    /// or the notch is touched while it plays (a press used to cut into it and the background vanished). Once the animation
    /// has completely finished, one scan starts, however many times space was pressed in the meantime.
    private func startPendingSpaceTask() {
        guard pendingSpaceTask == nil else { return }
        pendingSpaceTask = Task { @MainActor [weak self] in
            for _ in 0..<160 {   // up to 8 s
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                let phase = NotchOverlayController.shared.phase
                if phase == .success || phase == .collapsing { continue }
                try? await Task.sleep(for: .milliseconds(150))   // let the notch settle fully
                guard !Task.isCancelled else { return }
                self.pendingSpaceTask = nil
                if self.pendingSpaceScan {
                    self.pendingSpaceScan = false
                    Trace.log("APPLOCK: the unlock animation is done: starting the face scan the space bar asked for")
                    self.spacePressedOnCover()
                }
                return
            }
            self?.pendingSpaceTask = nil
            self?.pendingSpaceScan = false
        }
    }

    private func spacePressedOnCover() {
        guard !isPaused, !LockMonitor.isScreenLockedCached() else { return }
        let animating = NotchOverlayController.shared.phase
        if animating == .success || animating == .collapsing {
            guard overlays.values.contains(where: { $0.wantsSpaceBar }) else { return }
            Trace.log("APPLOCK: space pressed during the unlock animation: recorded, the scan starts after it")
            pendingSpaceScan = true
            startPendingSpaceTask()
            return
        }
        // The cover in front (the one that is active and waiting) takes the key.
        for overlay in overlays.values where overlay.wantsSpaceBar {
            overlay.spaceBarPressed()
            break
        }
        syncCoverSpaceMonitor()
    }

    private func watchWindows() {
        syncCoverSpaceMonitor()
        guard !isPaused else { return }
        detectNewLockedLaunches()
        relockBackgroundedApps()
        // v541: an unlock whose process is gone is dropped here at the latest (one second), whatever the quit notification did.
        for pid in Array(unlocked.keys) { _ = isUnlocked(pid: pid) }
        // A locked app in front with no cover (for example reopened from the Dock while it was already in front).
        var uncovered: NSRunningApplication?
        var uncoveredID: String?
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, lockedBundleIDs.contains(id),
           overlays[front.processIdentifier] == nil, !isUnlocked(pid: front.processIdentifier),
           !LockMonitor.isScreenLockedCached() {
            uncovered = front
            uncoveredID = id
        }
        let now = Date()
        // Only apps unlocked more than 3 seconds ago are looked at (a window that was just opened may still be settling).
        var wanted = Set(unlocked.filter { now.timeIntervalSince($0.value.at) > 3 }.keys)
        for pid in unlocked.keys where !wanted.contains(pid) { noWindowTicks[pid] = nil; closedCandidates[pid] = nil }
        if let uncovered { wanted.insert(uncovered.processIdentifier) }
        guard !wanted.isEmpty, let counts = Self.windowCounts(for: wanted) else { return }

        // v541: while the Mac is locked or the display sleeps the window list says nothing about what the user did.
        let screenQuiet = LockMonitor.isScreenLockedCached() || CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for pid in wanted where unlocked[pid] != nil {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                forget(pid: pid); continue
            }
            let c = counts[pid] ?? AppLockWindowCounts(total: 1, onScreen: 1, hasFullScreenWindow: false)
            // v562: a window that is seen on the screen while the app is in front is what makes a later "nothing on the screen" mean
            // "closed". An app that was out of focus does not keep that: coming back to it (another Space, a minimized or
            // un-hidden window, a window still sliding in) is not a close and must not ask again before the time set in Settings.
            if pid == frontPID {
                if c.onScreen > 0 { visibleWhileFront.insert(pid) }
            } else {
                visibleWhileFront.remove(pid)
            }
            if AppLockSessionRules.windowsAllGone(c) {
                let n = (noWindowTicks[pid] ?? 0) + 1
                noWindowTicks[pid] = n
                if n >= 2 {
                    Trace.log("APPLOCK: pid \(pid) has no window left: locked again")
                    relockClosedApp(pid: pid)
                    continue
                }
            } else {
                noWindowTicks[pid] = nil
            }
            // v541: windows closed but kept by the app (nothing on the screen while it is in front). A second look 0.35 s
            // later decides, so a window that is only moving between Spaces or animating never locks the app.
            if !screenQuiet, visibleWhileFront.contains(pid),
               AppLockSessionRules.windowsClosedWhileInFront(c, isFront: pid == frontPID, isHidden: app.isHidden) {
                if closedCandidates[pid] == nil {
                    closedCandidates[pid] = now
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        self?.recheckClosedWindows(pid: pid)
                    }
                }
            } else {
                closedCandidates[pid] = nil
            }
        }
        if let uncovered, let uncoveredID, (counts[uncovered.processIdentifier]?.onScreen ?? 0) > 0 {
            lockIfNeeded(pid: uncovered.processIdentifier, bundleID: uncoveredID)
        }
    }

    /// v544: THE REOPEN FIX, independent of every notification. Once a second, every RUNNING process of a locked app is compared
    /// with the ones seen before. A process that is new (a locked app that was quit and opened again, or one that started in the
    /// background) loses anything that could still count as an unlock, loses any cover left from an older process, and is covered
    /// the moment it is the app in front. The earlier fixes (v541, v542) all hung on the launch / terminate / activation
    /// notifications reaching this class in the right order; this does not: it only needs the list of running apps.
    private func detectNewLockedLaunches() {
        let locked = lockedBundleIDs
        guard !locked.isEmpty else { seenLockedProcesses.removeAll(); return }
        var alive: Set<pid_t> = []
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, locked.contains(id), !app.isTerminated else { continue }
            let pid = app.processIdentifier
            alive.insert(pid)
            let launch = app.launchDate
            if let known = seenLockedProcesses[pid] {
                // Same pid: still the same process unless its start time changed (a reused pid).
                if AppLockSessionRules.isSameProcess(storedLaunch: known, currentLaunch: launch, isTerminated: false) { continue }
            }
            seenLockedProcesses[pid] = .some(launch)
            Trace.log("APPLOCK: new process of the locked app \(id) (pid \(pid)): no unlock can carry over to it")
            // An unlock that was given to THIS process a moment ago (a very quick face match) stays; any other one is dropped.
            if let session = unlocked[pid], !AppLockSessionRules.isSameProcess(storedLaunch: session.launch, currentLaunch: launch, isTerminated: false) {
                dropSession(pid: pid)
            }
            if let existing = overlays[pid], !AppLockSessionRules.isSameProcess(storedLaunch: existing.launchDate, currentLaunch: launch, isTerminated: false) {
                existing.dismiss()
                overlays[pid] = nil
            }
            if LockMonitor.isScreenLockedCached() { continue }   // the lock screen's own check covers it when the Mac is unlocked
            if frontPID == pid, overlays[pid] == nil {
                Trace.log("APPLOCK: the new process (pid \(pid)) is in front: covering it")
                lockIfNeeded(pid: pid, bundleID: id)
            } else if overlays[pid] == nil {
                armLaunchCover(pid: pid, bundleID: id)
            }
        }
        // Processes that are gone are forgotten, so a pid that comes back later counts as new.
        for pid in Array(seenLockedProcesses.keys) where !alive.contains(pid) {
            seenLockedProcesses[pid] = nil
            if unlocked[pid] != nil || overlays[pid] != nil {
                Trace.log("APPLOCK: locked process pid \(pid) is gone: its unlock and cover are removed")
                forget(pid: pid)
            }
        }
    }

    /// v545: some apps (WhatsApp) never really quit: Cmd+Q or the red button turns them into a background process that keeps the same
    /// pid, shows no Dock dot and no windows. No quit notification is sent, so the unlock stayed and the app opened later without
    /// asking (the v544 log showed the same pid for minutes). An unlocked app that is no longer a normal (regular) app is closed as far
    /// as the person is concerned: its unlock is dropped, and the next time it comes back it is covered.
    private func relockBackgroundedApps() {
        for pid in Array(unlocked.keys) {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { continue }
            if app.activationPolicy != .regular {
                Trace.log("APPLOCK: pid \(pid) is no longer a regular app (policy \(app.activationPolicy.rawValue)): it was quit to the background, locked again")
                dropSession(pid: pid)
                armLaunchCover(pid: pid, bundleID: app.bundleIdentifier ?? "")
            }
        }
    }

    /// v541: the second look at an unlocked app that showed no window while in front. Still nothing on the screen: its windows were
    /// closed, so it is locked again and, if it is still in front, covered the moment a window comes back.
    private func recheckClosedWindows(pid: pid_t) {
        guard closedCandidates[pid] != nil else { return }
        closedCandidates[pid] = nil
        guard !isPaused, unlocked[pid] != nil, !LockMonitor.isScreenLockedCached(), CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let counts = Self.windowCounts(for: [pid]), let c = counts[pid] else { return }
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard visibleWhileFront.contains(pid),
              AppLockSessionRules.windowsClosedWhileInFront(c, isFront: isFront, isHidden: app.isHidden) else { return }
        Trace.log("APPLOCK: pid \(pid) is in front with every window closed: locked again, it asks when it is opened")
        let bundleID = app.bundleIdentifier
        relockClosedApp(pid: pid)
        armQuickCover(pid: pid, bundleID: bundleID)
    }

    /// v541: watches a locked-again app in front every 0.15 s (for at most 30 s) and covers it as soon as a window appears.
    private func armQuickCover(pid: pid_t, bundleID: String?) {
        guard quickCoverTasks[pid] == nil else { return }
        quickCoverTasks[pid] = Task { @MainActor [weak self] in
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, !self.isPaused,
                      self.unlocked[pid] == nil, self.overlays[pid] == nil,
                      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { break }
                if let counts = Self.windowCounts(for: [pid]), (counts[pid]?.onScreen ?? 0) > 0 {
                    self.lockIfNeeded(pid: pid, bundleID: bundleID)
                    break
                }
            }
            self?.quickCoverTasks[pid] = nil
        }
    }

    // MARK: - App switching

    private func handleActivation(pid: pid_t, bundleID: String?, regular: Bool = true) {
        // Indra's own panel taking focus is not a switch.
        guard pid != ownPID, !isPaused else { return }
        // Spotlight, the Dock and other background helpers taking focus are not a switch either. v542: but an app the user
        // LOCKED is never skipped because of its policy: a just-launched app can still report itself as a background process
        // when its activation is announced, and was then shown without asking.
        guard regular || (bundleID.map { lockedBundleIDs.contains($0) } ?? false) else { return }

        // Remember when each unlocked app lost focus, and relock this one if it was away too long.
        let now = Date()
        for unlockedPID in unlocked.keys where unlockedPID != pid && leftFocusAt[unlockedPID] == nil {
            leftFocusAt[unlockedPID] = now
        }
        if let left = leftFocusAt[pid] {
            leftFocusAt[pid] = nil
            let minutes = idleMinutes
            if minutes > 0, isUnlocked(pid: pid), now.timeIntervalSince(left) >= TimeInterval(minutes * 60) {
                Trace.log("APPLOCK: pid \(pid) was out of focus for \(Int(now.timeIntervalSince(left))) s (limit \(minutes) min): locked again")
                unlocked[pid] = nil
            }
        }

        // Moving to any other app means leaving every locked app that is still covered.
        for (otherPID, overlay) in overlays where otherPID != pid {
            overlay.targetDeactivatedWhenSettled()
        }
        lockIfNeeded(pid: pid, bundleID: bundleID)
        // v542: safety net. If this app is locked and in front half a second later and still has neither a cover nor an unlock,
        // cover it now (whatever made the first attempt skip it).
        if let bundleID, lockedBundleIDs.contains(bundleID) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.isPaused,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.overlays[pid] == nil, !self.isUnlocked(pid: pid) else { return }
                Trace.log("APPLOCK: safety net covered pid \(pid), which the activation had skipped")
                self.lockIfNeeded(pid: pid, bundleID: bundleID)
            }
        }
    }

    private func lockIfNeeded(pid: pid_t, bundleID: String?) {
        guard pid != ownPID, !isPaused,
              let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              lockedBundleIDs.contains(bundleID) else { return }

        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if let existing = overlays[pid] {
            // v541: a cover that belongs to an older process with this pid is never reused for the new one.
            if AppLockSessionRules.isSameProcess(storedLaunch: existing.launchDate, currentLaunch: app.launchDate, isTerminated: false) {
                existing.targetActivated()
                return
            }
            Trace.log("APPLOCK: the cover under pid \(pid) belonged to another process: replaced")
            existing.dismiss()
            overlays[pid] = nil
        }
        guard !isUnlocked(pid: pid) else {
            Trace.log("APPLOCK: \(bundleID) (pid \(pid)) is not covered: it holds an unlock from \(unlocked[pid].map { Int(Date().timeIntervalSince($0.at)) } ?? -1) s ago")
            return
        }

        let launch = app.launchDate
        Trace.log("APPLOCK: covering \(bundleID) (pid \(pid)): no valid unlock for this process")
        let overlay = AppLockOverlay(app: app, faceScanner: faceScanner) { [weak self] in
            guard let self else { return }
            // v541: an unlock that arrives after the app has already quit (a late face result) is not recorded.
            let current = NSRunningApplication(processIdentifier: pid)
            if AppLockSessionRules.isSameProcess(storedLaunch: launch, currentLaunch: current?.launchDate, isTerminated: current?.isTerminated ?? true) {
                self.unlocked[pid] = UnlockSession(at: Date(), launch: launch)
            }
            self.leftFocusAt[pid] = nil
            self.overlays[pid] = nil
        }
        overlays[pid] = overlay
        overlay.targetActivated()
    }

    private func forget(pid: pid_t) {
        overlays[pid]?.dismiss()
        overlays[pid] = nil
        dropSession(pid: pid)
        quickCoverTasks[pid]?.cancel()
        quickCoverTasks[pid] = nil
    }

    // MARK: - Screen lock and relocking

    private func screenLockedOrSleeping() {
        RingLight.shared.hide()
        for overlay in overlays.values { overlay.screenLocked() }
        if relockOnLock {
            if !unlocked.isEmpty { Trace.log("APPLOCK: the Mac was locked or went to sleep: every unlock is removed (Relock on lock or sleep)") }
            unlocked.removeAll(); leftFocusAt.removeAll(); noWindowTicks.removeAll(); closedCandidates.removeAll(); visibleWhileFront.removeAll()
        }
    }

    private func relockExpired() {
        let minutes = relockMinutes
        guard minutes > 0, !unlocked.isEmpty else { return }
        let limit = TimeInterval(minutes * 60)
        let expired = unlocked.filter { Date().timeIntervalSince($0.value.at) > limit }.map(\.key)
        guard !expired.isEmpty else { return }
        for pid in expired { unlocked[pid] = nil }
        checkFrontmost()
    }

    /// Treats every locked app as locked again; the one in front is covered right away.
    func lockAllNow() {
        unlocked.removeAll()
        noWindowTicks.removeAll()
        closedCandidates.removeAll()
        visibleWhileFront.removeAll()
        checkFrontmost()
    }

    /// Locks the app in front right now if it's locked and not currently unlocked.
    private func checkFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        lockIfNeeded(pid: front.processIdentifier, bundleID: front.bundleIdentifier)
    }
}
