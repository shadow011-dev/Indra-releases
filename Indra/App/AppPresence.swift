import AppKit

/// v393: makes Indra's windows behave like an app, not like a stray window.
///
/// Indra normally lives in the notch as an accessory app (no Dock icon). An accessory app cannot reliably take the
/// keyboard focus from the app in front: `NSApp.activate()` is only a request on macOS 14 and later, so Settings
/// opened from the notch's right-click menu appeared while the other app kept the focus. While one of Indra's
/// windows is open, Indra is therefore a regular app (Dock icon, app switcher, menu bar) and is activated for real,
/// which puts the app that was in front out of focus. When the last window closes it returns to the notch-only mode.
@MainActor
enum AppPresence {
    private static var openWindows = Set<ObjectIdentifier>()
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// True while one of Indra's windows (Settings) is open: nothing may hand the keyboard back to another app.
    static var hasWindow: Bool { !openWindows.isEmpty }

    static func bringToFront(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if closeObservers[id] == nil {
            closeObservers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in AppPresence.closed(id) }
            }
        }
        openWindows.insert(id)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        focus(window)
        // The policy change lands a moment later: once more on the next turn, so the activation sticks.
        DispatchQueue.main.async { focus(window) }
    }

    private static func focus(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func closed(_ id: ObjectIdentifier) {
        if let token = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
        openWindows.remove(id)
        guard openWindows.isEmpty else { return }
        // Back to living in the notch (no Dock icon) once the last window is gone.
        NSApp.setActivationPolicy(.accessory)
    }
}
