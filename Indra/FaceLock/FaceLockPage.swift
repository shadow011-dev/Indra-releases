//
//  FaceLockPage.swift
//  Indra Face Lock
//
//  The Face Lock section of Indra's settings window. v502: opening it no longer asks for anything. The fingerprint or
//  password prompt appears only when a crucial setting is changed, and one pass stays valid until Indra loses focus.
//

import SwiftUI

/// A closure `onPreferenceChange` can actually consume (that API requires `Value: Equatable`, which a bare closure can
/// never be). Equality is by identity, so this is deliberately never equal to a previous instance.
struct HeaderAction: Equatable {
    private let id = UUID()
    let perform: () -> Void

    static func == (lhs: HeaderAction, rhs: HeaderAction) -> Bool { lhs.id == rhs.id }
}

/// Lets one page (the Camera page's "Refresh camera list") publish an action to the section's header.
struct HeaderTrailingActionKey: PreferenceKey {
    static var defaultValue: HeaderAction? { nil }
    static func reduce(value: inout HeaderAction?, nextValue: () -> HeaderAction?) {
        value = nextValue() ?? value
    }
}

struct FaceLockPage: View {
    @State private var tab: SettingsTab = .general
    @State private var headerAction: HeaderAction?
    @State private var hasPassword = FaceLockSecrets.hasPassword
    @State private var showPasswordSheet = false
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordMessage: String?

    private var environment: FaceLockEnvironment { FaceLockHost.shared.environment }

    var body: some View {
        SettingsPage(.faceLock) {
            unlockedContent
        }
        .onAppear {
            hasPassword = FaceLockSecrets.hasPassword
        }
        .onReceive(NotificationCenter.default.publisher(for: .indraMainWindowClosed)) { _ in
            tab = .general
        }
        .sheet(isPresented: $showPasswordSheet) { passwordSheet }
    }

    // MARK: - Unlocked

    private var unlockedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Access") {
                // v543: "Ask for fingerprint or password to open this section" is not an option any more: it is always on.
                SettingRow(symbol: "key.fill", tint: Theme.orange,
                           title: hasPassword ? "Change section password" : "Set section password") {
                    Button(hasPassword ? "Change…" : "Set…") {
                        FaceLockGate.shared.require {
                            newPassword = ""
                            confirmPassword = ""
                            passwordMessage = nil
                            showPasswordSheet = true
                        }
                    }
                }
                if hasPassword {
                    RowDivider()
                    SettingRow(symbol: "trash.fill", tint: Theme.red, title: "Remove section password") {
                        Button("Remove") {
                            FaceLockGate.shared.require {
                                FaceLockSecrets.removePassword()
                                hasPassword = false
                            }
                        }
                    }
                }
            }

            Picker("", selection: $tab) {
                ForEach(SettingsTab.visibleTabs(includingDebug: environment.isDebugSectionRevealed)) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                    pageBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(FaceLockTheme.accent)

                if let headerAction {
                    Button(action: headerAction.perform) {
                        Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help("Refresh camera list")
                }
            }
            .animation(.smooth(duration: 0.3), value: tab)
            .onPreferenceChange(HeaderTrailingActionKey.self) { headerAction = $0 }

            // v540: Face Lock is built on Glance (MIT); the credit and the licenses sit at the bottom of the section.
            FaceLockCredit()
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch tab {
        case .general:
            GeneralSettingsPage(coordinator: environment.faceUnlockCoordinator, pocController: environment.pocController)
        case .yourFace:
            // v478: Face, Camera and Recognition in one page. While the session is locked only the Face page shows
            // (it carries the unlock prompt), so the prompt is not repeated three times.
            YourFaceSettingsPage(environment: environment)
            // v479: Camera (pickers + preview) is the last block of the page.
            if environment.pocController.isSessionUnlocked {
                RecognitionSettingsPage(coordinator: environment.faceUnlockCoordinator, pocController: environment.pocController)
                CameraSettingsPage(pocController: environment.pocController)
            }
        case .password:
            PasswordSettingsPage(pocController: environment.pocController)
        case .appLock:
            AppLockSettingsPage()
        case .debugFaceLab:
            FaceLockLabPage()
        }
    }

    // MARK: - Section password

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(hasPassword ? "Change section password" : "Set section password")
                .font(.system(size: 16, weight: .semibold))
            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
            if let passwordMessage {
                Text(passwordMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showPasswordSheet = false }
                Button("Save") {
                    guard !newPassword.isEmpty else { passwordMessage = "Enter a password."; return }
                    guard newPassword == confirmPassword else { passwordMessage = "The two passwords differ."; return }
                    FaceLockSecrets.setPassword(newPassword)
                    hasPassword = FaceLockSecrets.hasPassword
                    showPasswordSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 320)
    }
}

/// Face Lab is only reachable through a hidden gesture in Lumen; here it stays unreachable unless the debug flag is set.
private struct FaceLockLabPage: View {
    @State private var controller: FaceLabController?

    var body: some View {
        Group {
            if let controller {
                FaceLabView(controller: controller)
            } else {
                ProgressView("Loading Face Lab…")
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
                    .task {
                        await Task.yield()
                        guard !Task.isCancelled, controller == nil else { return }
                        controller = FaceLabController()
                    }
            }
        }
        .onDisappear {
            controller?.stop()
            controller = nil
        }
    }
}
