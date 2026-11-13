import AppKit

/// Direct access to the trackpad's haptic motor, for the two things `NSHapticFeedbackManager` cannot do: its three
/// patterns have a fixed, fairly gentle strength, and they only play while the app is the active one (never for the
/// notch or the lock screen, which are panels). The system's own multitouch framework can fire the motor with a
/// chosen actuation, including the strongest ones, whatever is on screen.
///
/// This is a private framework, so everything is looked up at run time and any miss simply turns it off;
/// `Haptics` then falls back to the normal system pulse. Needs the unsandboxed (full access) build.
///
/// v366: THE ROOT CAUSE of "haptics do not work when hovering the notch". The project was being built with the App
/// Sandbox on (`Indra-Standard.entitlements`). Inside the sandbox macOS refuses the multitouch framework its
/// connection to the trackpad, so `MTActuatorOpen` never succeeds and no amount of re-opening, priming or settling
/// (v361, v364) can help. Every tap then fell back to `NSHapticFeedbackManager`, which only plays while Indra is
/// the active app: it worked in the settings window (and the Haptic Lab), and was silent on the notch, which is a
/// non-activating panel. Clicks only "felt" right because the trackpad's own click is physical. The default build is
/// now the full-access one (`project.yml`), and the problem report says so when the motor is blocked.
///
/// v364: hover haptics. `prime()` used to rebuild the handle whenever `MTActuatorIsOpen` said "closed", and that
/// call is wrong on some systems, so every notch hover swapped in a fresh handle right before its tap (see
/// `isHealthy`). Health now comes only from real failures, and a fresh handle gets 60 ms to settle.
///
/// WHY HAPTICS USED TO WORK "SOMETIMES", AND WEAKLY (v361 rewrite)
///
/// Earlier versions tried to be safe by never trusting a handle that had sat unused for a second or two: the next
/// tap first threw the handle away and opened a new one, and fired on it a few microseconds later. A notch hover
/// is, by its nature, the first tap after a rest, so EVERY hover tap ran on a handle that had been opened a moment
/// before. A freshly opened motor handle is the least reliable one: its first actuation is the one that is
/// dropped or comes out weak, which is exactly "fails on hover, uneven strength, fine when tapping quickly". The
/// renewal also ran on the main thread, so it sat in the middle of the notch's opening layout and competed with it.
/// Marking the handle stale whenever the app was activated or a Space changed made it happen even more often.
///
/// Now:
///
///  * ONE long-lived handle. It is opened at launch and left open; it is only renewed when there is a real reason:
///    the system slept / woke / locked / unlocked, `MTActuatorIsOpen` says it closed, or the motor answered a tap
///    with an error. Never on a timer, never because the app became active, never on a Space change;
///  * all motor calls run on their own serial queue (user-interactive priority), never on the main thread, so a
///    busy layout can neither delay a tap nor be delayed by one;
///  * after a wake or unlock the renewal waits until macOS has brought the trackpad back (0.7 s, then 3 s), and
///    is done when nobody is touching the pad, not in the middle of the next tap;
///  * a failed search for the motor is repeated with a short, growing delay (0.15 s up to 2 s), and a background
///    check every 15 s notices a handle that closed by itself, so the next tap does not have to discover it;
///  * `prime()` (called when the pointer comes near the notch) makes sure the handle is open before the tap.
final class TrackpadActuator: @unchecked Sendable {
    static let shared = TrackpadActuator()

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetDeviceID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> UnsafeRawPointer?
    private typealias OpenActuator = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias CloseActuator = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias IsOpenActuator = @convention(c) (UnsafeRawPointer) -> Bool
    private typealias Actuate = @convention(c) (UnsafeRawPointer, Int32, UInt32, Float, Float) -> Int32

    private struct Symbols {
        let createList: CreateList
        let getID: GetDeviceID
        let create: CreateActuator
        let open: OpenActuator
        let close: CloseActuator?
        let isOpen: IsOpenActuator?
        let actuate: Actuate
    }

    /// Every motor call and all of the state below belong to this queue.
    private let queue = DispatchQueue(label: "com.indra.haptics.motor", qos: .userInteractive)

    private var symbols: Symbols?
    private var symbolsLoaded = false
    private var actuators: [UnsafeRawPointer] = []
    /// Set by a sleep, wake, lock, unlock or a tap that only some handles answered: renew before the next tap.
    private var needsRebuild = false
    private var nextAttempt = Date.distantPast
    private var failureStreak = 0
    private var lastCount = -1
    /// v501: set by a sleep / wake / lock / unlock. The old handles then belong to a device that may have been detached
    /// and re-attached; calling `MTActuatorClose` on such a handle talks to a device that is no longer there.
    private var handlesMayBeStale = false
    /// When the current handles were opened: a handle needs a moment before its first tap is reliable.
    private var openedAt = Date.distantPast
    private var lastFailureNote = Date.distantPast
    private var keepAlive: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    /// v543: consecutive refusals of each open handle (parallel to `actuators`). A handle that keeps refusing is dropped on its
    /// own; the old code renewed EVERY handle (close + open of the multitouch device) whenever one of them refused a tap.
    private var failures: [Int] = []
    /// v543: when the handles were last renewed, newest last. The driver is shared with the keyboard and the cursor, and
    /// opening / closing it over and over is what the MacBook froze on (see the note at the top of `rebuild`).
    private var rebuildTimes: [Date] = []
    /// v543: set when the motor must not be touched again in this run (too many renewals, or the person switched it off).
    private var disabledForRun = false
    private var lastActuation = Date.distantPast
    /// Taps waiting on the motor's queue (shared with the callers' threads, behind `lock`).
    private var pendingFires = 0
    /// v544: while this is in the future the private driver is not touched at all (no tap, no renewal, no check). Behind `lock`.
    private var quietUntil = Date.distantPast

    // Shared with other threads (the problem report, the haptics page), so behind a lock.
    private let lock = NSLock()
    private var readyFlag = false
    private var disabledForRunFlag = false
    private var firedCount = 0
    private var failedCount = 0
    private var rebuildCount = 0
    private var lastActuateCode: Int32 = 0

    private init() {
        // The system notification centres are the main thread's business: register there.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { installObservers() }
        }
    }

    @MainActor
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.systemRested()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.systemWoke()
            })
        }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: nil) { [weak self] _ in
            self?.systemRested()
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                            object: nil, queue: nil) { [weak self] _ in
            self?.systemWoke()
        })
    }

    // MARK: - Public

    /// v544: THE QUIET WINDOW. A file drag, a drop and a send to Blip / AirDrop are the moments the whole Mac was seen to
    /// freeze (cursor, keyboard, display). In that time the private multitouch driver is left completely alone: every tap
    /// becomes the system's own pattern (a public API), and nothing is opened, closed or checked. It only ever grows.
    func stayQuiet(for seconds: TimeInterval, why: String) {
        let until = Date().addingTimeInterval(seconds)
        let extended = locked { () -> Bool in
            guard until > quietUntil else { return false }
            quietUntil = until
            return true
        }
        if extended { FreezeTrail.mark("haptic motor quiet for \(Int(seconds)) s (\(why))") }
    }

    /// True while the quiet window is open.
    var isQuiet: Bool { locked { Date() < quietUntil } }

    /// Opens the motor ahead of the first tap and starts the background check.
    func warmUp() {
        queue.async { [self] in
            if let s = loadSymbols() { ensureReady(s) }
            startKeepAlive()
        }
    }

    /// Makes sure the motor is open and healthy. Call it when a tap is likely to come (the pointer is near the
    /// notch): the tap itself then never has to open anything.
    func prime() {
        queue.async { [self] in
            guard let s = loadSymbols() else { return }
            ensureReady(s)
        }
    }

    /// True once a trackpad motor has been opened.
    var isAvailable: Bool {
        let ready = locked { readyFlag }
        if !ready { prime() }
        return ready
    }

    /// True when the App Sandbox is on (the Standard build). Inside it macOS refuses the multitouch framework's
    /// connection to the trackpad, so the motor can never be opened and every tap falls back to the system pattern,
    /// which stays silent for the notch and the lock screen (Indra is not the active app there).
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// One line for the problem report.
    var statusLine: String {
        locked {
            if !readyFlag, TrackpadActuator.isSandboxed {
                return "motor blocked by the App Sandbox (Standard build): hover / notch haptics cannot work, build the full-access version"
            }
            let state = !Preferences.strongHaptics ? "full-strength haptics OFF (switched off by the person, or by an abrupt end of the last run)"
                : (disabledForRunFlag ? "motor stopped for this run by the freeze guard" : (readyFlag ? "motor ready" : "motor not found"))
            let master = Preferences.hapticsEnabled ? "on" : "OFF by the person"
            let lock = Preferences.lockHapticsEnabled ? "on" : "OFF by the person"
            return "notch switch \(master), lock screen switch \(lock), \(state), taps \(firedCount) ok / \(failedCount) failed, last motor answer \(lastActuateCode), reopened \(rebuildCount)x"
        }
    }

    /// Fires one actuation on every open trackpad motor, off the main thread. `completion` (on the main thread) says
    /// whether anything was fired, so the caller can fall back to the system pattern.
    func fire(_ actuationID: Int32, completion: (@MainActor (Bool) -> Void)? = nil) {
        // v428: the switches (notch / main window, lock screen) are checked by `Haptics` and `HapticLab` before they
        // get here, so the motor itself no longer looks at either.
        // v543: taps that pile up behind a slow motor are dropped instead of being played one after another later.
        // v544: inside the quiet window the motor is not used; the caller falls back to the system pattern at once.
        if isQuiet {
            if let completion { DispatchQueue.main.async { MainActor.assumeIsolated { completion(false) } } }
            return
        }
        let waiting = locked { () -> Int in pendingFires += 1; return pendingFires }
        if waiting > 4 {
            locked { pendingFires -= 1 }
            if let completion { DispatchQueue.main.async { MainActor.assumeIsolated { completion(true) } } }
            return
        }
        queue.async { [self] in
            defer { locked { pendingFires -= 1 } }
            let ok = fireNow(actuationID)
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
            }
        }
    }

    // MARK: - System events

    private func systemRested() {
        queue.async { [self] in
            needsRebuild = true
            handlesMayBeStale = true
        }
    }

    private func systemWoke() {
        queue.async { [self] in
            needsRebuild = true
            handlesMayBeStale = true
        }
        // macOS needs a moment to bring the trackpad (and the keyboard, on a laptop: they share one driver) back after a
        // wake or unlock. v501: the renewal used to start 0.7 s after the wake, right in the middle of that, and again at
        // 3 s. Opening and closing the multitouch device while the driver is still re-attaching can leave it wedged
        // (trackpad gestures and keys dead until a hard restart). Now the first try waits until things have settled, and
        // nothing is opened while the screen is still locked.
        queue.asyncAfter(deadline: .now() + 2.5) { [self] in
            guard !LockMonitor.isScreenActuallyLocked(), let s = loadSymbols() else { return }
            ensureReady(s)
        }
        queue.asyncAfter(deadline: .now() + 6.0) { [self] in
            guard !LockMonitor.isScreenActuallyLocked(), let s = loadSymbols() else { return }
            ensureReady(s)
        }
    }

    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let s = self.loadSymbols() else { return }
            self.ensureReady(s)
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: - Queue-only: opening

    private func loadSymbols() -> Symbols? {
        // v543: nothing of the private driver is touched while the switch is off (it switches itself off after an abrupt exit)
        // or after the motor was stopped for this run.
        guard Preferences.strongHaptics, !disabledForRun else { return nil }
        if symbolsLoaded { return symbols }
        symbolsLoaded = true
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let listSym = dlsym(lib, "MTDeviceCreateList"),
              let idSym = dlsym(lib, "MTDeviceGetDeviceID"),
              let createSym = dlsym(lib, "MTActuatorCreateFromDeviceID"),
              let openSym = dlsym(lib, "MTActuatorOpen"),
              let actuateSym = dlsym(lib, "MTActuatorActuate") else {
            IndraLog.crumb("Haptics: trackpad motor framework not available")
            return nil
        }
        var close: CloseActuator?
        if let closeSym = dlsym(lib, "MTActuatorClose") { close = unsafeBitCast(closeSym, to: CloseActuator.self) }
        var isOpen: IsOpenActuator?
        if let isOpenSym = dlsym(lib, "MTActuatorIsOpen") { isOpen = unsafeBitCast(isOpenSym, to: IsOpenActuator.self) }
        symbols = Symbols(createList: unsafeBitCast(listSym, to: CreateList.self),
                          getID: unsafeBitCast(idSym, to: GetDeviceID.self),
                          create: unsafeBitCast(createSym, to: CreateActuator.self),
                          open: unsafeBitCast(openSym, to: OpenActuator.self),
                          close: close,
                          isOpen: isOpen,
                          actuate: unsafeBitCast(actuateSym, to: Actuate.self))
        return symbols
    }

    /// Opens a fresh handle on every trackpad that is connected.
    private func openDevices(_ s: Symbols) -> [UnsafeRawPointer] {
        guard let list = s.createList()?.takeRetainedValue() else { return [] }
        var opened: [UnsafeRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            var deviceID: UInt64 = 0
            guard s.getID(device, &deviceID) == 0, deviceID != 0,
                  let actuator = s.create(deviceID) else { continue }
            if s.open(actuator) == 0 { opened.append(actuator) }
        }
        return opened
    }

    /// The handles are closed but never released: they are few, renewals are rare now, and releasing an object the
    /// framework may still hold is the one thing here that could crash.
    private func closeAll(_ handles: [UnsafeRawPointer], _ s: Symbols) {
        guard let close = s.close else { return }
        for handle in handles { _ = close(handle) }
    }

    /// False when there is no handle or one was flagged (sleep / wake / lock / a refused tap).
    ///
    /// v364: `MTActuatorIsOpen` is deliberately NOT consulted any more. On some macOS versions it answers "closed"
    /// for a handle that works perfectly. `prime()` (called the moment the pointer reaches the notch) trusted it,
    /// threw the good handle away and opened a brand-new one a fraction of a second before the hover tap, and a
    /// brand-new handle drops its first actuation: hovering the notch gave no haptic, while clicks (which never
    /// call `prime()`) felt fine. A handle that really has died is still noticed: the motor refuses the tap and
    /// `fireNow` renews it and taps again.
    private func isHealthy(_ s: Symbols) -> Bool {
        !actuators.isEmpty && !needsRebuild
    }

    /// Renews the handles when they are not healthy. Returns whether a usable motor is open afterwards.
    @discardableResult
    private func ensureReady(_ s: Symbols) -> Bool {
        if isHealthy(s) { return true }
        if disabledForRun { return false }
        // v544: never open or renew anything inside the quiet window.
        if isQuiet { return !actuators.isEmpty }
        // v543: never renew more than once every 15 s (and wait out the retry delay after a failed search), whatever asked.
        if Date() < nextAttempt { return !actuators.isEmpty }
        rebuild(s)
        return !actuators.isEmpty
    }

    /// Closes the old handles first (a dead one is no use, and some Macs allow only one handle at a time), then
    /// opens fresh ones.
    private func rebuild(_ s: Symbols) {
        // v543: THE FREEZE GUARD. Every renewal closes and opens the trackpad's multitouch device. That driver is shared with the
        // keyboard and the cursor on a MacBook, and the whole machine froze (cursor, keyboard, display; hard shutdown) while
        // Indra renewed the handles again and again: any tap where one handle answered and another refused (a second
        // multitouch device without a motor, such as a Magic Mouse) marked ALL handles for renewal, so a file dragged over the
        // drop buttons (several taps a second) closed and re-opened the device on every one of them. Now: one renewal at most
        // every 15 s, at most 6 in 10 minutes, then the motor is left alone for the rest of the run.
        let now = Date()
        rebuildTimes = rebuildTimes.filter { now.timeIntervalSince($0) < 600 }
        if rebuildTimes.count >= 6 {
            stopMotorForThisRun("the handles were renewed \(rebuildTimes.count) times in 10 minutes")
            return
        }
        rebuildTimes.append(now)
        FreezeTrail.mark("haptic motor: renewing the handles (renewal \(rebuildTimes.count))")
        nextAttempt = now.addingTimeInterval(15)
        needsRebuild = false
        let old = actuators
        actuators = []
        failures = []
        // v501: after a sleep / wake / lock the old handles are dropped without being closed (a few small objects are
        // kept alive on purpose, see `closeAll`) instead of closing handles of a device the driver has just re-created.
        if !handlesMayBeStale { closeAll(old, s) }
        handlesMayBeStale = false
        actuators = openDevices(s)
        FreezeTrail.mark("haptic motor: \(actuators.count) handle(s) open")
        failures = Array(repeating: 0, count: actuators.count)
        openedAt = Date()
        if actuators.isEmpty {
            failureStreak += 1
            let delay = min(0.15 * pow(2.0, Double(min(failureStreak, 5) - 1)), 2.0)
            nextAttempt = Date().addingTimeInterval(max(delay, 15))
        } else {
            failureStreak = 0
        }
        let count = actuators.count
        locked {
            readyFlag = count > 0
            if !old.isEmpty { rebuildCount += 1 }
        }
        if count != lastCount {
            lastCount = count
            if count == 0, TrackpadActuator.isSandboxed {
                IndraLog.crumb("Haptics: motor blocked by the App Sandbox (Standard build); notch haptics are silent")
            } else {
                IndraLog.crumb(count == 0 ? "Haptics: no trackpad motor found" : "Haptics: trackpad motor ready (\(count))")
            }
        }
    }

    // MARK: - Queue-only: firing

    private func fireNow(_ actuationID: Int32) -> Bool {
        guard let s = loadSymbols() else { return false }
        guard ensureReady(s) else { noteFailure("no motor"); return false }
        // v543: no "open afresh and try again" any more: a refused tap is a failed tap (the system pattern stands in). A handle
        // that keeps refusing is dropped inside `send`; renewing is left to the 15 s rule in `ensureReady`.
        if send(actuationID, s) { noteSuccess(); return true }
        noteFailure("motor refused the tap")
        return false
    }

    /// v543: leaves the private driver alone for the rest of this run.
    private func stopMotorForThisRun(_ why: String) {
        disabledForRun = true
        actuators = []
        failures = []
        locked { readyFlag = false; disabledForRunFlag = true }
        IndraLog.crumb("Haptics: trackpad motor stopped for this run (\(why)); the system pattern is used")
        Trace.log("SAFETY: trackpad motor stopped for this run: \(why)")
    }

    private func send(_ actuationID: Int32, _ s: Symbols) -> Bool {
        // A handle opened a moment ago drops or weakens its first tap: let it settle (this is the motor's own
        // queue, so the main thread never waits).
        let settle = 0.06 - Date().timeIntervalSince(openedAt)
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        // v543: never closer than 50 ms to the previous tap, whatever asked.
        if Date().timeIntervalSince(lastActuation) < 0.05 { return true }
        lastActuation = Date()
        var fired = false
        for index in actuators.indices {
            let code = s.actuate(actuators[index], actuationID, 0, 0, 0)
            locked { lastActuateCode = code }
            if code == 0 {
                fired = true
                failures[index] = 0
            } else {
                failures[index] += 1
            }
        }
        // v543: a handle that refuses three taps in a row (a device without a motor) is dropped for good, without touching the
        // others and without renewing anything. The handle is not closed: closing is what the driver did not like.
        if failures.contains(where: { $0 >= 3 }) {
            var keptActuators: [UnsafeRawPointer] = []
            var keptFailures: [Int] = []
            for index in actuators.indices where failures[index] < 3 {
                keptActuators.append(actuators[index])
                keptFailures.append(failures[index])
            }
            actuators = keptActuators
            failures = keptFailures
        }
        return fired
    }

    private func noteSuccess() {
        locked { firedCount += 1 }
    }

    private func noteFailure(_ why: String) {
        locked { failedCount += 1 }
        let now = Date()
        if now.timeIntervalSince(lastFailureNote) > 30 {
            lastFailureNote = now
            IndraLog.crumb("Haptics: tap failed (\(why))")
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
