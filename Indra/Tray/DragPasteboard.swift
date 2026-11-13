import AppKit

/// v563: macOS 27 keeps a running app's copy of the drag pasteboard (its change count and what it holds) as it was while a file is
/// being dragged from Finder, so every drag looked like "no file": the drop zones never opened, the pointer reached the menu bar,
/// and Mission Control started instead. Asking the system's Pasteboard Manager to synchronise first (what other notch apps do on
/// macOS 27) makes the count current again.
///
/// The two Pasteboard Manager functions are looked up by name at run time instead of being linked, so nothing here can stop the
/// app from building or starting on another macOS version: when they are not found, nothing happens and the count is read as before.
@MainActor
enum DragPasteboard {
    private typealias CreateFunction = @convention(c) (CFString?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias SynchronizeFunction = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

    private static let create: CreateFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "PasteboardCreate") else { return nil }
        return unsafeBitCast(symbol, to: CreateFunction.self)
    }()

    private static let synchronizeBoard: SynchronizeFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "PasteboardSynchronize") else { return nil }
        return unsafeBitCast(symbol, to: SynchronizeFunction.self)
    }()

    private typealias ReleaseFunction = @convention(c) (UnsafeRawPointer?) -> Void

    /// CFRelease is marked unavailable to Swift, so it is looked up by name like the two functions above.
    private static let releaseBoard: ReleaseFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CFRelease") else { return nil }
        return unsafeBitCast(symbol, to: ReleaseFunction.self)
    }()

    private static var lastSync = Date.distantPast

    /// The drag pasteboard's change count, current.
    static func changeCount() -> Int {
        synchronize()
        return NSPasteboard(name: .drag).changeCount
    }

    /// At most once every 40 ms: a drag reports its position far more often than that.
    static func synchronize() {
        let now = Date()
        guard now.timeIntervalSince(lastSync) > 0.04 else { return }
        lastSync = now
        guard let create, let synchronizeBoard else { return }
        var created: UnsafeMutableRawPointer?
        guard create(NSPasteboard.Name.drag.rawValue as CFString, &created) == 0, let board = created else { return }
        _ = synchronizeBoard(board)
        releaseBoard?(UnsafeRawPointer(board))
    }
}
