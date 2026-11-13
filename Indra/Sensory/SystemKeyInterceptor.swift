import AppKit
import ApplicationServices

/// The volume / brightness / keyboard backlight keys on the keyboard.
enum SystemKey: Int {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case keyboardUp = 21
    case keyboardDown = 22
    case mute = 7
}

/// Catches the volume / brightness keys before macOS shows its own pop-up, so Indra's overlay
/// can replace it. Needs the Accessibility permission and does not work inside the App Sandbox.
///
/// v501 (system-wide input freeze fix): the tap used to be served by the MAIN thread, and its callback ran the whole key
/// action (CoreAudio, DisplayServices and CoreBrightness calls, all synchronous round trips to other system daemons)
/// before answering. While the callback has not answered, the window server holds the keyboard event queue. Whenever the
/// main thread was busy or waiting on a daemon (wake, lock, display dimming, camera start) the whole input system stalled:
/// cursor still moving, nothing else answering. Now:
///  * the tap lives on its OWN thread and run loop, so a busy main thread can never hold it up;
///  * the callback only decides "swallow or not" from plain flags (no system calls, no locks held by the main thread)
///    and hands the actual work to the main thread asynchronously;
///  * the tap is switched off completely while the display sleeps / the Mac sleeps, when it has nothing to do and the
///    window server is busiest (v526: it stays on while the screen is only locked, so the lock screen shows Indra's overlay
///    alone).
final class SystemKeyInterceptor: @unchecked Sendable {
    /// Called on the MAIN thread, after the event has already been answered. The Bool result is ignored (the swallow
    /// decision is `shouldSwallow`, which must be answerable without touching the main thread).
    @MainActor var onKey: ((SystemKey, NSEvent.ModifierFlags) -> Bool)?
    /// Read from the tap thread. Set by the owner from the main thread whenever the preferences change.
    var shouldSwallow: @Sendable (SystemKey) -> Bool = { _ in false }

    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeys = Set<Int>()
    private var thread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var wantsRunning = false
    private var suspendedBySystem = false
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    /// v528: true between the lock and the unlock notification. Read on the tap thread (under `stateLock`) only to pick how long the
    /// tap may wait for the main thread to decode a key, and to label the trace lines.
    private var screenLockedFlag = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS "allow Accessibility" prompt.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return tap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        stateLock.lock()
        wantsRunning = true
        let already = tap != nil || thread != nil
        let suspended = suspendedBySystem
        stateLock.unlock()
        installSystemObservers()
        if already || suspended { return true }   // while suspended, `resume()` brings it back
        // v526: no longer held back while the screen is locked (see `installSystemObservers`).
        return spawnTapThread()
    }

    func stop() {
        stateLock.lock()
        wantsRunning = false
        stateLock.unlock()
        removeSystemObservers()
        tearDownTapThread()
    }

    // MARK: - Lock / sleep awareness

    private func installSystemObservers() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let off: () -> Void = { [weak self] in self?.suspend() }
        let on: () -> Void = { [weak self] in self?.resume() }
        // v526: a locked screen no longer switches the tap off. The lock screen used to show macOS's own volume / brightness
        // pop-up next to Indra's overlay, because the keys were not caught there. The tap's callback has not touched the main
        // thread's work since v501 (it only decides swallow or not, and a busy main thread lets the key through after 40 ms), so
        // keeping it on while locked cannot stall the keyboard any more. Display sleep and Mac sleep still switch it off.
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setScreenLocked(false)
            on()
        })
        // v528: the screen locking checks that the tap is really there and really on. macOS's own volume / brightness pop-up showed on
        // the lock screen next to Indra's whenever the tap was missing or switched off at that moment (see `ensureTapAlive`).
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setScreenLocked(true)
            self?.ensureTapAlive(reason: "screen locked")
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in off() })
        }
        // A session change that is only the screen locking (some systems post it then) must not switch the tap off either.
        // v528: this notification also arrives while the screen is only locking, and the lock flag is not always set yet at that moment,
        // so the tap used to be switched off exactly when the lock screen came up. Now it is only switched off when, a second later, the
        // session really is no longer the one on the screen (fast user switching) and is not locked.
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if LockMonitorSnapshot.isOffConsole && !LockMonitorSnapshot.isLockedOrAsleep { off() }
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A wake that finds the screen locked (lid opened, display woken) keeps the lock flag; `resume()` brings the tap back.
                if name == NSWorkspace.sessionDidBecomeActiveNotification, !LockMonitorSnapshot.isLockedOrAsleep { self?.setScreenLocked(false) }
                on()
            })
        }
    }

    private func removeSystemObservers() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            distributed.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func suspend() {
        stateLock.lock(); suspendedBySystem = true; stateLock.unlock()
        tearDownTapThread()
    }

    private func resume() {
        stateLock.lock()
        suspendedBySystem = false
        let go = wantsRunning && tap == nil && thread == nil
        stateLock.unlock()
        guard go else { return }
        // Not right at the moment of the wake / unlock: the window server is busiest then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let ok = self.wantsRunning && !self.suspendedBySystem && self.tap == nil && self.thread == nil
            self.stateLock.unlock()
            guard ok else { return }   // v526: also while the screen is locked
            _ = self.spawnTapThread()
        }
    }

    private func setScreenLocked(_ value: Bool) {
        stateLock.lock(); screenLockedFlag = value; stateLock.unlock()
    }

    private var isScreenLockedFlag: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return screenLockedFlag
    }

    /// v528: makes sure the tap exists and is switched on; builds it again when it is gone or macOS switched it off. Runs when the
    /// screen locks. Does nothing while the tap is deliberately off (display or Mac asleep) or not wanted.
    private func ensureTapAlive(reason: String) {
        stateLock.lock()
        let wanted = wantsRunning && !suspendedBySystem
        let port = tap
        stateLock.unlock()
        guard wanted else { return }
        if let port, CGEvent.tapIsEnabled(tap: port) {
            Trace.log("LOCKHUD: key tap checked (\(reason)): running")
            return
        }
        Trace.log("LOCKHUD: key tap checked (\(reason)): \(port == nil ? "missing" : "switched off"), building it again")
        tearDownTapThread()
        let ok = spawnTapThread()
        Trace.log("LOCKHUD: key tap rebuilt: \(ok ? "ok" : "failed (Accessibility?)")")
    }

    private final class CreatedFlag: @unchecked Sendable { var value = false }

    // MARK: - Tap thread

    private func spawnTapThread() -> Bool {
        stateLock.lock()
        generation += 1
        let gen = generation
        stateLock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let created = CreatedFlag()
        let worker = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<SystemKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handleOnTapThread(type: type, event: event)
            }
            // NX_SYSDEFINED (14): media keys arrive as system-defined events.
            let mask: CGEventMask = 1 << 14
            guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, runLoopSource, .commonModes)
            self.stateLock.lock()
            let stale = self.generation != gen
            if !stale {
                self.tap = port
                self.source = runLoopSource
                self.tapRunLoop = loop
            }
            self.stateLock.unlock()
            if stale {
                CFMachPortInvalidate(port)
                ready.signal()
                return
            }
            CGEvent.tapEnable(tap: port, enable: true)
            created.value = true
            ready.signal()
            // A watchdog on this same thread: a tap macOS switched off (and did not tell us about) is switched back on.
            let watch = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.stateLock.lock(); let port = self.tap; self.stateLock.unlock()
                if let port, !CGEvent.tapIsEnabled(tap: port) {
                    CGEvent.tapEnable(tap: port, enable: true)
                    self.stateLock.lock(); self.swallowedKeys.removeAll(); self.stateLock.unlock()
                }
            }
            RunLoop.current.add(watch, forMode: .common)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
            watch.invalidate()
        }
        worker.name = "com.indra.keytap"
        worker.qualityOfService = .userInteractive
        stateLock.lock(); thread = worker; stateLock.unlock()
        worker.start()
        // Waits (briefly) so `start()` can report success; the tap thread never waits for the main thread, so this cannot deadlock.
        _ = ready.wait(timeout: .now() + 1.0)
        if !created.value {
            stateLock.lock(); if thread === worker { thread = nil }; stateLock.unlock()
        }
        return created.value
    }

    private func tearDownTapThread() {
        stateLock.lock()
        generation += 1
        let port = tap, src = source, loop = tapRunLoop, worker = thread
        tap = nil; source = nil; tapRunLoop = nil; thread = nil
        swallowedKeys.removeAll()
        stateLock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let src, let loop { CFRunLoopRemoveSource(loop, src, .commonModes) }
        worker?.cancel()
        if let loop { CFRunLoopStop(loop) }
    }

    // MARK: - The callback (tap thread). Must stay tiny and must never wait for anything.

    private struct DecodedSystemEvent { let subtype: Int16; let data1: Int; let flags: NSEvent.ModifierFlags }

    private final class DecodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DecodedSystemEvent?
        func set(_ v: DecodedSystemEvent?) { lock.lock(); value = v; lock.unlock() }
        func get() -> DecodedSystemEvent? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Reads subtype / data / modifier flags of a system-defined event on the main thread (see the note in the callback).
    private func decodeOnMain(_ event: CGEvent, timeout: Double) -> DecodedSystemEvent? {
        let box = DecodeBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            if let ns = NSEvent(cgEvent: event) {
                box.set(DecodedSystemEvent(subtype: ns.subtype.rawValue, data1: ns.data1, flags: ns.modifierFlags))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }

    private func handleOnTapThread(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock(); let port = tap; swallowedKeys.removeAll(); stateLock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14 else { return Unmanaged.passUnretained(event) }

        // v516: NSEvent(cgEvent:) must NOT be called on this thread. For Caps Lock and other system events it calls into
        // HIToolbox, which asserts it is on the main queue and crashed Indra (SIGTRAP in dispatch_assert_queue, build 515).
        // The event is decoded on the main thread instead; this thread waits at most 40 ms for the answer and lets the key
        // through untouched if the main thread is busy, so a busy main thread still can never hold the keyboard up for long.
        // v528: on the lock screen the main thread is busy with the lock window (blur, video, vinyl), and a 40 ms answer was often too
        // late: the key then went through untouched and macOS showed its own pop-up next to Indra's. While locked the tap waits longer
        // (150 ms at most, and only for system keys, which are rare).
        let locked = isScreenLockedFlag
        guard let decoded = decodeOnMain(event, timeout: locked ? 0.15 : 0.04) else {
            if locked {
                Trace.log("LOCKHUD: key tap: the main thread did not decode a system key in time on the lock screen, the key went through to macOS")
                // v564: the key may be a volume / brightness key that macOS now answers with its own pop-up next to Indra's. The
                // fallback that keeps that pop-up away lived on the main thread, the very thread that was too busy to answer a moment
                // ago, so it came too late (or not at all). This one runs on background queues only.
                if Preferences.sensoryVolume || Preferences.sensoryBrightness || Preferences.sensoryKeyboard {
                    SystemHUDSuppressor.suppressWithoutMainThread()
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard decoded.subtype == 8 else { return Unmanaged.passUnretained(event) }
        let data = decoded.data1
        let keyCode = (data & 0xFFFF0000) >> 16
        let keyFlags = data & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
        let flags = decoded.flags
        guard let key = SystemKey(rawValue: keyCode) else { return Unmanaged.passUnretained(event) }

        if isDown {
            let swallow = shouldSwallow(key)
            if locked { Trace.log("LOCKHUD: key tap saw \(key) on the lock screen: \(swallow ? "caught, Indra's overlay only" : "not caught (its overlay is off), macOS handles it")") }
            guard swallow else { return Unmanaged.passUnretained(event) }
            stateLock.lock(); swallowedKeys.insert(keyCode); stateLock.unlock()
            // The real work happens later, on the main thread, after this event has been answered.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { _ = self?.onKey?(key, flags) }
            }
            return nil
        }
        // Swallow the matching key-up too, so macOS never sees half a key press.
        stateLock.lock(); let had = swallowedKeys.remove(keyCode) != nil; stateLock.unlock()
        return had ? nil : Unmanaged.passUnretained(event)
    }
}

/// Whether the screen is locked right now (a cheap session lookup), for code that must not wait on the main thread.
enum LockMonitorSnapshot {
    /// v528: true when this login session is no longer the one on the screen (another user's session is in front).
    static var isOffConsole: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return !((dict["kCGSSessionOnConsoleKey"] as? Bool) ?? true)
    }

    static var isLockedOrAsleep: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}


/// v528: the last line of defence for the lock screen. When a volume / brightness key reaches macOS untouched there (the key tap
/// was not there, or answered too late), macOS draws its own pop-up through its OSDUIHelper process, next to Indra's overlay.
/// Indra cannot take the key back at that point, so for a moment it keeps that one helper process from drawing: it is ended
/// every 25 ms for about a second (macOS starts it again by itself on the next key, and the desktop is never touched: this only
/// runs when a key was pressed on the lock screen and Indra's own overlay for that key is switched on).
enum SystemHUDSuppressor {
    @MainActor private static var running = false
    @MainActor private static var until = Date.distantPast
    private static let helperBundleID = "com.apple.OSDUIHelper"

    private static let backgroundLock = NSLock()
    private static var backgroundUntil = Date.distantPast

    /// v564: the same as `suppress`, for callers that must not touch the main thread (the key tap's thread). Only the system's
    /// `killall`, started from background queues at a few moments over the next second; macOS starts the helper again by itself
    /// on the next key. Safe to call from any thread, as often as needed.
    static func suppressWithoutMainThread(for seconds: Double = 0.9) {
        guard !SensoryDiagnostics.isSandboxed else { return }
        backgroundLock.lock()
        let alreadyRunning = Date() < backgroundUntil
        backgroundUntil = max(backgroundUntil, Date().addingTimeInterval(seconds))
        backgroundLock.unlock()
        guard !alreadyRunning else { return }
        Trace.log("LOCKHUD: macOS pop-up suppressed from the key tap's own thread for \(seconds) s")
        for delay in [0.0, 0.1, 0.25, 0.45, 0.7] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["OSDUIHelper"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
        }
    }

    @MainActor
    static func suppress(for seconds: Double = 1.0, why: String) {
        guard !SensoryDiagnostics.isSandboxed else { return }
        until = max(until, Date().addingTimeInterval(seconds))
        Trace.log("LOCKHUD: macOS pop-up suppressed for \(seconds) s (\(why))")
        guard !running else { return }
        running = true
        // The helper may not be listed as an app: a plain killall covers that, twice (at once and a little later, in case macOS
        // was still starting it). Nothing waits for it.
        for delay in [0.0, 0.35] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["OSDUIHelper"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
        }
        Task { @MainActor in
            var ended = 0
            while Date() < until {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleID) {
                    if app.forceTerminate() { ended += 1 }
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            running = false
            Trace.log("LOCKHUD: macOS pop-up suppression finished (helper ended \(ended) time(s) as an app)")
        }
    }
}
