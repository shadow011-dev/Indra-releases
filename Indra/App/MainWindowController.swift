import AppKit
import SwiftUI

/// The full app page (sidebar + settings pages). The menu-bar quick settings stay available too.
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: MainWindowView())
            let w = NSWindow(contentViewController: controller)
            w.title = AppBrand.name
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            // v478: closing the window sends the app back to General, so the next opening starts there.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NotificationCenter.default.post(name: .indraMainWindowClosed, object: nil)
            }
            // v491: the default window is 860 x 840 (the size the user settled on).
            w.setContentSize(NSSize(width: 860, height: 840))
            w.center()
            window = w
        }
        let wasVisible = window?.isVisible ?? false
        if !wasVisible { window?.alphaValue = 0 }
        // Opens like an app: Indra becomes the app in front and the one that was in front goes out of focus.
        if let w = window { AppPresence.bringToFront(w) }
        if !wasVisible, let w = window {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
        }
    }
}

extension Notification.Name {
    /// v478: the main window was closed.
    static let indraMainWindowClosed = Notification.Name("indraMainWindowClosed")
}

/// Frosted window background.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
