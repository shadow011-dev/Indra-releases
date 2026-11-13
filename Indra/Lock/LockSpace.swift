import AppKit

/// A dedicated window-server Space for the lock screen player, written from scratch.
///
/// The lock screen is drawn by a separate system process, so an ordinary window never shows there.
/// A private Space at a moderate absolute level (400), created and shown by Indra, is above it.
/// The very large level used by the notch's all-desktops Space is not accepted on the lock screen.
/// The functions are looked up at runtime; if any is missing, `init` returns nil.
@MainActor
final class LockSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias MoveWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    private let connection: Int32
    private let space: UInt64
    private let setLevel: SetLevel
    private let show: ShowSpaces
    private let move: MoveWindows
    private static let level: Int32 = 400

    init?() {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        func lookup(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(handle, "SLS" + name) ?? dlsym(handle, "CGS" + name)
        }
        guard let mainSymbol = lookup("MainConnectionID"),
              let createSymbol = lookup("SpaceCreate"),
              let levelSymbol = lookup("SpaceSetAbsoluteLevel"),
              let showSymbol = lookup("ShowSpaces"),
              let moveSymbol = lookup("SpaceAddWindowsAndRemoveFromSpaces") else { return nil }

        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnection.self)
        let create = unsafeBitCast(createSymbol, to: SpaceCreate.self)
        let connection = mainConnection()
        let space = create(connection, 1, 0)
        guard space != 0 else { return nil }
        self.connection = connection
        self.space = space
        self.setLevel = unsafeBitCast(levelSymbol, to: SetLevel.self)
        self.show = unsafeBitCast(showSymbol, to: ShowSpaces.self)
        self.move = unsafeBitCast(moveSymbol, to: MoveWindows.self)
        refresh()
    }

    func refresh() {
        _ = setLevel(connection, space, LockSpace.level)
        show(connection, [NSNumber(value: space)] as CFArray)
    }

    /// Moves the window into this Space and out of every other one.
    func delegate(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        move(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }
}
