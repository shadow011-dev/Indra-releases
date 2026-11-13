import SwiftUI
import IOBluetooth
import IOKit
import QuartzCore

/// What kind of device connected. Every kind is drawn as the matching Apple product,
/// whatever the real brand is (a Galaxy phone shows an iPhone, a ThinkPad shows a MacBook...).
enum BluetoothKind: String, Equatable, CaseIterable {
    case earbuds
    case headphones
    case phone
    case tablet
    case laptop
    case desktop
    case watch
    case speaker
    case keyboard
    case mouse

    /// Everything except earbuds and headphones.
    static let otherDevices: [BluetoothKind] = [.phone, .tablet, .laptop, .desktop, .watch, .speaker, .keyboard, .mouse]

    var isAudioWearable: Bool { self == .earbuds || self == .headphones }

    /// Every device except the earbuds, headphones and the watch is drawn as a live 3D model.
    var has3DModel: Bool { !isAudioWearable && self != .watch }

    /// Name of the Apple product the animation shows.
    var appleName: String {
        switch self {
        case .earbuds: return "AirPods"
        case .headphones: return "AirPods Max"
        case .phone: return "iPhone"
        case .tablet: return "iPad"
        case .laptop: return "MacBook"
        case .desktop: return "iMac"
        case .watch: return "Apple Watch"
        case .speaker: return "HomePod"
        case .keyboard: return "Magic Keyboard"
        case .mouse: return "Magic Mouse"
        }
    }
}

enum BluetoothPalette {
    /// Somewhat darker shades of green and red.
    static let connected = Color(red: 0.11, green: 0.64, blue: 0.28)
    static let disconnected = Color(red: 0.78, green: 0.14, blue: 0.16)
}

// MARK: - Input-device lookup

/// What the system's registry says about the keyboards, mice and game pads that are connected.
/// Reads the registry only, so it needs no permission.
enum HIDRegistry {
    struct Node {
        let product: String
        let bluetooth: Bool
        /// The device's main purpose when it is on the Generic Desktop page (1 pointer, 2 mouse, 4 joystick,
        /// 5 game pad, 6 keyboard, 7 keypad).
        let primary: Int?
        /// Every Generic Desktop purpose it offers.
        let desktop: Set<Int>
        /// Its Bluetooth address (12 lower-case hex digits) when the registry shows one.
        let address: String?
    }

    /// "AA-BB-CC-DD-EE-FF", "aa:bb:cc:dd:ee:ff" and "aabbccddeeff" are all the same address.
    static func normalizedAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = raw.lowercased().filter { $0.isHexDigit }
        return hex.count == 12 ? hex : nil
    }

    static func read(_ entry: io_registry_entry_t) -> Node? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any],
              let product = props["Product"] as? String, !product.isEmpty else { return nil }
        let transport = ((props["Transport"] as? String) ?? "").lowercased()
        // Unbranded low-energy mice often name their transport differently (or not at all): a Bluetooth address
        // or the Bluetooth SIG vendor source gives them away just as well.
        let viaBluetooth = transport.contains("bluetooth")
            || props["DeviceAddress"] != nil
            || props["BluetoothDevice"] != nil
            || (props["VendorIDSource"] as? Int) == 1
        var desktop = Set<Int>()
        var primary: Int?
        if let page = props["PrimaryUsagePage"] as? Int, let usage = props["PrimaryUsage"] as? Int, page == 1 {
            desktop.insert(usage)
            primary = usage
        }
        if let pairs = props["DeviceUsagePairs"] as? [[String: Any]] {
            for pair in pairs {
                if let page = pair["DeviceUsagePage"] as? Int, page == 1, let usage = pair["DeviceUsage"] as? Int {
                    desktop.insert(usage)
                }
            }
        }
        let address = normalizedAddress(props["DeviceAddress"] as? String) ?? normalizedAddress(props["SerialNumber"] as? String)
        return Node(product: product, bluetooth: viaBluetooth, primary: primary, desktop: desktop, address: address)
    }

    static func nodes() -> [Node] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var out: [Node] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let node = read(entry) { out.append(node) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return out
    }

    /// Mouse, keyboard or nil, from every part (interface) one physical device shows to the system.
    static func kind(of parts: [Node], name: String) -> BluetoothKind? {
        let desktop = parts.reduce(into: Set<Int>()) { $0.formUnion($1.desktop) }
        let primaries = Set(parts.compactMap { $0.primary })
        let mouse = primaries.contains(2) || primaries.contains(1)
        let keyboard = primaries.contains(6) || primaries.contains(7)
        if mouse && keyboard {
            // Mice often carry a keyboard part for extra buttons and keyboards a pointer part: the name decides.
            let lower = name.lowercased()
            let words = ["keyboard", "keys", "keychron", "typing", "keypad"]
            return words.contains(where: { lower.contains($0) }) ? .keyboard : .mouse
        }
        if mouse { return .mouse }
        if keyboard { return .keyboard }
        if desktop.contains(2) || desktop.contains(1) { return .mouse }
        if desktop.contains(6) || desktop.contains(7) { return .keyboard }
        if desktop.contains(4) || desktop.contains(5) { return .mouse }
        return nil
    }
}

/// Asks the system what an input device really is (mouse, keyboard, game pad), whatever its brand or name.
enum HIDKindLookup {
    /// By Bluetooth address first (exact, whatever the device is called), then by name.
    static func kind(address: String?, name: String) -> BluetoothKind? {
        if let wanted = HIDRegistry.normalizedAddress(address) {
            let parts = HIDRegistry.nodes().filter { $0.address == wanted }
            if !parts.isEmpty, let kind = HIDRegistry.kind(of: parts, name: name) { return kind }
        }
        return kind(named: name)
    }

    static func kind(named name: String) -> BluetoothKind? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard wanted.count >= 3 else { return nil }
        let parts = HIDRegistry.nodes().filter { node in
            let product = node.product.lowercased()
            return product == wanted
                || (wanted.count >= 5 && product.count >= 5 && (product.contains(wanted) || wanted.contains(product)))
        }
        guard !parts.isEmpty else { return nil }
        return HIDRegistry.kind(of: parts, name: name)
    }
}

/// Sees Bluetooth mice, keyboards and game pads the moment they connect or disconnect, whatever their brand, over
/// classic Bluetooth and Bluetooth Low Energy alike (the Bluetooth framework only reports the classic ones).
/// It listens to the system's device registry, so it needs no permission.
/// The registry is read on a background queue (a scan walks every HID device); everything else runs on the main run loop.
final class HIDBluetoothWatcher {
    private let onChange: (String, BluetoothKind, Bool) -> Void
    private let scanQueue = DispatchQueue(label: "indra.hid.scan", qos: .utility)
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var online: Set<String> = []
    /// v495: how many scans in a row a device has been missing from the registry (see `apply`).
    private var absent: [String: Int] = [:]
    private var known: [String: (name: String, kind: BluetoothKind)] = [:]
    private var scanItem: DispatchWorkItem?
    private var timer: Timer?
    private var running = false

    init(onChange: @escaping (String, BluetoothKind, Bool) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard !running, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        running = true
        self.port = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<HIDBluetoothWatcher>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, news: true)
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
                                         callback, me, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOHIDDevice"),
                                         callback, me, &removedIterator)
        // What is connected right now is not news; emptying the iterators arms the notifications.
        scan(announce: false)
        drain(addedIterator, news: false)
        drain(removedIterator, news: false)
        // A slow safety net in case the system skips a notification.
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            self?.scan(announce: true)
        }
        timer?.tolerance = 2   // v507: was every 3 s with no slack
    }

    /// Stops listening and lets go of everything the system handed out (the callbacks hold an unretained pointer to
    /// this object, so none of them may outlive it).
    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        scanItem?.cancel()
        scanItem = nil
        if let port {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            IONotificationPortDestroy(port)
        }
        port = nil
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
    }

    fileprivate func drain(_ iterator: io_iterator_t, news: Bool) {
        var service = IOIteratorNext(iterator)
        var any = false
        while service != 0 {
            any = true
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        guard news, any, running else { return }
        // A device shows up as several parts, a moment apart: look once they have all arrived.
        scanItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scan(announce: true) }
        scanItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// Reads the registry off the main thread, then compares with what was there before back on the main one.
    private func scan(announce: Bool) {
        scanQueue.async { [weak self] in
            let nodes = HIDRegistry.nodes().filter { $0.bluetooth }
            DispatchQueue.main.async { self?.apply(nodes, announce: announce) }
        }
    }

    private func apply(_ nodes: [HIDRegistry.Node], announce: Bool) {
        guard running else { return }
        var groups: [String: [HIDRegistry.Node]] = [:]
        for node in nodes {
            groups[node.product.lowercased(), default: []].append(node)
        }
        for (key, parts) in groups {
            guard let kind = HIDRegistry.kind(of: parts, name: parts[0].product) else { continue }
            known[key] = (parts[0].product, kind)
        }
        let now = Set(groups.keys.filter { known[$0] != nil })
        let arrived = now.subtracting(online)
        // v495: a device that is missing from ONE read of the registry is not reported as gone: the registry can be caught
        // between removing and re-adding its entries, which showed a disconnect card and a connect card for a device that
        // never moved. It has to be missing from two reads in a row (the second is taken a second later, so a real
        // disconnect is still shown promptly).
        let missing = online.subtracting(now)
        var left: Set<String> = []
        if announce {
            for key in missing {
                absent[key, default: 0] += 1
                if absent[key, default: 0] >= 2 { left.insert(key) }
            }
        }
        absent = absent.filter { missing.contains($0.key) && !left.contains($0.key) }
        online = now.union(missing.subtracting(left))
        if !announce { online = now; absent = [:] }
        guard announce else { return }
        if !absent.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.scan(announce: true) }
        }
        for key in arrived { if let info = known[key] { onChange(info.name, info.kind, true) } }
        for key in left { if let info = known[key] { onChange(info.name, info.kind, false) } }
    }
}

// MARK: - Remembered devices

struct BluetoothSeenDevice: Identifiable {
    let name: String
    var kind: BluetoothKind
    var id: String { name }
}

/// The devices Indra has shown, and the product the user picked by hand for a device that was drawn wrong
/// (Settings > Bluetooth > Your devices). A picked product always wins over the automatic guess.
enum BluetoothMemory {
    private static let seenKey = "bluetoothSeenDevices"
    private static let overridesKey = "bluetoothKindOverrides"

    private static func read(_ key: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    private static func id(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    static func override(for name: String) -> BluetoothKind? {
        let key = id(name)
        guard !key.isEmpty, let raw = read(overridesKey)[key] else { return nil }
        return BluetoothKind(rawValue: raw)
    }

    static func setOverride(_ kind: BluetoothKind, for name: String) {
        let key = id(name)
        guard !key.isEmpty else { return }
        var all = read(overridesKey)
        all[key] = kind.rawValue
        UserDefaults.standard.set(all, forKey: overridesKey)
        remember(name, kind)
    }

    static func remember(_ name: String, _ kind: BluetoothKind) {
        let shown = name.trimmingCharacters(in: .whitespaces)
        guard !shown.isEmpty else { return }
        var seen = read(seenKey)
        if seen[shown] == kind.rawValue { return }
        seen[shown] = kind.rawValue
        while seen.count > 40, let first = seen.keys.first(where: { $0 != shown }) { seen[first] = nil }
        UserDefaults.standard.set(seen, forKey: seenKey)
    }

    static func seen() -> [BluetoothSeenDevice] {
        read(seenKey)
            .compactMap { entry -> BluetoothSeenDevice? in
                guard let kind = BluetoothKind(rawValue: entry.value) else { return nil }
                return BluetoothSeenDevice(name: entry.key, kind: override(for: entry.key) ?? kind)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension BluetoothMemory {
    /// Every paired device (also one paired a moment ago, connected or not), each with the product it is drawn
    /// as, together with the devices Indra has shown before.
    @MainActor
    static func all() -> [BluetoothSeenDevice] {
        var byName: [String: BluetoothSeenDevice] = [:]
        for device in seen() { byName[device.name] = device }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired {
            let name = (device.name ?? device.nameOrAddress ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, byName[name] == nil else { continue }
            let kind = override(for: name) ?? BluetoothMonitor.classify(device).kind
            byName[name] = BluetoothSeenDevice(name: name, kind: kind)
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Monitor

/// Event-driven: reports when a Bluetooth earbud, headphone, phone, laptop, speaker, watch... connects or disconnects.
@MainActor
final class BluetoothMonitor: NSObject {
    private let onEvent: (BluetoothKind, String, Bool) -> Void
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var lastEvent: [String: Date] = [:]
    private var startedAt = Date()
    /// Devices currently connected, by address. A 2 s check against this catches any change the system's
    /// own notifications miss, so a connect or disconnect is never lost.
    private var known: [String: IOBluetoothDevice] = [:]
    private var pollTimer: Timer?
    private var hidWatcher: HIDBluetoothWatcher?
    private var lastByName: [String: Date] = [:]
    /// What each connected device was shown as, so its disconnect card is the same product (by then the device
    /// registry no longer knows it, and a guess would turn a mouse into a phone).
    private var shownKind: [String: BluetoothKind] = [:]
    /// Connected devices still being identified.
    private var pendingResolve: Set<String> = []
    private var lastInputConnect: Date?

    init(onEvent: @escaping (BluetoothKind, String, Bool) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
        // Devices that are already connected: only watch for their disconnect.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired where device.isConnected() {
            watch(device)
            known[key(device)] = device
            shownKind[key(device)] = BluetoothMonitor.classify(device).kind
        }
        pollTimer?.invalidate()
        // v507: every 4 s with slack (was every 2 s). Each pass asks the Bluetooth daemon for every paired device.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        pollTimer?.tolerance = 1.5
        // Mice, keyboards and game pads of any brand, including low-energy ones the Bluetooth framework never reports.
        let watcher = HIDBluetoothWatcher { [weak self] name, kind, connected in
            Task { @MainActor [weak self] in self?.emit(kind, name: name, connected: connected) }
        }
        hidWatcher = watcher
        watcher.start()
    }

    /// Shows a connect / disconnect, once even when two sources report the same device.
    private func emit(_ detected: BluetoothKind, name: String, connected: Bool) {
        // A product the user picked for this device wins over any guess.
        let kind = BluetoothMemory.override(for: name) ?? detected
        BluetoothMemory.remember(name, kind)
        guard Preferences.liveBluetooth,
              connected || Preferences.bluetoothDisconnect,
              Date().timeIntervalSince(startedAt) > 2,
              kind.isAudioWearable || Preferences.bluetoothOtherDevices else { return }
        let sign = connected ? "+" : "-"
        let id = name.lowercased() + sign
        if let last = lastByName[id], Date().timeIntervalSince(last) < 6 { return }
        // The Bluetooth framework and the device registry can know the same mouse or keyboard by slightly different names.
        let kindId = "kind:" + kind.rawValue + sign
        if kind == .mouse || kind == .keyboard, let last = lastByName[kindId], Date().timeIntervalSince(last) < 4 { return }
        lastByName[id] = Date()
        lastByName[kindId] = Date()
        if connected && (kind == .mouse || kind == .keyboard) { lastInputConnect = Date() }
        onEvent(kind, name, connected)
    }

    private func poll() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var now: Set<String> = []
        for device in paired where device.isConnected() {
            let id = key(device)
            now.insert(id)
            if known[id] == nil {
                known[id] = device
                watch(device)
                report(device, connected: true)
            }
        }
        for (id, device) in known where !now.contains(id) {
            known[id] = nil
            disconnectNotes[id]?.unregister()
            disconnectNotes[id] = nil
            report(device, connected: false)
        }
    }

    private func key(_ device: IOBluetoothDevice) -> String {
        device.addressString ?? device.name ?? "unknown"
    }

    private func watch(_ device: IOBluetoothDevice) {
        let id = key(device)
        guard disconnectNotes[id] == nil else { return }
        disconnectNotes[id] = device.register(forDisconnectNotification: self,
                                              selector: #selector(deviceDisconnected(_:device:)))
    }

    // The Bluetooth framework calls these from whichever thread it likes. They are not tied to the main actor
    // (a main-actor method called from another thread stops the app on the spot); each one only hands the
    // device over to the main actor, where the real work happens a moment later.
    @objc nonisolated private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Task { @MainActor [weak self] in self?.handleConnected(device) }
    }

    @objc nonisolated private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Task { @MainActor [weak self] in self?.handleDisconnected(device) }
    }

    private func handleConnected(_ device: IOBluetoothDevice) {
        watch(device)
        known[key(device)] = device
        report(device, connected: true)
    }

    private func handleDisconnected(_ device: IOBluetoothDevice) {
        let id = key(device)
        disconnectNotes[id]?.unregister()
        disconnectNotes[id] = nil
        known[id] = nil
        report(device, connected: false)
    }

    private func displayName(_ device: IOBluetoothDevice) -> String {
        // Some devices have no name at all: the address then stands in, so the card still shows.
        (device.name ?? device.nameOrAddress ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func report(_ device: IOBluetoothDevice, connected: Bool) {
        let id = key(device)
        // The system can report the same change twice in a row.
        let stamp = id + (connected ? "+" : "-")
        if let last = lastEvent[stamp], Date().timeIntervalSince(last) < 3 { return }
        lastEvent[stamp] = Date()
        if connected {
            pendingResolve.insert(id)
            resolve(device, attempt: 0)
        } else {
            let wasPending = pendingResolve.remove(id) != nil
            let kind = shownKind[id]
            shownKind[id] = nil
            // Gone again before it was ever shown: nothing to take back.
            if wasPending && kind == nil { return }
            emit(kind ?? BluetoothMonitor.classify(device).kind, name: displayName(device), connected: false)
        }
    }

    /// Works out what a newly connected device is. A mouse or keyboard that has no name worth reading and no device
    /// class only shows up in the system's device registry a moment after it connects, so when nothing but a guess
    /// is available the device is looked at again (up to three more times, a second apart) before the card is shown.
    private func resolve(_ device: IOBluetoothDevice, attempt: Int) {
        let id = key(device)
        guard pendingResolve.contains(id), known[id] != nil else {
            pendingResolve.remove(id)
            return
        }
        let result = BluetoothMonitor.classify(device)
        if !result.confident && attempt < 3 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.resolve(device, attempt: attempt + 1)
            }
            return
        }
        pendingResolve.remove(id)
        // The registry has just announced a mouse or keyboard and it got its card: a guess must not add a second one.
        if !result.confident, let last = lastInputConnect, Date().timeIntervalSince(last) < 8 { return }
        shownKind[id] = result.kind
        emit(result.kind, name: displayName(device), connected: true)
    }

    /// What the device is: a product picked by hand first, then its name, its Bluetooth device class and the
    /// system's device registry. `confident` is false only when nothing but a guess is left.
    static func classify(_ device: IOBluetoothDevice) -> (kind: BluetoothKind, confident: Bool) {
        let name = (device.name ?? "").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }

        if let picked = BluetoothMemory.override(for: device.name ?? device.nameOrAddress ?? "") { return (picked, true) }

        // Earbuds whose names contain a headphone model word (Sony WF-1000XM5, Powerbeats Pro).
        if has(["wf-1000", "wf-c", "powerbeats"]) { return (.earbuds, true) }

        // Audio worn on the head. A device that reports itself as headphones (class 4, minor 6) is one
        // even when its name sounds like earbuds.
        if has(["airpods max", "headphone", "headset", "over-ear", "over ear", "on-ear", "wh-", "mdr-", "xm3", "xm4", "xm5", "xm6",
                "quietcomfort", "qc35", "qc45", "qc ultra", "bose nc", "nc 700", "beats studio", "beats solo", "beats pro", "momentum",
                "px7", "px8", "sennheiser", "rockerz", "life q", "space one", "hesh", "crusher", "arctis", "kraken", "barracuda",
                "hd 4", "hd 5", "hd 6", "hd 8", "major iv", "major v", "monitor ii", "bluedio", "anc headphone"]) { return (.headphones, true) }
        if Int(device.deviceClassMajor) == 4 && Int(device.deviceClassMinor) == 6 { return (.headphones, true) }
        if has(["airpods", "buds", "earbud", "earphone", "pods", "powerbeats", "tws", "wf-1000", "wf-c",
                "airdopes", "neckband", "jabra elite", "liberty", "nothing ear", "ear (", "freeclip"]) { return (.earbuds, true) }

        // Things on the wrist.
        if has(["watch", "mi band", "smart band", "redmi band", "honor band", "huawei band", "amazfit",
                "garmin", "fenix", "forerunner", "fitbit", "galaxy fit"]) { return (.watch, true) }

        // A device that says it is an input device (class 5) is one, whatever it is called.
        // Bit 4 of the minor class is "keyboard", bit 5 "pointing device".
        if Int(device.deviceClassMajor) == 5 {
            let minor = Int(device.deviceClassMinor)
            let keyboardBit = minor & 0x10 != 0, pointerBit = minor & 0x20 != 0
            if keyboardBit && pointerBit { return (has(["mouse", "mice", "trackpad"]) ? .mouse : .keyboard, true) }
            return (keyboardBit ? .keyboard : .mouse, true)   // pointing devices, game pads and the rest
        }

        // Whatever its brand or name, ask the system whether it is a mouse or a keyboard (by address, then by name).
        if let input = HIDKindLookup.kind(address: device.addressString, name: device.name ?? "") { return (input, true) }

        // Input devices.
        if has(["keyboard", "keychron", "mx keys", "k380", "k480", "k780"]) { return (.keyboard, true) }
        if has(["mouse", "mice", "trackpad", "trackball", "mx master", "mx anywhere", "m720", "m590"]) { return (.mouse, true) }

        // Speakers.
        if has(["homepod", "speaker", "soundbar", "soundlink", "boombox", "megaboom", "wonderboom", "partybox",
                "jbl flip", "jbl charge", "jbl go", "jbl clip", "jbl xtreme", "revolve", "echo", "sonos",
                "marshall", "stanmore", "emberton", "woburn", "acton", "kilburn", "soundcore", "ultimate ears",
                "srs-", "beats pill", "tribit", "stormbox", "harman", "kardon", "portronics", "zebronics"]) { return (.speaker, true) }

        // Computers and tablets.
        if has(["ipad", "galaxy tab", "tablet", "matepad", "xiaomi pad", "redmi pad", "mi pad", "oneplus pad"]) { return (.tablet, true) }
        if has(["imac", "mac mini", "mac studio", "mac pro", "desktop", "optiplex", "all-in-one"]) { return (.desktop, true) }
        if has(["macbook", "laptop", "notebook", "thinkpad", "surface", "xps", "zenbook", "vivobook", "ideapad",
                "inspiron", "latitude", "pavilion", "spectre", "chromebook", "pixelbook", "matebook", "galaxy book",
                "legion", "elitebook", "probook"])
            || name == "mac" || name.hasSuffix(" mac") || name.contains(" mac ") { return (.laptop, true) }

        // Phones.
        if has(["iphone", "phone", "galaxy s", "galaxy a", "galaxy z", "galaxy m", "galaxy f", "galaxy note",
                "pixel", "oneplus", "redmi", "xiaomi", "poco", "realme", "oppo", "vivo", "iqoo", "motorola",
                "moto g", "moto e", "xperia", "infinix", "tecno", "itel", "sm-"]) { return (.phone, true) }

        // Fall back to the device class. Every device gets an animation, so nothing here is left out.
        let major = Int(device.deviceClassMajor)
        let minor = Int(device.deviceClassMinor)
        switch major {
        case 1:  // computer
            switch minor {
            case 1, 2: return (.desktop, true)
            case 4, 5, 7: return (.tablet, true)
            case 6: return (.watch, true)
            default: return (.laptop, true)
            }
        case 2:  // phone
            return (.phone, true)
        case 4:  // audio / video
            switch minor {
            case 1, 2: return (.earbuds, true)
            case 6: return (.headphones, true)
            default: return (.speaker, true)
            }
        case 7, 9:  // wearable, health
            return (.watch, true)
        case 3, 6:  // networking, imaging
            return (.desktop, false)
        default:
            // A brand-new or unlabelled device (many low-energy gadgets report no class at all). It may be a mouse
            // the registry has not listed yet, so this is only a guess; the caller looks again before using it.
            return (.phone, false)
        }
    }
}

// MARK: - Views

/// Animated picture shown where the album artwork normally sits.
/// Earbuds: "airpods" or "pro". Every other kind has one rotating Apple device animation.
struct BluetoothGlyph: View {
    let kind: BluetoothKind
    let style: String
    let size: CGFloat
    @AppStorage(Preferences.bluetooth3DKey) private var use3D = true
    @State private var appeared = false

    private var resource: String {
        switch kind {
        case .headphones: return "BluetoothHeadphones"
        case .earbuds: return style == "pro" ? "BluetoothEarbuds2" : "BluetoothEarbuds1"
        case .phone: return "BluetoothIPhone"
        case .tablet: return "BluetoothIPad"
        case .laptop: return "BluetoothMacBook"
        case .desktop: return "BluetoothIMac"
        case .watch: return "BluetoothWatch"
        case .speaker: return "BluetoothHomePod"
        case .keyboard: return "BluetoothKeyboard"
        case .mouse: return "BluetoothMouse"
        }
    }

    private var fallbackSymbol: String {
        switch kind {
        case .headphones: return "airpodsmax"
        case .earbuds: return style == "pro" ? "airpodspro" : "airpods"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .watch: return "applewatch"
        case .speaker: return "homepod"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        }
    }

    var body: some View {
        Group {
            if kind.isAudioWearable || !use3D {
                if GIFLayerView.exists(resource) {
                    GIFView(name: resource)
                } else {
                    // v422: the animation is missing from the app: a plain symbol instead of an empty space.
                    Image(systemName: fallbackSymbol)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(size * 0.14)
                }
            } else if kind.has3DModel {
                DeviceSceneView(kind: kind)
            } else {
                SmoothSpriteView(name: resource + "Sheet")
            }
        }
        .id(resource)
        .frame(width: size, height: size)
        // The AirPods Max fill their whole picture, so they are drawn a little smaller and lower.
        .scaleEffect(kind == .headphones ? 0.92 : 1, anchor: .bottom)
        .offset(y: kind == .headphones ? size * 0.02 : 0)
        .clipped()
        .scaleEffect(appeared ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { appeared = true }
        }
    }
}

/// Smooth 60 fps playback of a rotating device.
/// The sheet holds 360 pre-blended frames (20 columns x 18 rows of 96 px). They are decoded once,
/// then Core Animation steps through them on the render server, so the main thread never touches playback.
private struct SmoothSpriteView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> SpriteNSView { SpriteNSView(name: name) }
    func updateNSView(_ view: SpriteNSView, context: Context) { view.play() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpriteNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 26, height: proposal.height ?? 26)
    }
}

private final class SpriteNSView: NSView {
    private static var cache: [String: [CGImage]] = [:]
    private static let columns = 20
    private static let cell = 96
    private static let duration: CFTimeInterval = DeviceSpin.seconds

    private let name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
        layer?.isOpaque = false
        let frames = Self.frames(named: name)
        layer?.contents = frames.first
        play()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        play()
    }

    /// (Re)starts the loop; harmless to call again while it is already running.
    func play() {
        guard let layer, layer.animation(forKey: "spin") == nil else { return }
        let frames = Self.frames(named: name)
        guard frames.count > 1 else { return }
        let spin = CAKeyframeAnimation(keyPath: "contents")
        spin.values = frames
        spin.calculationMode = .discrete
        spin.duration = Self.duration
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        layer.add(spin, forKey: "spin")
    }

    private static func frames(named name: String) -> [CGImage] {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let rows = sheet.height / cell
        var out: [CGImage] = []
        out.reserveCapacity(rows * columns)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        for r in 0..<rows {
            for c in 0..<columns {
                let rect = CGRect(x: c * cell, y: r * cell, width: cell, height: cell)
                guard let piece = sheet.cropping(to: rect),
                      let ctx = CGContext(data: nil, width: cell, height: cell, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.draw(piece, in: CGRect(x: 0, y: 0, width: cell, height: cell))
                if let image = ctx.makeImage() { out.append(image) }
            }
        }
        cache[name] = out
        return out
    }
}

/// Plays a GIF from the app bundle (earbuds and headphones).
/// v422: the frames are read and played by Indra itself (ImageIO + a Core Animation loop, like the sprite sheets next to it).
/// It used to hand the file to NSImageView, whose own GIF playing can silently show nothing, with no way to tell why.
private struct GIFView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> GIFLayerView { GIFLayerView(name: name) }

    func updateNSView(_ view: GIFLayerView, context: Context) { view.play() }

    /// Take exactly the size SwiftUI offers (the image itself is larger than the notch slot).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GIFLayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 26, height: proposal.height ?? 26)
    }
}

private final class GIFLayerView: NSView {
    private struct Clip {
        let frames: [CGImage]
        let duration: CFTimeInterval
    }

    private static var cache: [String: Clip] = [:]
    /// v523: the clips in the order they were last used. Each is 120 decoded frames (about 4 MB), and there are eleven
    /// devices: all of them kept for good was up to 48 MB. Only the two latest are kept (a playing view holds its own frames).
    private static var recent: [String] = []
    private static func touch(_ name: String) {
        recent.removeAll { $0 == name }
        recent.append(name)
        while recent.count > 2 { cache[recent.removeFirst()] = nil }
    }
    private static var reportedMissing = Set<String>()

    /// Whether the GIF is in the app at all.
    static func exists(_ name: String) -> Bool {
        let found = Bundle.main.url(forResource: name, withExtension: "gif") != nil
        if !found, !reportedMissing.contains(name) {
            reportedMissing.insert(name)
            Trace.log("RESOURCE \(name).gif is missing from the app bundle (Resources folder: \(Bundle.main.resourcePath ?? "?"))")
        }
        return found
    }

    private let name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
        layer?.isOpaque = false
        layer?.contents = Self.clip(named: name)?.frames.first
        play()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        play()
    }

    /// (Re)starts the loop; harmless to call again while it is already running.
    func play() {
        guard let layer, layer.animation(forKey: "gif") == nil,
              let clip = Self.clip(named: name), clip.frames.count > 1 else { return }
        let loop = CAKeyframeAnimation(keyPath: "contents")
        loop.values = clip.frames
        loop.calculationMode = .discrete
        loop.duration = clip.duration
        loop.repeatCount = .infinity
        loop.isRemovedOnCompletion = false
        layer.add(loop, forKey: "gif")
    }

    private static func clip(named name: String) -> Clip? {
        if let cached = cache[name] { touch(name); return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var frames: [CGImage] = []
        var total: CFTimeInterval = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(image)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            var delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.05
            if delay < 0.011 { delay = 0.1 }
            total += delay
        }
        guard !frames.isEmpty else {
            Trace.log("RESOURCE \(name).gif could not be read")
            return nil
        }
        let result = Clip(frames: frames, duration: max(total, 0.1))
        cache[name] = result
        touch(name)
        return result
    }
}

/// Green dot when a device connected, red dot when it disconnected (in place of the visualizer).
/// It pops in, flickers once with a ring rippling out of it, then stays as a plain dot.
struct BluetoothDot: View {
    let connected: Bool
    @State private var appeared = false
    @State private var ring = false
    @State private var flick = false

    private var color: Color { connected ? BluetoothPalette.connected : BluetoothPalette.disconnected }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.7), lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .scaleEffect(ring ? 2.6 : 1)
                .opacity(ring ? 0 : 0.8)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(flick ? 0.95 : 0.7), radius: flick ? 5 : 3)
                .scaleEffect(appeared ? (flick ? 1.3 : 1) : 0.2)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { appeared = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.1)) { ring = true }
            withAnimation(.easeOut(duration: 0.16).delay(0.3)) { flick = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { flick = false }
            }
        }
    }
}

/// The device's name, centred in the strip that hangs below the notch while a Bluetooth card shows.
struct BluetoothNameDownline: View {
    let name: String
    let notchHeight: CGFloat
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 4)
                .offset(y: shown ? 0 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { withAnimation(.easeOut(duration: 0.55).delay(0.2)) { shown = true } }
    }
}
