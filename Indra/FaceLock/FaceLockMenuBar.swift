//
//  FaceLockMenuBar.swift
//  Indra Face Lock
//
//  Indra's menu bar icon. Four items:
//    1. Unlock Session / Lock Session   (Touch ID / Mac password when unlocking)
//    2. Quit Face Lock / Start Face Lock (asks for fingerprint or password before quitting; Indra keeps running)
//    3. Settings…                        (opens Indra's window)
//    4. Quit Indra
//  The icon turns red while the Face Lock session is locked.
//

import AppKit

@MainActor
final class FaceLockMenuBar: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var sessionItem: NSMenuItem?
    private var faceLockItem: NSMenuItem?
    private var unlocking = false

    func start() {
        apply()
        // The menu bar icon preference (Settings) adds or removes the icon live.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func apply() {
        if Preferences.menuBarIcon {
            install()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)   // v529: the menu bar icon is wide, not square
        item.behavior = []

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let session = NSMenuItem(title: "", action: #selector(toggleSession), keyEquivalent: "")
        session.target = self
        menu.addItem(session)

        let faceLock = NSMenuItem(title: "", action: #selector(toggleFaceLock), keyEquivalent: "")
        faceLock.target = self
        menu.addItem(faceLock)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = Self.symbol("gearshape.fill")
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Indra", action: #selector(quitIndra), keyEquivalent: "q")
        quit.target = self
        quit.image = Self.symbol("power")
        menu.addItem(quit)

        item.menu = menu
        MenuBarIconTinter.shared.attach(to: item.button)
        statusItem = item
        sessionItem = session
        faceLockItem = faceLock
        refreshTitles()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitles()
    }

    /// v547: one size and weight for every symbol in the menu, so they line up.
    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        image?.isTemplate = true
        return image
    }

    private func refreshTitles() {
        // v547: the symbol shows the STATE (a closed padlock while the session is locked, an open one while it is unlocked);
        // the title says what pressing the item does. It used to show the open padlock next to "Unlock Session" on a locked session.
        let unlocked = SecureCredentialManager.isSessionUnlocked
        sessionItem?.title = unlocked ? "Lock Session" : "Unlock Session"
        sessionItem?.image = Self.symbol(unlocked ? "lock.open.fill" : "lock.fill")
        sessionItem?.isEnabled = !unlocking

        let running = !FaceLockHost.shared.isFaceLockQuit
        faceLockItem?.title = running ? "Quit Face Lock" : "Start Face Lock"
        faceLockItem?.image = Self.symbol(running ? "faceid" : "eye.slash.fill")
    }

    // MARK: Actions

    @objc private func toggleSession() {
        let poc = FaceLockHost.shared.environment.pocController
        if SecureCredentialManager.isSessionUnlocked {
            poc.lockSession()
            MenuBarIconTinter.shared.refreshNow()
            return
        }
        guard !unlocking else { return }
        unlocking = true
        Task { @MainActor [weak self] in
            await poc.unlockSession()
            self?.unlocking = false
            MenuBarIconTinter.shared.refreshNow()
        }
    }

    @objc private func toggleFaceLock() {
        if FaceLockHost.shared.isFaceLockQuit {
            FaceLockHost.shared.startFaceLock()
            return
        }
        // Quitting Face Lock (only that, Indra keeps running) always asks for a fingerprint or the password.
        FaceLockGate.shared.require(title: "Quit Face Lock", force: true, always: true) {
            FaceLockHost.shared.quitFaceLock()
        }
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .indraOpenSettings, object: nil)
    }

    @objc private func quitIndra() {
        NSApp.terminate(nil)
    }
}
