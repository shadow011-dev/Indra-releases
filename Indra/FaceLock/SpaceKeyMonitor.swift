//
//  SpaceKeyMonitor.swift
//  Indra Face Lock
//
//  Detects the space key on the lock screen via raw IOKit HID reads — Secure Event Input suppresses every other keyboard tap there.
//
//  glance never appears under Input Monitoring: TCC resolves that gate against Accessibility first, and glance already requires
//  Accessibility to type the password, so `IOHIDCheckAccess` grants without ever registering it there. Correct, not a bug.
//
//  Graceful degradation: if access isn't granted or `IOHIDManagerOpen` fails, `start()` no-ops rather than crashing.
//
//  Not a keylogger: only runs while locked + opted into "On space", and the callback checks only whether the key is the spacebar.
//

import Foundation
import CoreGraphics
import AppKit
import IOKit
import IOKit.hid
import OSLog

@MainActor
final class SpaceKeyMonitor {
    /// Traces the Input Monitoring handshake, otherwise invisible since TCC decisions happen out of process.
    static let log = Logger(subsystem: "com.indra.Indra", category: "inputmonitoring")

    /// Fires on key-down only, not release or auto-repeat.
    var onSpaceKeyDown: (() -> Void)?

    private var manager: IOHIDManager?

    /// v498: second, independent way of seeing the space key. Reads the keyboard's key state 60 times a second while the
    /// monitor runs (only while locked and opted into "On space"). Needs no Input Monitoring grant and does not depend on
    /// which HID device the keyboard shows up as, so the space key still works when the HID reader above sees nothing.
    /// v508: what this monitor has seen since it started. One set PER MONITOR: these used to be shared statics, and the App Lock
    /// cover's monitor (stopped again once a second while no cover waits) reset them to zero every second, so nothing counted
    /// on the lock screen could be trusted. Plain numbers written from the reader's thread and read elsewhere; a lost update is
    /// harmless here.
    final class Counters: @unchecked Sendable {
        var hidOpened = false
        var hidValues = 0          // values (any key, up or down) the keyboard reader was given
        var keyLogs = 0            // "the reader saw a key" lines written (capped)
        var keyPressesReported = 0 // key presses the system itself reported (any key)
        var spaceSeen = 0          // space presses this monitor reported
        var anyKeyFallbacks = 0    // times two key presses started a scan
        var nonKeyInputs = 0       // v515: input that was not a key press (Touch ID, trackpad, ...) and was ignored
        var lastSpaceAt = Date.distantPast
    }
    nonisolated let counters = Counters()

    /// v508: set by the lock screen's owner. When the lock screen hides the keyboard from both readers (Secure Event Input
    /// does this to polling, and a missing Input Monitoring grant does it to the HID reader) the space bar can never be told
    /// apart from other keys, so the FIRST key pressed on the lock screen counts as the request instead. Typed stray keys are
    /// wiped from the password field before the password is typed (KeystrokeInjector), so this is safe. Off for App Lock covers
    /// (there a space inside a password must never start a scan).
    var allowsAnyKeyFallback = false

    /// v508: shown in Face Lock > General so "space did nothing" can be read from the app, not guessed.
    nonisolated(unsafe) static var lastSummary = "The lock screen has not been watched yet."
    nonisolated(unsafe) static var lastIgnoreReason = ""
    /// True when something asks the lock screen to start a scan on space: "On space", or App Lock's "Scan only on notch hover
    /// or button" (a person who starts scans by hand there expects space to work on the lock screen too).
    static var isWanted: Bool {
        true   // v516: always on for the lock screen (two key presses within 1 s, or notch hover / button)
    }
    /// v501: the key-state poll now runs on its own background queue (a dispatch timer), not as a main run loop timer. On the
    /// lock screen Indra has no visible window, so macOS "naps" it and stretches main-thread timers by seconds: a 60 Hz
    /// timer then sampled the space bar far too rarely to ever catch a normal key press (down and up inside one gap),
    /// which is why "press space" did nothing on the lock screen. A background timer plus an App Nap opt-out fixes that.
    private var pollSource: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.indra.space.poll", qos: .userInteractive)
    private var napActivity: NSObjectProtocol?
    private var lastFireAt = Date.distantPast

    /// Written and read only on `pollQueue`.
    private final class PollState: @unchecked Sendable {
        var wasDown = false
        /// v505: diagnosis only (see the poll handler).
        var ticks = 0
        var keyLogs = 0
        var beats = 0
        var lastKeyAge = Double.infinity
        /// v508: space was seen down since the last reported key press.
        var spaceSinceKey = false
        var allowFallback = false
        /// v510: when the "any key" fallback last started a scan (a cooldown replaces the old one-shot flag, so a second
        /// press still works after a failed scan).
        var lastFallbackAt = Date.distantPast
        /// v510: input-idle counters (seconds since the last input of any kind) and where the cursor was, to tell a key press
        /// from mouse movement without reading the keyboard.
        var prevIdleIO: Double?
        var prevIdleCG: Double?
        var lastCursor: CGPoint?
        var lastMouseAt = Date.distantPast
        var startedAt = Date()
        var idleLogs = 0
        /// v514: when the key-down counter last reported a real key press.
        var lastKeyDownAt = Date.distantPast
        var prevAgeHID: Double?
        var prevAgeSession: Double?
    }


    /// v510: the lock screen hides every key from Indra (Secure Event Input: the keyboard reader got 0 values and the system
    /// reported 0 key presses while locked). What it does NOT hide is the "seconds since the last input" counter that the
    /// screensaver uses. Read here from the HID system's registry entry; no permission needed.
    private final class IdleReader: @unchecked Sendable {
        private var service: io_service_t = 0
        init() { service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem")) }
        deinit { if service != 0 { IOObjectRelease(service) } }
        func seconds() -> Double? {
            guard service != 0,
                  let prop = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let ns = prop as? NSNumber else { return nil }
            return ns.doubleValue / 1_000_000_000
        }
    }

    // MARK: - Input Monitoring permission (static — callable without an instance)

    /// `denied` matters on its own: once set, no API can re-prompt — only System Settings can undo it.
    enum InputMonitoringAccess {
        case granted
        case denied
        case notDetermined
    }

    static var inputMonitoringAccess: InputMonitoringAccess {
        let raw = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let state: InputMonitoringAccess
        switch raw {
        case kIOHIDAccessTypeGranted: state = .granted
        case kIOHIDAccessTypeDenied: state = .denied
        default: state = .notDetermined
        }
        log.info("checkAccess -> \(String(describing: state), privacy: .public) (raw \(raw.rawValue)), xcodeLaunched=\(isLaunchedByXcode, privacy: .public)")
        return state
    }

    /// Never prompts. True whenever Accessibility is granted (see file header), so it tracks `KeystrokeInjector.isAccessibilityTrusted()`.
    static func hasInputMonitoringAccess() -> Bool {
        inputMonitoringAccess == .granted
    }

    /// True when launched by Xcode's Run button, which makes TCC decisions attribute to Xcode, not glance — test permission
    /// behavior from an independently launched copy instead (`open /path/to/glance.app`, or a build in /Applications).
    static var isLaunchedByXcode: Bool {
        ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }

    /// Near-always a no-op: already satisfied through Accessibility. Skipped under Xcode, where it would attribute to Xcode instead.
    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        guard !isLaunchedByXcode else {
            log.error("requestAccess SKIPPED — launched by Xcode, request would be attributed to Xcode")
            return hasInputMonitoringAccess()
        }
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log.info("requestAccess -> \(granted, privacy: .public)")
        return granted
    }

    // MARK: - Lifecycle

    /// Idempotent. v498: starts both readers (HID and key-state polling); either one is enough.
    func start() {
        if manager == nil, pollSource == nil {
            // A fresh watch (a new lock screen): the numbers start from zero.
            let c = counters
            c.hidOpened = false; c.hidValues = 0; c.keyLogs = 0; c.keyPressesReported = 0; c.spaceSeen = 0; c.anyKeyFallbacks = 0; c.nonKeyInputs = 0
            pressTimes.removeAll()
        }
        startHID()
        startPolling()
    }

    /// Idempotent; fails closed if access was revoked between the caller's check and here.
    private func startHID() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match physical keyboards only, not every HID device.
        // v508: keyboards AND keypads (some keyboards, and Apple's built-in one on some models, show up as a keypad).
        let keyboard: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        let keypad: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad,
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, [keyboard, keypad] as CFArray)

        // Capture-less C callback; `self` threaded through the context pointer. `passUnretained` is safe since this object
        // always `stop()`s (unregistering) before deallocation.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            let counters = Unmanaged<SpaceKeyMonitor>.fromOpaque(context).takeUnretainedValue().counters
            counters.hidValues &+= 1
            let element = IOHIDValueGetElement(value)
            if IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad), IOHIDValueGetIntegerValue(value) == 1,
               counters.keyLogs < 4 {
                counters.keyLogs += 1
                Trace.log("SPACE: keyboard reader saw key usage \(IOHIDElementGetUsage(element)) (space is 44)")
            }
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardSpacebar),
                  IOHIDValueGetIntegerValue(value) == 1 // key-down only
            else { return }
            let monitor = Unmanaged<SpaceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            // Already on the main thread (scheduled on the main run loop); hop onto the main actor to satisfy isolation.
            Task { @MainActor in monitor.keyPressed(source: "hid") }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // Ground truth about HID access (unlike IOHIDCheckAccess); logged since a failure here is a silent no-op on the lock screen.
        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        counters.hidOpened = (result == kIOReturnSuccess)
        Trace.log("SPACE: keyboard reader opened=\(result == kIOReturnSuccess) (code 0x\(String(result, radix: 16))), Input Monitoring=\(String(describing: Self.inputMonitoringAccess))")
        guard result == kIOReturnSuccess else {
            Self.log.error("IOHIDManagerOpen FAILED (0x\(String(result, radix: 16), privacy: .public)) — space key won't be seen")
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        Self.log.info("listening for space on the lock screen")
        manager = mgr
    }

    /// Stops listening. Idempotent.
    func stop() {
        let wasRunning = manager != nil || pollSource != nil
        stopPolling()
        if wasRunning && allowsAnyKeyFallback { recordSummary() }
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    /// v508: one readable line about the watch that just ended (lock-screen monitor only).
    private func recordSummary() {
        let c = counters
        var line = "Last lock screen: keyboard reader \(c.hidOpened ? "opened" : "could not open"), \(c.hidValues) key values seen; "
            + "the system reported \(c.keyPressesReported) key presses; space seen \(c.spaceSeen) times"
        if c.anyKeyFallbacks > 0 { line += "; a scan was started by two key presses" }
        if c.keyPressesReported > 0, c.hidValues == 0, c.spaceSeen == 0 {
            line += ". Keys reached the Mac but not Indra's keyboard reader: allow Indra under Privacy & Security > Input Monitoring."
        }
        if c.nonKeyInputs > 0 { line += "; \(c.nonKeyInputs) inputs that were not key presses were ignored" }
        if c.nonKeyInputs > 0, c.keyPressesReported == 0, c.spaceSeen == 0 {
            line += ". The lock screen reported input but no key presses to Indra, so the two-key start cannot see keys on this Mac."
        }
        Self.lastSummary = line
        Trace.log("SPACE: " + line)
    }

    // MARK: - v498: key-state polling and the shared "space was pressed" entry point

    private func startPolling() {
        guard pollSource == nil else { return }
        // The app must not be "napped" while it waits for the space bar on the lock screen.
        if napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Indra face unlock is watching the space key on the lock screen")
        }
        let state = PollState()
        state.allowFallback = allowsAnyKeyFallback
        let counters = self.counters
        let queue = pollQueue   // v509: captured here; the timer closure below may not name self.pollQueue
        // A space key that is already held when the monitor starts is not a new press.
        state.wasDown = Self.isSpaceDownNow()
        let idleReader = IdleReader()
        state.startedAt = Date()
        state.prevIdleIO = idleReader.seconds()
        let anyInput = CGEventType(rawValue: UInt32.max)
        Trace.log("SPACE: input-idle counters at start: registry=\(state.prevIdleIO.map { String(format: "%.2f", $0) } ?? "unreadable") s")
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            let down = SpaceKeyMonitor.isSpaceDownNow()
            state.ticks += 1
            // v508: both state tables are asked for the time since the last key press (a question the system answers on the
            // lock screen too); the smaller age wins.
            let ageHID = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
            let ageSession = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            let age: Double = min(ageHID.isFinite ? ageHID : Double.infinity, ageSession.isFinite ? ageSession : Double.infinity)
            if down { state.spaceSinceKey = true }
            // v515: a key press is told ONLY by the system's own "seconds since the last key down" counters (one per state table),
            // which mouse, trackpad and Touch ID input never touch. A drop of either counter is a new key press. The idle
            // counters (any input) are read for the log only and never start anything.
            let idleIO = idleReader.seconds()
            let idleCG: Double? = anyInput.map { min(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0),
                                                     CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)) }
            let now = Date()
            var idleDropped = false
            if let io = idleIO, let prev = state.prevIdleIO, io < prev - 0.004 { idleDropped = true }
            if let cg = idleCG, cg.isFinite, let prev = state.prevIdleCG, cg < prev - 0.004 { idleDropped = true }
            state.prevIdleIO = idleIO
            state.prevIdleCG = idleCG?.isFinite == true ? idleCG : nil
            let settled = now.timeIntervalSince(state.startedAt) > 0.5   // the keys that locked or woke the Mac don't count
            var keyDownEvent = false
            if ageHID.isFinite, let prev = state.prevAgeHID, ageHID < prev - 0.004 { keyDownEvent = true }
            if ageSession.isFinite, let prev = state.prevAgeSession, ageSession < prev - 0.004 { keyDownEvent = true }
            state.prevAgeHID = ageHID.isFinite ? ageHID : nil
            state.prevAgeSession = ageSession.isFinite ? ageSession : nil
            if keyDownEvent {
                state.lastKeyDownAt = now
                if settled {
                    counters.keyPressesReported += 1
                    if state.keyLogs < 10 {
                        state.keyLogs += 1
                        Trace.log("SPACE: key press seen (key-down counter)")
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.keyPressed(source: "key-down counter") }
                    }
                }
            } else if idleDropped, now.timeIntervalSince(state.lastKeyDownAt) > 0.35, state.idleLogs < 8 {
                state.idleLogs += 1
                counters.nonKeyInputs += 1
                Trace.log("SPACE: input that was not a key press (finger on the sensor, trackpad, ...): ignored")
            }
            state.lastKeyAge = age
            // Every 5 seconds for the first two minutes of a watch: how long it has been running, how many values the keyboard
            // reader was given, and how long ago the system last saw a key press.
            if state.ticks % 250 == 0, state.beats < 24 {
                state.beats += 1
                Trace.log("SPACE: still watching (\(state.ticks / 50) s); keyboard reader values: \(counters.hidValues); last key press the system saw: \(age.isFinite ? Int(min(age, 9999)) : -1) s ago; idle counters: registry=\(idleIO.map { String(format: "%.1f", $0) } ?? "unreadable") cg=\(idleCG.map { String(format: "%.1f", $0) } ?? "n/a")")
            }
            let pressed = down && !state.wasDown
            state.wasDown = down
            guard pressed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.keyPressed(source: "poll") }
            }
        }
        timer.resume()
        pollSource = timer
        Self.log.info("polling the space key state while locked")
        Trace.log("SPACE: watching the space key on the lock screen (Input Monitoring=\(String(describing: Self.inputMonitoringAccess)))")
    }

    private func stopPolling() {
        if pollSource != nil { Trace.log("SPACE: stopped watching the space key") }
        pollSource?.cancel()
        pollSource = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    /// Key code 0x31 is the space bar. Reads the hardware key state, which Secure Event Input on the lock screen does
    /// not hide (it only hides key EVENTS from event taps). Both the raw hardware table and the session table are asked,
    /// since which of the two keeps updating on the lock screen differs between macOS versions.
    nonisolated private static func isSpaceDownNow() -> Bool {
        CGEventSource.keyState(.hidSystemState, key: 0x31) || CGEventSource.keyState(.combinedSessionState, key: 0x31)
    }

    /// v515: how many key presses (any keys) in a row start a scan on the lock screen.
    var requiredKeyPresses = 2
    private var pressTimes: [Date] = []

    /// Every reader reports a key press here. The App Lock cover (no "any key" mode) starts on the first space as before; the
    /// lock screen needs `requiredKeyPresses` presses of ANY keys within 1 s, so a single key, a finger on Touch ID, the
    /// cursor or the trackpad never starts a scan.
    func keyPressed(source: String) {
        guard allowsAnyKeyFallback else { fire(source: source); return }
        let now = Date()
        pressTimes.removeAll { now.timeIntervalSince($0) > 1.0 }
        // One physical press is often reported by two readers a few milliseconds apart.
        if let last = pressTimes.last, now.timeIntervalSince(last) < 0.12 { return }
        pressTimes.append(now)
        Trace.log("SPACE: key press \(pressTimes.count) of \(requiredKeyPresses) (\(source))")
        guard pressTimes.count >= requiredKeyPresses else { return }
        pressTimes.removeAll()
        counters.anyKeyFallbacks += 1
        fire(source: "two key presses")
    }

    /// Both readers end up here. A press seen by both within 0.4 s counts once.
    func fire(source: String) {
        let now = Date()
        guard now.timeIntervalSince(lastFireAt) > 0.4 else { return }
        lastFireAt = now
        counters.spaceSeen += 1
        counters.lastSpaceAt = now
        Self.log.info("space key seen via \(source, privacy: .public)")
        Trace.log("SPACE: space key seen via \(source)")
        onSpaceKeyDown?()
    }

    deinit {
        // Always stopped before teardown (on unlock/disable), so nothing to unwind here.
    }
}
