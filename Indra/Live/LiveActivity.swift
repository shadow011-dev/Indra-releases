import AppKit
import IOKit.ps

/// Short-lived activities shown at the sides of the closed notch.
enum LiveActivity: Equatable {
    case battery(percent: Int, charging: Bool, pluggedIn: Bool)
    case lock(locked: Bool)
    case hud(kind: HUDKind, value: Double, muted: Bool)
    case bluetooth(name: String, kind: BluetoothKind, connected: Bool)
    /// A to-do or reminder popping up (when and how often is set in To Do settings).
    case task(kind: TaskKind, title: String, detail: String)
    /// A different song started: the usual artwork and visualizer beside the notch, and the title and artist
    /// in a strip hanging below it.
    case song(title: String, artist: String)
    /// v553: a new version of Indra is ready: a card below the closed notch for a few seconds (see UpdateNotice).
    case update(version: Int)
}

extension LiveActivity {
    /// A short name for the problem log (no device names or other personal details).
    var logName: String {
        switch self {
        case .battery(let percent, let charging, _): return "battery \(percent)%\(charging ? " charging" : "")"
        case .lock(let locked): return locked ? "lock" : "unlock"
        case .hud(let kind, _, _): return kind.logName
        case .bluetooth(_, let kind, let connected): return "bluetooth \(kind.rawValue) \(connected ? "connected" : "disconnected")"
        case .task(let kind, _, _): return "task \(kind.rawValue)"
        case .song: return "song change"
        case .update: return "update notice"
        }
    }
}

/// What a volume / brightness overlay is about.
enum HUDKind: Equatable {
    case volume
    case brightness
    case keyboard

    var title: String {
        switch self {
        case .volume: return "Volume"
        case .brightness: return "Display"
        case .keyboard: return "Keyboard"
        }
    }

    var logName: String {
        switch self {
        case .volume: return "volume"
        case .brightness: return "brightness"
        case .keyboard: return "keyboard backlight"
        }
    }

    func notchSymbol(value: Double, muted: Bool) -> String {
        switch self {
        case .brightness: return "display"
        case .keyboard: return value <= 0.001 ? "light.min" : "light.max"
        case .volume: return HUDKind.speakerSymbol(value: value, muted: muted)
        }
    }

    func appleSymbol(value: Double, muted: Bool) -> String {
        switch self {
        case .brightness: return "sun.max.fill"
        case .keyboard: return value <= 0.001 ? "light.min" : "light.max"
        case .volume: return HUDKind.speakerSymbol(value: value, muted: muted)
        }
    }

    private static func speakerSymbol(value: Double, muted: Bool) -> String {
        if muted || value <= 0.001 { return "speaker.slash.fill" }
        if value < 0.34 { return "speaker.wave.1.fill" }
        if value < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool

    static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let capacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return BatteryInfo(percent: maximum > 0 ? capacity * 100 / maximum : capacity,
                               charging: charging,
                               pluggedIn: pluggedIn)
        }
        return nil
    }
}

/// Event-driven: power-source change notifications and screen lock/unlock notifications.
@MainActor
final class LiveActivityMonitor {
    private let onActivity: (LiveActivity) -> Void
    /// v523: each token is kept with the centre that made it (this monitor uses the distributed and the workspace centres),
    /// so `stop()` can remove it from the right one.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var started = false
    private var lastBattery: BatteryInfo?
    /// Battery changes are ignored for a few seconds after locking, unlocking or waking.
    private var quietUntil = Date.distantPast
    private var screenLocked = false
    /// Safety net: macOS sometimes drops a power-source notification (after sleep, or while the run loop is busy),
    /// so the state is also compared every couple of seconds.
    private var pollTimer: Timer?

    init(onActivity: @escaping (LiveActivity) -> Void) {
        self.onActivity = onActivity
    }

    func start() {
        guard !started else { return }
        started = true
        lastBattery = BatteryInfo.read()

        // The run-loop source gets an unretained pointer to this object, so it must be removed (stop()) before this
        // object can ever be freed.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<LiveActivityMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.powerChanged()
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        // v507: a safety net behind the power-source notification above: every 5 s with slack (was every 2 s).
        let poll = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.powerChanged() }
        }
        poll.tolerance = 2
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        let center = DistributedNotificationCenter.default()
        observers.append((center, center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                     object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emitLock(true) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.quietBattery() }
            }))
        }
        observers.append((center, center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                     object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emitLock(false) }
        }))
    }

    /// v523: takes everything `start()` registered back out (the power-source run-loop source, the safety-net timer and the
    /// notification observers). Safe to call twice, and to call without `start()`.
    func stop() {
        guard started else { return }
        started = false
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        powerSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()
        Trace.log("LiveActivityMonitor stopped")
    }

    private func quietBattery() {
        // On the lock screen a plug-in right after waking is real, so the quiet spell is short there.
        quietUntil = Date().addingTimeInterval(screenLocked ? 2 : 8)
        lastBattery = BatteryInfo.read()
    }

    private func emitLock(_ locked: Bool) {
        screenLocked = locked
        quietBattery()
        // The lock / unlock icon was removed from the notch.
    }

    private func powerChanged() {
        guard let new = BatteryInfo.read() else { return }
        let old = lastBattery
        guard new != old else { return }
        lastBattery = new
        guard Preferences.liveBattery, let old else { return }

        // Plugging in or pulling out always shows, even right after waking or unlocking (the old reading is
        // refreshed on wake, so this cannot be a leftover). Only the percentage alerts wait out the quiet spell.
        let pluggedChanged = new.pluggedIn != old.pluggedIn
        let quiet = Date() < quietUntil
        let becameLow = !quiet && !new.pluggedIn && new.percent <= 20 && old.percent > 20
        let becameCritical = !quiet && !new.pluggedIn && new.percent <= 10 && old.percent > 10
        // The charge limit from Settings (80 / 90 / 100): popping up when the battery reaches it while plugged in.
        let limit = Preferences.batteryLimit
        let reachedLimit = !quiet && new.pluggedIn && old.percent < limit && new.percent >= limit
        // v536: every power change that reaches this point leaves one line, so a missing pop-up can be explained from the log.
        Trace.log("BATTERY: \(old.percent)% -> \(new.percent)% plugged \(old.pluggedIn) -> \(new.pluggedIn), limit \(limit), quiet \(quiet): "
                  + ((pluggedChanged || becameLow || becameCritical || reachedLimit) ? "pop-up" : "no pop-up"))
        if pluggedChanged || becameLow || becameCritical || reachedLimit {
            // macOS reports "charging" a moment after the plug is detected, so plugged in counts as charging.
            let charging = new.charging || new.pluggedIn
            // On the lock screen the notch is not drawn: the lock screen window shows the same card.
            NotificationCenter.default.post(name: .indraLockBattery, object: nil,
                                            userInfo: ["percent": new.percent, "charging": charging, "pluggedIn": new.pluggedIn])
            onActivity(.battery(percent: new.percent, charging: charging, pluggedIn: new.pluggedIn))
        }
    }
}
