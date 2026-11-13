import Foundation

/// In-memory copy of the enrolled face identities, so app-lock face checks keep working after the
/// password session auto-locks. Never written to disk; it disappears when Indra quits.
@MainActor
enum AppLockIdentityCache {
    static var identities = FaceEnrollmentStore.shared.activeIdentities
    private static var timer: Timer?

    /// While the session is unlocked the live store is the truth (even when empty, e.g. after removing a face).
    /// While it is locked, only a non-empty live list replaces the copy.
    private static var lastRefresh = Date.distantPast

    static func refresh(force: Bool = false) {
        // Reading the faces decrypts them on the main thread, and this used to run twice at every scan start, right while
        // the notch was opening. Reuse a recent copy; a session change still refreshes at once.
        if !force, Date().timeIntervalSince(lastRefresh) < 3 { return }
        lastRefresh = Date()
        let live = FaceEnrollmentStore.shared.activeIdentities
        if SecureCredentialManager.isSessionUnlocked || !live.isEmpty {
            identities = live
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in AppLockIdentityCache.refresh() }
            }
            // Reloading the faces only matters when the session locks or unlocks, so react to that directly.
            NotificationCenter.default.addObserver(forName: .secureCredentialSessionDidChange, object: nil, queue: .main) { _ in
                Task { @MainActor in AppLockIdentityCache.refresh(force: true) }
            }
        }
    }
}
