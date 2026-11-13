import SwiftUI
import Observation

@Observable
@MainActor
final class AppLockState {
    var status = ""
    var canRetryFace = false
    /// Label of the face button: "Scan face" while the scan waits for a hover or a tap, "Try face again" after a scan.
    var retryTitle = "Try face again"
    var isUnlocked = false
    var appearCount = 0
    /// True while the cover only covers the app's own (small) window, e.g. a Stage Manager thumbnail.
    var compact = false
}

struct AppLockView: View {
    let appName: String
    let state: AppLockState
    let isFirstUse: Bool
    let onRetryFace: () -> Void
    let onTouchID: () -> Void
    let onSubmitPassword: (String) -> Bool
    let onCloseApp: () -> Void

    @State private var showPassword = false
    @State private var password = ""
    @State private var wrongPassword = false
    @State private var appeared = true
    @State private var viewHeight: CGFloat = 800
    @State private var shakeCount = 0
    @State private var relocking = false
    /// Mirrors the menu bar's Session Locked state; the face button turns red while it is locked.
    @State private var sessionLocked = !SecureCredentialManager.isSessionUnlocked
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            if state.compact {
                CompactLockTile().transition(.opacity)
            } else {
                fullBody.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: state.compact)
    }

    private var fullBody: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                Image(systemName: (isUnlockedNow || relocking) ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 48)
                    .modifier(LockFloat())
            }
            .modifier(StaggeredEntrance(appeared: appeared, delay: 0.0, startScale: 0.6))

            Text("\(appName) is locked")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .modifier(StaggeredEntrance(appeared: appeared, delay: 0.08))

            VStack(spacing: 18) {
            // Fixed slots: the status text and the retry button appear in place and never push the buttons below.
            ZStack {
                if !state.status.isEmpty {
                    Text(state.status)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            .frame(height: 34)

            pill("faceid", state.retryTitle, tint: sessionLocked ? Color(red: 0.86, green: 0.20, blue: 0.22) : nil) { onRetryFace() }
                .task { await watchSession() }
                .modifier(StaggeredEntrance(appeared: appeared, delay: 0.11))
                .opacity(state.canRetryFace ? 1 : 0)
                .allowsHitTesting(state.canRetryFace)

            HStack(spacing: 12) {
                pill("touchid", "Fingerprint") { onTouchID() }
                pill("key.fill", "Password") { togglePassword() }
            }
            .modifier(StaggeredEntrance(appeared: appeared, delay: 0.14))

            if showPassword {
                VStack(spacing: 8) {
                    if isFirstUse {
                        Text("Choose an app-lock password (4+ characters)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    SecureField(isFirstUse ? "New password" : "Password", text: $password)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(width: 220)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                        .modifier(FieldShake(count: shakeCount))
                        .overlay(Capsule().strokeBorder(Color.red.opacity(AnimationFlagsB.passwordShake && wrongPassword ? 0.8 : 0), lineWidth: 1))
                    if wrongPassword {
                        Text("Incorrect password")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }
                .onAppear { fieldFocused = true }
                .transition(AnimationFlagsB.passwordExpand ? AnyTransition.scale(scale: 0.5, anchor: .top).combined(with: .opacity) : .identity)
            }

            Button(action: onCloseApp) {
                Label("Close app", systemImage: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.52))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .help("Quit \(appName) without unlocking it")
            .modifier(StaggeredEntrance(appeared: appeared, delay: 0.2))
            }
            .frame(height: 340, alignment: .top)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(y: 50)
        .onAppear { replayEntrance() }
        .onChange(of: state.appearCount) { _, _ in replayEntrance() }
    }

    private var isUnlockedNow: Bool { AnimationFlags.successDissolve && state.isUnlocked }

    private func togglePassword() {
        withAnimation(AnimationFlagsB.passwordExpand ? .spring(response: 0.4, dampingFraction: 0.8) : nil) { showPassword.toggle() }
        guard showPassword else { return }
        NSApp.activate()
        for w in NSApp.windows where w is NSPanel && w.isVisible { w.makeKey() }
        Task { @MainActor in
            for ms in [60, 200] {
                try? await Task.sleep(for: .milliseconds(ms))
                fieldFocused = true
            }
        }
    }

    private func replayEntrance() {
        guard AnimationFlags.blurScreenEntrance else { return }
        appeared = false
        if AnimationFlagsB.relockClose { relocking = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            appeared = true
            try? await Task.sleep(for: .milliseconds(260))
            relocking = false
        }
    }

    private func submit() {
        if !onSubmitPassword(password) {
            wrongPassword = true
            password = ""
            shakeCount += 1
            FaceLockHaptics.failure()
        }
    }

    private func watchSession() async {
        while !Task.isCancelled {
            sessionLocked = !SecureCredentialManager.isSessionUnlocked
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func pill(_ symbol: String, _ title: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}


/// What a locked app shows when it is only a small window or thumbnail: plain black with a lock.
struct CompactLockTile: View {
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let icon = min(max(side * 0.26, 16), 64)
            ZStack {
                Color.black
                RadialGradient(colors: [Color.white.opacity(0.07), .clear],
                               center: .center, startRadius: 0, endRadius: max(side * 0.6, 1))
                Image(systemName: "lock.fill")
                    .font(.system(size: icon, weight: .medium))
                    .foregroundStyle(Color.white.opacity(breathe ? 0.95 : 0.7))
                    .shadow(color: .white.opacity(breathe ? 0.35 : 0.1), radius: icon * 0.35)
                    .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: breathe)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { breathe = true }
    }
}
