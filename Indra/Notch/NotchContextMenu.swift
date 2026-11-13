import AppKit

/// Right-click menu on the notch: version, Settings…, Quit.
@MainActor
final class NotchContextMenu: NSObject, NSMenuDelegate {
    private let openSettings: () -> Void
    private let onOpen: () -> Void
    private let onClose: () -> Void

    init(openSettings: @escaping () -> Void, onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.openSettings = openSettings
        self.onOpen = onOpen
        self.onClose = onClose
        super.init()
    }

    func makeMenu() -> NSMenu {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let versionItem = NSMenuItem(title: "Version \(version) (\(build))", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Indra", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func settingsAction() {
        openSettings()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        onOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        onClose()
    }
}
