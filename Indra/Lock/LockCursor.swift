import AppKit

/// v419: after the album photo or the song name on the lock screen player is clicked, the pointer jumps to the right
/// edge of the screen (at the same height), out of the way of the vinyl, the lyrics and the cover row.
enum LockCursor {
    @MainActor
    static func moveToRightEdge() {
        guard Preferences.lockCursorJump else { return }   // v420: can be switched off in Lock Screen settings
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NotchMetrics.notchScreen() ?? NSScreen.main else { return }
        // Cocoa has its origin at the bottom left of the main screen, Quartz at its top left.
        let target = CGPoint(x: screen.frame.maxX - 2, y: primary.frame.maxY - mouse.y)
        CGWarpMouseCursorPosition(target)
        // A warp swallows mouse movement for a moment unless the mouse and the pointer are tied together again.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
