import AppKit
import CoreAudio
import IOKit

struct SensoryEvent {
    let kind: HUDKind
    /// 0 ... 1
    let value: Double
    let muted: Bool
}

/// Reads / writes brightness through private macOS calls (loaded at runtime).
/// Inside the App Sandbox these calls are refused, so brightness is then unavailable.
fileprivate final class BrightnessAccess: @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let getFunction: GetBrightness?
    private let setFunction: SetBrightness?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let handle = dlopen(path, RTLD_LAZY) {
            getFunction = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
            setFunction = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        } else {
            getFunction = nil
            setFunction = nil
        }
    }

    func read(display: CGDirectDisplayID) -> Float? {
        guard let getFunction else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    func write(_ value: Float, display: CGDirectDisplayID) -> Bool {
        guard let setFunction else { return false }
        return setFunction(display, min(max(value, 0), 1)) == 0
    }

    /// Same answer as `builtInDisplay()` without AppKit, so it can run on a background queue.
    static func builtInDisplayThreadSafe() -> CGDirectDisplayID {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetActiveDisplayList(16, &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return CGMainDisplayID()
    }

    static func builtInDisplay() -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayIsBuiltin(number) != 0 {
                return number
            }
        }
        return CGMainDisplayID()
    }
}

/// Reads / writes the keyboard backlight through the private CoreBrightness framework (loaded at runtime,
/// like the display brightness). Inside the App Sandbox this is usually refused, so it is then unavailable.
fileprivate final class KeyboardBacklightAccess: @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetBrightness = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias CopyIDs = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?

    private let client: NSObject?
    private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    private let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
    private var keyboardID: UInt64 = 1

    init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        if let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let object = type.init()
            client = object.responds(to: getSelector) && object.responds(to: setSelector) ? object : nil
        } else {
            client = nil
        }
        if let client, client.responds(to: idsSelector) {
            let function = unsafeBitCast(client.method(for: idsSelector), to: CopyIDs.self)
            if let list = function(client, idsSelector)?.takeRetainedValue() as? [NSNumber],
               let first = list.first {
                keyboardID = first.uint64Value
            }
        }
    }

    func read() -> Float? {
        guard let client else { return nil }
        let function = unsafeBitCast(client.method(for: getSelector), to: GetBrightness.self)
        let value = function(client, getSelector, keyboardID)
        guard value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    func write(_ value: Float) -> Bool {
        guard let client else { return false }
        let function = unsafeBitCast(client.method(for: setSelector), to: SetBrightness.self)
        return function(client, setSelector, min(max(value, 0), 1), keyboardID)
    }
}

/// What works in this build of Indra (shown in Settings).
enum SensoryDiagnostics {
    /// True while the App Sandbox is on (the standard build).
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func brightnessReadable() -> Bool {
        let access = BrightnessAccess()
        return access.read(display: BrightnessAccess.builtInDisplay()) != nil
    }

    static func keyboardBacklightReadable() -> Bool {
        KeyboardBacklightAccess().read() != nil
    }
}

/// Watches the output volume (CoreAudio listeners, no polling) and the built-in display brightness,
/// and can change both (used when the macOS pop-up is replaced).
@MainActor
final class SensoryMonitor {
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663 // 'vmvc'

    private let onEvent: (SensoryEvent) -> Void
    private let brightness = BrightnessAccess()
    private let keyboard = KeyboardBacklightAccess()

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var lastVolume: Float?
    private var lastMuted: Bool?

    private var brightnessTimer: Timer?
    private var lastBrightness: Float?
    private var lastKeyboard: Float?
    /// The overlay only shows for changes you make yourself. Locking the screen, display sleep and wake, and the
    /// automatic dimming that goes with them change the levels too: no overlay for those.
    private var quietUntil = Date.distantPast
    private var quietObservers: [NSObjectProtocol] = []
    /// When a keyboard backlight key (brightness up / down / toggle) was last pressed.
    private var lastBacklightKey = Date.distantPast
    private var backlightKeyMonitor: Any?
    /// v501: true while the screen is locked or the display / Mac sleeps. Nothing is polled then: the brightness and
    /// backlight daemons are busiest (and slowest to answer) at exactly those moments.
    private var systemIdle = false
    /// v525: true while the screen is locked. A locked screen is NOT idle: the lock screen's own volume / brightness overlay
    /// has to see changes made there, so reads go on (a bit slower), unlike while the display sleeps or the screensaver runs.
    private var screenLocked = false
    private var lockedPollSkip = false
    /// v525: locked by the notification, or (in case that was missed) by the session's own state.
    private var isLockedNow: Bool { screenLocked || LockMonitor.isScreenLockedCached() }
    /// v501: brightness / backlight reads are round trips to system daemons. They run here, never on the main thread, so a
    /// slow answer can no longer hold up the main thread (and with it the key tap and every window).
    private let readQueue = DispatchQueue(label: "com.indra.sensory.read", qos: .utility)
    private var readInFlight = false

    init(onEvent: @escaping (SensoryEvent) -> Void) {
        self.onEvent = onEvent
    }

    var canAdjustBrightness: Bool {
        brightness.read(display: BrightnessAccess.builtInDisplay()) != nil
    }

    var canAdjustKeyboard: Bool {
        keyboard.read() != nil
    }

    /// True when a change right now is most likely yours: no lock / sleep / wake in the last few seconds, and you
    /// touched the keyboard, trackpad or mouse a moment ago (a slider drag or a key press).
    private var isManualChange: Bool {
        guard Date() >= quietUntil else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0) ?? .null)
        // v525: the session's counter alone could stay silent on the lock screen; the HID system's own idle counter (the one the
        // screensaver uses) does not, so whichever saw input most recently counts.
        let hid = SensoryMonitor.hidIdleSeconds() ?? .infinity
        return min(idle, hid) < 1.5
    }

    /// v525: seconds since the last keyboard / mouse input, from the HID system's registry entry (needs no permission).
    private static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = property as? NSNumber else { return nil }
        return nanoseconds.doubleValue / 1_000_000_000
    }

    /// v541: brightness and the keyboard backlight move BY THEMSELVES (adaptive brightness follows the room light, the backlight
    /// follows it too and switches off when you stop typing). Their overlays are only for a change you make yourself, and that
    /// is exactly two things: a brightness / backlight KEY, or dragging the slider in Control Center / System Settings. Before
    /// v541 any typing, any trackpad movement (brightness) or any left click anywhere (backlight) counted as "yours", so the
    /// automatic changes that happen while you work brought the overlay up. A key press is remembered here; the slider is
    /// recognised by `pointerIsOnSystemSlider` (checked on the read queue, only when a level actually moved).
    private var lastBrightnessKey = Date.distantPast
    private var lastAutoLogAt = Date.distantPast

    private func keyWasPressed(_ kind: HUDKind) -> Bool {
        guard Date() >= quietUntil else { return false }
        let at = kind == .brightness ? lastBrightnessKey : lastBacklightKey
        return Date().timeIntervalSince(at) < 1.2
    }

    /// v541: true while the pointer is pressed (or was released a moment ago) on a Control Center / System Settings window:
    /// the only places where the brightness and backlight sliders live. Thread-safe (runs on the read queue).
    private nonisolated static func pointerIsOnSystemSlider() -> Bool {
        let source = CGEventSourceStateID.combinedSessionState
        let pressed = CGEventSource.buttonState(source, button: .left)
        guard pressed || CGEventSource.secondsSinceLastEventType(source, eventType: .leftMouseUp) < 0.6,
              let point = CGEvent(source: nil)?.location,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let owners: Set<String> = ["Control Center", "System Settings", "System Preferences"]
        for window in list {   // front to back
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.contains(point) else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            return owners.contains(window[kCGWindowOwnerName as String] as? String ?? "")
        }
        return false
    }

    private func watchBacklightKeys() {
        guard backlightKeyMonitor == nil else { return }
        backlightKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data = event.data1
            let code = (data & 0xFFFF0000) >> 16
            // v525: the volume and brightness keys pressed on the lock screen (see `lockScreenKeyPressed`).
            let isDown = (((data & 0x0000FFFF) & 0xFF00) >> 8) == 0xA
            if isDown, let key = SystemKey(rawValue: code) {
                MainActor.assumeIsolated { self?.lockScreenKeyPressed(key) }
            }
            if code == SystemKey.brightnessUp.rawValue || code == SystemKey.brightnessDown.rawValue {
                MainActor.assumeIsolated { self?.lastBrightnessKey = Date() }
                return
            }
            guard code == SystemKey.keyboardUp.rawValue || code == SystemKey.keyboardDown.rawValue || code == 23 else { return }
            MainActor.assumeIsolated { self?.lastBacklightKey = Date() }
        }
    }

    /// v525: a volume / brightness key was pressed while the screen is locked and reached this passive monitor (v526: normally the
    /// key tap catches it first and shows the overlay itself; this is the fallback). Indra's own key tap was off there (macOS handled
    /// the key), and the overlay used to depend on the level having visibly changed and on input-idle counters: nothing
    /// showed at full or zero volume, or when the counters stayed silent. The key press itself now asks for the overlay: a
    /// moment later, once macOS has applied it, the level is read and shown whatever it is.
    private func lockScreenKeyPressed(_ key: SystemKey) {
        guard isLockedNow else { return }
        Trace.log("LOCKHUD: key \(key) pressed on the lock screen")
        // v528: a key that reaches this passive monitor was NOT caught by the key tap, so macOS is about to draw its own pop-up as well.
        // Indra's overlay replaces it, so macOS's helper is kept from drawing for a moment (see `SystemHUDSuppressor`).
        switch key {
        case .soundUp, .soundDown, .mute:
            if Preferences.sensoryVolume { SystemHUDSuppressor.suppress(why: "\(key) reached macOS on the lock screen") }
        case .brightnessUp, .brightnessDown:
            if Preferences.sensoryBrightness { SystemHUDSuppressor.suppress(why: "\(key) reached macOS on the lock screen") }
        case .keyboardUp, .keyboardDown:
            if Preferences.sensoryKeyboard { SystemHUDSuppressor.suppress(why: "\(key) reached macOS on the lock screen") }
        }
        switch key {
        case .soundUp, .soundDown, .mute:
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard let self, self.isLockedNow else { return }
                self.publishVolume()
            }
        case .brightnessUp, .brightnessDown:
            guard Preferences.sensoryBrightness else { return }
            let brightness = self.brightness
            readQueue.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                let value = brightness.read(display: BrightnessAccess.builtInDisplayThreadSafe())
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isLockedNow, let value else { return }
                        self.lastBrightness = value
                        self.onEvent(SensoryEvent(kind: .brightness, value: Double(value), muted: false))
                    }
                }
            }
        default:
            break
        }
    }

    private func quiet(for seconds: Double) {
        quietUntil = Date().addingTimeInterval(seconds)
    }

    private func watchQuietTimes() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            quietObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // v525: locking no longer counts as idle (see `screenLocked`). A lock can also arrive while the display
                    // already sleeps, so it leaves the idle flag as it is; the screensaver and an unlock set it.
                    switch name {
                    case "com.apple.screenIsLocked": self?.screenLocked = true
                    case "com.apple.screenIsUnlocked": self?.screenLocked = false; self?.systemIdle = false
                    case "com.apple.screensaver.didstart": self?.systemIdle = true
                    default: self?.systemIdle = false
                    }
                    self?.quiet(for: 4)
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                                          NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                                          NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        let idling: Set<Notification.Name> = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                                              NSWorkspace.sessionDidResignActiveNotification]
        for name in names {
            let idles = idling.contains(name)
            quietObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemIdle = idles
                    self?.quiet(for: 4)
                }
            })
        }
    }

    func start() {
        watchQuietTimes()
        watchBacklightKeys()
        var address = SensoryMonitor.address(kAudioHardwarePropertyDefaultOutputDevice,
                                             scope: kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.attachVolumeListeners()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            defaultDeviceBlock = block
        }
        attachVolumeListeners()
        refreshSettings()
    }

    /// Brightness and the keyboard backlight are only watched while their overlay is switched on.
    func refreshSettings() {
        let watchBrightness = Preferences.sensoryBrightness && canAdjustBrightness
        let watchKeyboard = Preferences.sensoryKeyboard && canAdjustKeyboard
        lastBrightness = watchBrightness ? (lastBrightness ?? brightness.read(display: BrightnessAccess.builtInDisplay())) : nil
        lastKeyboard = watchKeyboard ? (lastKeyboard ?? keyboard.read()) : nil
        if watchBrightness || watchKeyboard {
            guard brightnessTimer == nil else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollSystemLevels() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            brightnessTimer = timer
        } else {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
        }
    }

    // MARK: - Changing volume / brightness (used when the macOS pop-up is hidden)

    func adjustVolume(by delta: Float) {
        guard let current = readVolume() else { return }
        if delta > 0, readMuted() == true { writeMuted(false) }
        let target = min(max(current + delta, 0), 1)
        writeVolume(target)
        publishVolume()
    }

    func toggleMute() {
        let muted = readMuted() ?? false
        writeMuted(!muted)
        publishVolume()
    }

    func adjustBrightness(by delta: Float) {
        let display = BrightnessAccess.builtInDisplay()
        guard let current = brightness.read(display: display) else { return }
        let target = min(max(current + delta, 0), 1)
        lastBrightnessKey = Date()
        _ = brightness.write(target, display: display)
        lastBrightness = target
        onEvent(SensoryEvent(kind: .brightness, value: Double(target), muted: false))
    }

    func adjustKeyboard(by delta: Float) {
        guard let current = keyboard.read() else { return }
        let target = min(max(current + delta, 0), 1)
        lastBacklightKey = Date()
        _ = keyboard.write(target)
        lastKeyboard = target
        onEvent(SensoryEvent(kind: .keyboard, value: Double(target), muted: false))
    }

    // MARK: - Volume

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func detachVolumeListeners() {
        guard let block = volumeBlock, deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var volumeAddress = SensoryMonitor.address(SensoryMonitor.virtualMainVolume)
        var muteAddress = SensoryMonitor.address(kAudioDevicePropertyMute)
        AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, block)
        AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, block)
        volumeBlock = nil
    }

    private func attachVolumeListeners() {
        detachVolumeListeners()
        var defaultAddress = SensoryMonitor.address(kAudioHardwarePropertyDefaultOutputDevice,
                                                    scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return }
        deviceID = device
        lastVolume = readVolume()
        lastMuted = readMuted()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.audioChanged()
            }
        }
        var volumeAddress = SensoryMonitor.address(SensoryMonitor.virtualMainVolume)
        var muteAddress = SensoryMonitor.address(kAudioDevicePropertyMute)
        let volumeStatus = AudioObjectAddPropertyListenerBlock(device, &volumeAddress, DispatchQueue.main, block)
        _ = AudioObjectAddPropertyListenerBlock(device, &muteAddress, DispatchQueue.main, block)
        if volumeStatus == noErr { volumeBlock = block }
    }

    private func readVolume() -> Float? {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = SensoryMonitor.address(SensoryMonitor.virtualMainVolume)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func readMuted() -> Bool? {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = SensoryMonitor.address(kAudioDevicePropertyMute)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private func writeVolume(_ volume: Float) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = SensoryMonitor.address(SensoryMonitor.virtualMainVolume)
        var value = Float32(volume)
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private func writeMuted(_ muted: Bool) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = SensoryMonitor.address(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Always shows the overlay, even when the value did not change (for example at maximum volume).
    private func publishVolume() {
        guard let volume = readVolume() else { return }
        let muted = readMuted() ?? false
        lastVolume = volume
        lastMuted = muted
        onEvent(SensoryEvent(kind: .volume, value: Double(volume), muted: muted))
    }

    private func audioChanged() {
        guard let volume = readVolume() else { return }
        let muted = readMuted() ?? false
        defer {
            lastVolume = volume
            lastMuted = muted
        }
        guard lastVolume != volume || lastMuted != muted else { return }
        // v525: on the lock screen nothing else changes the volume (a Bluetooth connect is held back by its own quiet
        // time), so a change after the quiet period counts as yours without asking the idle counters.
        guard isManualChange || (isLockedNow && Date() >= quietUntil) else {
            if isLockedNow { Trace.log("LOCKHUD: the volume changed on the lock screen but was not counted as yours (quiet period or no recent input)") }
            return
        }
        if isLockedNow { Trace.log("LOCKHUD: volume change on the lock screen: sending it to the lock window") }
        onEvent(SensoryEvent(kind: .volume, value: Double(volume), muted: muted))
    }

    // MARK: - Brightness

    /// v501: reads the levels on a background queue (one read at a time, none while the Mac is locked or asleep) and
    /// handles the result back on the main thread.
    private func pollSystemLevels() {
        guard !systemIdle, !readInFlight else { return }
        // v525: on the lock screen the reads run at half the rate (they are on a background queue, so a slow daemon answer
        // cannot hold up the main thread any more).
        if isLockedNow {
            lockedPollSkip.toggle()
            if lockedPollSkip { return }
        }
        let wantBrightness = Preferences.sensoryBrightness
        let wantKeyboard = Preferences.sensoryKeyboard
        guard wantBrightness || wantKeyboard else { return }
        readInFlight = true
        let brightness = self.brightness
        let keyboard = self.keyboard
        let lastB = lastBrightness
        let lastK = lastKeyboard
        readQueue.async { [weak self] in
            let b = wantBrightness ? brightness.read(display: BrightnessAccess.builtInDisplayThreadSafe()) : nil
            let k = wantKeyboard ? keyboard.read() : nil
            // v541: only when a level really moved, and only here (off the main thread), look at whether the pointer is on a
            // system slider. Almost every poll finds nothing moved and costs nothing.
            var moved = false
            if let b, let lastB, abs(lastB - b) > 0.004 { moved = true }
            if let k, let lastK, abs(lastK - k) > 0.03 { moved = true }
            let onSlider = moved ? SensoryMonitor.pointerIsOnSystemSlider() : false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.readInFlight = false
                    guard !self.systemIdle else { return }
                    if let b { self.handleBrightness(b, sliderDrag: onSlider) }
                    if let k { self.handleKeyboard(k, sliderDrag: onSlider) }
                }
            }
        }
    }

    /// v541: only a brightness key or a drag of the system slider shows the overlay. A change that has neither (adaptive
    /// brightness following the room light, dimming on battery, True Tone and so on) never does, whatever you are doing.
    private func handleBrightness(_ value: Float, sliderDrag: Bool) {
        guard Preferences.sensoryBrightness else { return }
        defer { lastBrightness = value }
        guard let last = lastBrightness, abs(last - value) > 0.004 else { return }
        guard keyWasPressed(.brightness) || (sliderDrag && Date() >= quietUntil) else {
            noteAutomaticChange("brightness")
            return
        }
        onEvent(SensoryEvent(kind: .brightness, value: Double(value), muted: false))
    }

    /// Same rule for the keyboard backlight: a backlight key or the system slider, never the automatic light.
    private func handleKeyboard(_ value: Float, sliderDrag: Bool) {
        guard Preferences.sensoryKeyboard else { return }
        defer { lastKeyboard = value }
        guard let last = lastKeyboard, abs(last - value) > 0.03 else { return }
        guard keyWasPressed(.keyboard) || (sliderDrag && Date() >= quietUntil) else {
            noteAutomaticChange("keyboard backlight")
            return
        }
        onEvent(SensoryEvent(kind: .keyboard, value: Double(value), muted: false))
    }

    /// One trace line every 30 s at most, so the log shows that the overlay was held back on purpose.
    private func noteAutomaticChange(_ what: String) {
        guard Date().timeIntervalSince(lastAutoLogAt) > 30 else { return }
        lastAutoLogAt = Date()
        Trace.log("HUD: \(what) changed by itself (no key, no system slider): no overlay")
    }
}
