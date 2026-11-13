import AppKit

/// v420: pop-ups (the volume / brightness bar, the edge light, the focus line ...) are windows that join every desktop. While
/// the desktops slide past (a three-finger swipe, Control-arrow), the window server is busy compositing the move, and a pop-up
/// that was animating at that moment could freeze half way and then catch up late: it looked stuck and laggy. After every
/// desktop change each registered pop-up that is on screen is brought to the front again and redrawn, at once and once more
/// when the slide has surely finished.
@MainActor
enum SpaceChangeGuard {
    private struct Entry { weak var panel: NSPanel? }
    private static var entries: [Entry] = []
    private static var observer: NSObjectProtocol?

    static func register(_ panel: NSPanel) {
        entries.removeAll { $0.panel == nil }
        if !entries.contains(where: { $0.panel === panel }) { entries.append(Entry(panel: panel)) }
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    SpaceChangeGuard.refresh()
                }
            }
        }
    }

    /// v429: only a pop-up that has really dropped off the screen is brought back; nothing is redrawn synchronously (that
    /// work, repeated during the slide of the desktops, was itself part of the lag).
    private static func refresh() {
        for entry in entries {
            guard let panel = entry.panel, panel.alphaValue > 0.01, !panel.isVisible else { continue }
            panel.orderFrontRegardless()
        }
    }
}
