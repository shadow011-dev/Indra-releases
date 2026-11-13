//
//  GeneralSettingsPage.swift
//  Indra Face Lock
//

import OSLog
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = FaceLockSettings.shared

    /// Refreshed on `didChangeScreenParametersNotification` so the picker
    /// reflects displays connecting/disconnecting while Settings is open.
    @State private var screens: [NSScreen] = NSScreen.screens
    /// Refreshed when the app regains focus, so granting the permission in
    /// System Settings clears the prompt below without a relaunch.
    @State private var inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — the session can be
    /// auto-locked while this page is visible.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    private var needsInputMonitoring: Bool {
        SpaceKeyMonitor.isWanted && inputMonitoring != .granted
    }

    /// Dev-only: under Xcode the reading above is Xcode's permission, not
    /// glance's, so it's meaningless. See `SpaceKeyMonitor.isLaunchedByXcode`.
    private var hasInheritedXcodePermission: Bool {
        SpaceKeyMonitor.isWanted && SpaceKeyMonitor.isLaunchedByXcode
    }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // The password prompt runs in the notch, outside this view's hierarchy,
        // so refresh the session state when that flow finishes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "Enable Face Unlock") {
                    FaceLockToggle(isOn: $coordinator.isEnabled.gated())
                }
                SettingsGroupDivider()
                displayPicker()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
            }
            .onAppear {
                // v516: the lock-screen key watch is always on now, so ask for Input Monitoring once, the first time this page opens.
                if inputMonitoring == .notDetermined {
                    _ = SpaceKeyMonitor.requestInputMonitoringAccess()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess }
                }
            }
            if hasInheritedXcodePermission {
                SettingsCaption(text: "Running from Xcode — permission checks resolve against Xcode’s grants, not Indra’s, so this reading is meaningless. Launch Indra.app on its own to see the real state.")
            } else if needsInputMonitoring {
                inputMonitoringNotice()
            }
            // v508: what the lock screen's space key reader did the last time the Mac was locked (and why a press was ignored).
            if SpaceKeyMonitor.isWanted {
                SettingsCaption(text: SpaceKeyMonitor.lastSummary
                    + (SpaceKeyMonitor.lastIgnoreReason.isEmpty ? "" : " " + SpaceKeyMonitor.lastIgnoreReason))
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Behaviour")
                SettingsGroup {
                    SettingsRowContent(title: "Retry on notch hover") {
                        FaceLockToggle(isOn: $settings.retryOnHover)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "Auto retry once after failure") {
                        FaceLockToggle(isOn: $settings.autoRetryOnce)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "Haptic feedback") {
                        FaceLockToggle(isOn: $settings.hapticFeedbackEnabled)
                    }
                    SettingsGroupDivider()
                    SettingsSteppedSliderRowContent(
                        title: "Face detection duration",
                        valueLabel: "\(settings.faceDetectionSeconds)s",
                        index: Binding(
                            get: { Double(settings.faceDetectionSeconds - FaceLockSettings.faceDetectionRange.lowerBound) },
                            set: { settings.faceDetectionSeconds = FaceLockSettings.faceDetectionRange.lowerBound + Int($0.rounded()) }
                        ),
                        stopCount: FaceLockSettings.faceDetectionRange.count
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Animation")
                SettingsGroup {
                    SettingsRowContent(title: "Show animation") {
                        FaceLockToggle(isOn: $settings.showUnlockAnimation)
                    }
                    SettingsGroupDivider()
                    UnlockAnimationPicker(
                        selection: $settings.unlockAnimationStyle,
                        isEnabled: settings.showUnlockAnimation
                    )
                    SettingsGroupDivider()
            AnimationColorRow().padding(.horizontal, 14).padding(.vertical, 10)
                        .opacity(settings.showUnlockAnimation ? 1 : 0.4)
                        .disabled(!settings.showUnlockAnimation)
                    SettingsGroupDivider()
                    AlbumGradientRow()
                        .opacity(settings.showUnlockAnimation ? 1 : 0.4)
                        .disabled(!settings.showUnlockAnimation)
                }
            }
        }
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }

    /// Shown while "On space" is selected but Input Monitoring isn't granted.
    private func inputMonitoringNotice() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: "“On space” reads the keyboard directly to see the space key on the lock screen, which needs Input Monitoring. Switch Indra on under Privacy & Security → Input Monitoring (if Indra is not in the list, press the button once, then look again), then quit and reopen Indra. A rebuilt Indra may need this again.")
            Button("Open Input Monitoring settings") {
                // v498: asks macOS first, which also puts Indra into the Input Monitoring list.
                SpaceKeyMonitor.requestInputMonitoringAccess()
                openSystemSettings(pane: "Privacy_ListenEvent")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(FaceLockTheme.accent)
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func displayPicker() -> some View {
        SettingsRowContent(title: "Display on") {
            SettingsMenuPickerPill(label: displayLabel) {
                Button("Main display") {
                    settings.preferredDisplayID = nil
                    settings.preferredDisplayName = nil
                }
                ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                    Button(screen.name) {
                        settings.preferredDisplayID = screen.id
                        settings.preferredDisplayName = screen.name
                    }
                }
            }
        }
    }

    /// A connected screen with its stable ID already unwrapped, so the
    /// picker's `ForEach` doesn't need to filter/force-unwrap inline.
    private struct NamedScreen {
        let id: String
        let name: String

        init?(_ screen: NSScreen) {
            guard let id = screen.stableDisplayID else { return nil }
            self.id = id
            self.name = screen.localizedName
        }
    }

    private var displayLabel: String {
        guard let targetID = settings.preferredDisplayID else { return "Main display" }
        if let connected = screens.first(where: { $0.stableDisplayID == targetID }) {
            return connected.localizedName
        }
        // Picked, but not currently connected — say so rather than showing
        // a bare ID or falling back to another display's name.
        guard let name = settings.preferredDisplayName else { return "Selected display (disconnected)" }
        return "\(name) (disconnected)"
    }
}

