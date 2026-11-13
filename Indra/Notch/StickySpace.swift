import AppKit

/// Puts the notch windows into a private, top-level Space.
///
/// Windows in that Space are not part of any desktop, so they stay exactly where they are
/// while you swipe between desktops or fullscreen apps (and can show over the lock screen).
///
/// macOS has no documented API for this. The window-server functions are looked up at
/// runtime and every step is checked; if anything is missing, `init` returns nil and the
/// windows simply behave like normal "all desktops" windows.
@MainActor
final class StickySpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias WindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void

    private let connection: Int32
    private let space: UInt64
    private let setLevelCall: SetLevel
    private let showCall: ShowSpaces
    private let addWindows: WindowsToSpaces
    private let removeWindows: WindowsToSpaces
    private let copySpaces: CopySpaces?
    /// v504: a Space created here lives in the window server until it is destroyed. Every external-monitor island that was
    /// created and dropped again left one behind (a top-level, visible Space at the highest level), for the rest of the session.
    private let destroyCall: SpaceDestroy?
    private var destroyed = false

    init?() {
        // Newer macOS versions expose the same functions under an SLS prefix.
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        func lookup(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(handle, "CGS" + name) ?? dlsym(handle, "SLS" + name)
        }
        guard let mainSymbol = lookup("MainConnectionID"),
              let createSymbol = lookup("SpaceCreate"),
              let levelSymbol = lookup("SpaceSetAbsoluteLevel"),
              let addSymbol = lookup("AddWindowsToSpaces"),
              let removeSymbol = lookup("RemoveWindowsFromSpaces"),
              let showSymbol = lookup("ShowSpaces") else { return nil }

        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnection.self)
        let create = unsafeBitCast(createSymbol, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(levelSymbol, to: SetLevel.self)
        let show = unsafeBitCast(showSymbol, to: ShowSpaces.self)

        let connection = mainConnection()
        // The flag value must be 1, otherwise Finder draws desktop icons into this Space.
        let space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        _ = setLevel(connection, space, Int32.max)
        show(connection, [NSNumber(value: space)] as CFArray)

        self.connection = connection
        self.space = space
        self.setLevelCall = setLevel
        self.showCall = show
        self.addWindows = unsafeBitCast(addSymbol, to: WindowsToSpaces.self)
        self.removeWindows = unsafeBitCast(removeSymbol, to: WindowsToSpaces.self)
        if let destroySymbol = lookup("SpaceDestroy") {
            self.destroyCall = unsafeBitCast(destroySymbol, to: SpaceDestroy.self)
        } else {
            self.destroyCall = nil
        }
        if let copySymbol = lookup("CopySpacesForWindows") {
            self.copySpaces = unsafeBitCast(copySymbol, to: CopySpaces.self)
        } else {
            self.copySpaces = nil
        }
    }

    /// Takes the windows out of every other Space, so they exist only in this one.
    /// Without this a window that also lives on the desktops still slides along with them
    /// when you swipe between desktops. Returns true only if that is verified to be the case.
    func makeExclusive(_ windows: [NSWindow]) -> Bool {
        guard let copySpaces, !windows.isEmpty else { return false }
        for window in windows {
            let number = NSNumber(value: window.windowNumber)
            guard window.windowNumber > 0 else { return false }
            let list = [number] as CFArray
            func current() -> [UInt64]? {
                guard let array = copySpaces(connection, 7, list)?.takeRetainedValue() as? [NSNumber] else { return nil }
                return array.map { $0.uint64Value }
            }
            guard let spaces = current() else { return false }
            let others = spaces.filter { $0 != space }
            if !others.isEmpty {
                removeWindows(connection, list, others.map { NSNumber(value: $0) } as CFArray)
            }
            guard let after = current(), after == [space] else { return false }
        }
        return true
    }

    /// Raises the Space to the top and shows it again (the lock screen can reset the visible Spaces).
    func refresh() {
        FreezeTrail.mark("private space: refresh")
        _ = setLevelCall(connection, space, Int32.max)
        showCall(connection, [NSNumber(value: space)] as CFArray)
    }

    func add(_ windows: [NSWindow]) {
        let numbers = windows.filter { $0.windowNumber > 0 }.map { NSNumber(value: $0.windowNumber) }
        guard !numbers.isEmpty else { return }
        FreezeTrail.mark("private space: adding \(numbers.count) window(s)")
        addWindows(connection, numbers as CFArray, [NSNumber(value: space)] as CFArray)
    }

    func remove(_ windows: [NSWindow]) {
        let numbers = windows.filter { $0.windowNumber > 0 }.map { NSNumber(value: $0.windowNumber) }
        guard !numbers.isEmpty else { return }
        FreezeTrail.mark("private space: removing \(numbers.count) window(s)")
        removeWindows(connection, numbers as CFArray, [NSNumber(value: space)] as CFArray)
    }

    /// v504: gives the Space back to the window server. The windows must already be out of it (or about to be closed).
    /// Safe to call twice; the Space cannot be used afterwards.
    func destroy() {
        guard !destroyed, let destroyCall else { return }
        destroyed = true
        destroyCall(connection, space)
    }
}
