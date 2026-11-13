import AppKit
import SwiftUI

/// The window that opens from the "Full access" pill at the bottom of the sidebar: every indicator of the app
/// (what is installed, allowed and working) in one place, with a button to fix whatever is not.
@MainActor
final class StatusWindowController {
    static let shared = StatusWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: StatusView())
            let w = NSWindow(contentViewController: controller)
            w.title = "Status"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 640))
            w.center()
            window = w
        }
        if let w = window { AppPresence.bringToFront(w) }
    }
}

private struct StatusView: View {
    @ObservedObject private var system = SystemNowPlaying.shared
    @ObservedObject private var reminders = RemindersStore.shared
    @ObservedObject private var health = HealthMonitor.shared
    @State private var trusted = SystemKeyInterceptor.isTrusted
    @State private var brightnessWorks = SensoryDiagnostics.brightnessReadable()
    @State private var keyboardWorks = SensoryDiagnostics.keyboardBacklightReadable()
    @State private var hapticsWork = TrackpadActuator.shared.isAvailable
    @State private var lockLayer = LockScreenController.layerAvailable

    private var systemStatusText: String {
        switch system.status {
        case .off: return "Off"
        case .preparing: return "Starting…"
        case .running: return "Active"
        case .unavailable: return "Unavailable"
        }
    }

    private func refresh() {
        trusted = SystemKeyInterceptor.isTrusted
        brightnessWorks = SensoryDiagnostics.brightnessReadable()
        keyboardWorks = SensoryDiagnostics.keyboardBacklightReadable()
        hapticsWork = TrackpadActuator.shared.isAvailable
        lockLayer = LockScreenController.layerAvailable
        reminders.reload()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Status")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.primary)

                SettingsCard("Access") {
                    SettingRow(symbol: "lock.open.fill", tint: Theme.green,
                               title: "Full-access build") {
                        StatusPill(ok: !SensoryDiagnostics.isSandboxed,
                                   text: SensoryDiagnostics.isSandboxed ? "Not installed" : "Installed")
                    }
                    RowDivider()
                    SettingRow(symbol: "accessibility", tint: Theme.blue,
                               title: "Accessibility") {
                        HStack(spacing: 8) {
                            StatusPill(ok: trusted, text: trusted ? "Allowed" : "Not allowed")
                            if !trusted {
                                ActionButton(title: "Allow…", kind: .primary) {
                                    SystemKeyInterceptor.requestTrust()
                                }
                            }
                        }
                    }
                    RowDivider()
                    SettingRow(symbol: "checklist", tint: Theme.yellow,
                               title: "Reminders") {
                        HStack(spacing: 8) {
                            StatusPill(ok: reminders.hasAccess, text: reminders.hasAccess ? "Allowed" : "Not allowed")
                            if !reminders.hasAccess {
                                ActionButton(title: reminders.isDenied ? "Open Settings" : "Allow…", kind: .primary) {
                                    if reminders.isDenied {
                                        RemindersStore.openPrivacySettings()
                                    } else {
                                        reminders.activate()
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsCard("Working") {
                    SettingRow(symbol: "sun.max.fill", tint: Theme.yellow,
                               title: "Brightness") {
                        StatusPill(ok: brightnessWorks, text: brightnessWorks ? "Active" : "Unavailable")
                    }
                    RowDivider()
                    SettingRow(symbol: "light.max", tint: Theme.orange,
                               title: "Keyboard backlight") {
                        StatusPill(ok: keyboardWorks, text: keyboardWorks ? "Active" : "Unavailable")
                    }
                    RowDivider()
                    SettingRow(symbol: "hand.tap.fill", tint: Theme.gray,
                               title: "Haptics") {
                        StatusPill(ok: hapticsWork, text: hapticsWork ? "Active" : "Unavailable")
                    }
                    RowDivider()
                    SettingRow(symbol: "lock.fill", tint: Theme.indigo,
                               title: "Lock screen") {
                        StatusPill(ok: lockLayer, text: lockLayer ? "Available" : "Unavailable")
                    }
                    RowDivider()
                    SettingRow(symbol: "play.rectangle.on.rectangle.fill", tint: Theme.pink,
                               title: "Media from any app") {
                        StatusPill(ok: system.status == .running, text: systemStatusText)
                    }
                    RowDivider()
                    SettingRow(symbol: "paperplane.fill", tint: Theme.blue,
                               title: "Blip") {
                        StatusPill(ok: FileSharing.blipURL != nil,
                                   text: FileSharing.blipURL != nil ? "Installed" : "Not installed")
                    }
                }

                SettingsCard("Self-check") {
                    SettingRow(symbol: "checkmark.shield.fill", tint: Theme.green,
                               title: "Indra") {
                        HStack(spacing: 8) {
                            StatusPill(ok: health.issues.isEmpty,
                                       text: health.issues.isEmpty ? "All good" : "\(health.issues.count) to fix")
                            ActionButton(title: "Run", symbol: "stethoscope") { health.checkNow() }
                        }
                    }
                    RowDivider()
                    SettingRow(title: "Changed something in System Settings?") {
                        ActionButton(title: "Check again", symbol: "arrow.clockwise") { refresh() }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(minWidth: 520, minHeight: 560)
        .background { VisualEffectBackground().ignoresSafeArea() }
        .onAppear {
            refresh()
            // The trackpad motor opens a moment after it is first asked for.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { hapticsWork = TrackpadActuator.shared.isAvailable }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }
}
