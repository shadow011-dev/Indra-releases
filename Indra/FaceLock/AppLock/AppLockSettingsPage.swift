import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppLockSettingsPage: View {
    @State private var lockedIDs: [String] = UserDefaults.standard.stringArray(forKey: "lockedAppBundleIDs") ?? []
    @State private var hasPassword = FaceLockSecrets.hasPassword
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String?

    @AppStorage("appLockUseFace") private var useFace = true
    @AppStorage("appLockScanOnHover") private var scanOnHover = false
    @AppStorage("appLockRelockMinutes") private var relockMinutes = 0
    @AppStorage("appLockRelockOnLock") private var relockOnLock = true
    @AppStorage("appLockIdleMinutes") private var idleMinutes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            lockedAppsSection
            passwordSection
            behaviorSection
            Text("Only the apps listed here are protected, and only while Indra is running.")
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .onAppear {
            lockedIDs = UserDefaults.standard.stringArray(forKey: "lockedAppBundleIDs") ?? []
            hasPassword = FaceLockSecrets.hasPassword
        }
    }

    // MARK: - Locked apps

    private var lockedAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Locked apps")
            SettingsGroup {
                if lockedIDs.isEmpty {
                    SettingsRowContent(title: "No apps locked yet") { EmptyView() }
                    SettingsGroupDivider()
                }
                ForEach(lockedIDs, id: \.self) { id in
                    let info = appInfo(id)
                    SettingsRowContent(title: "\(info.name)") {
                        HStack(spacing: 10) {
                            Image(nsImage: info.icon)
                                .resizable()
                                .frame(width: 22, height: 22)
                            Button { FaceLockGate.shared.require { remove(id) } } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(SettingsMetrics.textSecondary)
                            .help("Stop locking this app")
                        }
                    }
                    SettingsGroupDivider()
                }
                SettingsActionRowContent(title: "Add an app", buttonTitle: "Add…") { FaceLockGate.shared.require { addApp() } }
            }
        }
    }

    private func appInfo(_ bundleID: String) -> (name: String, icon: NSImage) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (bundleID, NSImage())
    }

    private func saveLockedIDs() {
        UserDefaults.standard.set(lockedIDs, forKey: "lockedAppBundleIDs")
    }

    private func remove(_ id: String) {
        lockedIDs.removeAll { $0 == id }
        saveLockedIDs()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to lock"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let pickerDelegate = LockedAppPickerDelegate(lockedIDs: Set(lockedIDs))
        panel.delegate = pickerDelegate
        panel.message = "Apps that are already locked are greyed out."
        let result = panel.runModal()
        withExtendedLifetime(pickerDelegate) {}
        guard result == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  id != "com.apple.finder",
                  !lockedIDs.contains(id) else { continue }
            lockedIDs.append(id)
        }
        saveLockedIDs()
    }

    // MARK: - Password

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "App-lock password")
            SettingsGroup {
                SettingsRowContent(title: "Status") {
                    Text(hasPassword ? "Password set" : "Not set")
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }
                SettingsGroupDivider()
                if hasPassword {
                    SettingsRowContent(title: "Current password") {
                        passwordField($currentPassword, placeholder: "Enter current password")
                    }
                    SettingsGroupDivider()
                }
                SettingsRowContent(title: "New password") {
                    passwordField($newPassword, placeholder: "At least 4 characters")
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Confirm new password") {
                    passwordField($confirmPassword, placeholder: "Repeat new password")
                }
                SettingsGroupDivider()
                SettingsActionRowContent(
                    title: hasPassword ? "Change password" : "Set password",
                    buttonTitle: "Save",
                    isEnabled: !newPassword.isEmpty && !confirmPassword.isEmpty && (!hasPassword || !currentPassword.isEmpty)
                ) { FaceLockGate.shared.require { savePassword() } }
                if hasPassword {
                    SettingsGroupDivider()
                    SettingsActionRowContent(title: "Remove password", buttonTitle: "Remove", isDestructive: true,
                                             isEnabled: !currentPassword.isEmpty) { FaceLockGate.shared.require { removePassword() } }
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(messageIsError ? Color.red : SettingsMetrics.textSecondary)
                    .transition(.opacity)
            }
        }
    }

    /// A visible, rounded entry box (the old borderless field looked like plain text), with a placeholder that says what to type.
    private func passwordField(_ text: Binding<String>, placeholder: String) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .onChange(of: text.wrappedValue) { _, _ in
                // Typing again clears an old "incorrect" / "saved" message.
                if message != nil { withAnimation(.smooth(duration: 0.2)) { message = nil } }
            }
    }

    private var messageIsError: Bool {
        guard let message else { return false }
        return !(message.hasPrefix("Password saved") || message.hasPrefix("Password removed"))
    }

    private func savePassword() {
        if hasPassword && !FaceLockSecrets.verify(currentPassword) {
            message = "Current password is incorrect."
            return
        }
        guard newPassword.count >= 4 else {
            message = "Use at least 4 characters."
            return
        }
        guard newPassword == confirmPassword else {
            message = "The new passwords don't match."
            return
        }
        FaceLockSecrets.setPassword(newPassword)
        hasPassword = true
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        message = "Password saved."
    }

    private func removePassword() {
        guard FaceLockSecrets.verify(currentPassword) else {
            message = "Enter your current password to remove it."
            return
        }
        FaceLockSecrets.removePassword()
        hasPassword = false
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        message = "Password removed. Locked apps now open only with face or fingerprint."
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Behavior")
            SettingsGroup {
                SettingsRowContent(title: "Face check first") {
                    FaceLockToggle(isOn: $useFace)
                }
                SettingsGroupDivider()
                SettingsRowContent(
                    title: "Scan only on notch hover or button",
                    subtitle: "The face scan and its notch animation start only when you move the cursor to the notch, press the face button or press space, not by themselves. With this off, the first scan starts by itself; after it, the notch and space work the same way.",
                    subtitleMaxWidth: 320
                ) {
                    FaceLockToggle(isOn: $scanOnHover)
                }
                .opacity(useFace ? 1 : 0.45)
                .allowsHitTesting(useFace)
                SettingsGroupDivider()
                SettingsRowContent(title: "Relock automatically") {
                    Picker("", selection: $relockMinutes) {
                        Text("When the app quits").tag(0)
                        Text("After 1 minute").tag(1)
                        Text("After 5 minutes").tag(5)
                        Text("After 15 minutes").tag(15)
                        Text("After 1 hour").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Relock when out of focus for") {
                    Picker("", selection: $idleMinutes) {
                        Text("Never").tag(0)
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Relock on lock or sleep") {
                    FaceLockToggle(isOn: $relockOnLock)
                }
            }
        }
    }
}


/// Greys out apps that are already locked, so they cannot be picked twice.
final class LockedAppPickerDelegate: NSObject, NSOpenSavePanelDelegate {
    private let lockedIDs: Set<String>
    init(lockedIDs: Set<String>) { self.lockedIDs = lockedIDs }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app",
              let id = Bundle(url: url)?.bundleIdentifier else { return true }
        if id == Bundle.main.bundleIdentifier || id == "com.apple.finder" { return false }
        return !lockedIDs.contains(id)
    }
}
