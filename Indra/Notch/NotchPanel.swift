import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// Only the to-do page has a text field. Everywhere else the panel must never become the key window:
    /// a key panel swallows the keystrokes meant for the app the user is working in.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Allow the panel to sit over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that accepts the first click (no "click to focus" step).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI must not register this view for drops: file drops are handled by the container.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

/// Container that reports pointer enter/exit and accepts dropped files.
final class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMove: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    /// Drag position in this view's coordinates, plus the view width.
    var onDragMove: ((NSPoint, CGFloat) -> Void)?
    var onDrop: (([URL]) -> Bool)?
    /// v485: files that are only PROMISED by the sender (Mail, Safari, Photos ...). They are received into a private folder
    /// by the owner of this view; reading them as plain URLs made the system leave a copy on the Desktop.
    var onPromisedDrop: (([NSFilePromiseReceiver], [URL]) -> Bool)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // v490: promised files (Safari, Mail, Photos, screenshots ...) must be accepted by the window too. Without their types
        // the window was no valid target for them, the drop fell through to the Desktop and the sender wrote the file there.
        registerForDraggedTypes(DropFiles.registeredTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseMoved(with event: NSEvent) { onMove?() }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        reportDragLocation(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        reportDragLocation(sender)
        return .copy
    }

    private func reportDragLocation(_ sender: NSDraggingInfo) {
        onDragMove?(convert(sender.draggingLocation, from: nil), bounds.width)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        reportDragLocation(sender)
        let pasteboard = sender.draggingPasteboard
        Trace.log("DROP: a notch window took the drop")
        DesktopCopyGuard.watch(sources: DropFiles.declaredFileURLs(in: pasteboard), since: Date().addingTimeInterval(-5))
        // v490: promised files FIRST. They are received into Indra's own temporary folder, never the Desktop, and nothing
        // may ask the sender for their file URL before that. Real files that come along with them are taken as they are.
        let receivers = DropFiles.promiseReceivers(in: pasteboard)
        let plain = DropFiles.plainFileURLs(in: pasteboard)
        if !receivers.isEmpty, let onPromisedDrop { return onPromisedDrop(receivers, plain) }
        if !plain.isEmpty { return onDrop?(plain) ?? false }
        if DropFiles.hasPromises(in: pasteboard) { return false }
        let legacy = DropFiles.legacyFileURLs(in: pasteboard)
        if !legacy.isEmpty { return onDrop?(legacy) ?? false }
        // v491: a picture dragged out of a web page (no file behind it).
        return onDrop?(DropFiles.imageFiles(in: pasteboard)) ?? false
    }
}
