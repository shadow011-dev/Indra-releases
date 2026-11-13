import Foundation

extension FaceUnlockCoordinator {
    /// nil when a face check can run; otherwise a short reason.
    var appLockFaceUnavailableReason: String? {
        if LockMonitor.isScreenActuallyLocked() { return "the screen is locked." }
        AppLockIdentityCache.refresh()
        if AppLockIdentityCache.identities.isEmpty {
            return SecureCredentialManager.isSessionUnlocked
                ? "no enrolled face is switched on in Your Face."
                : "face data isn't loaded yet. Open Indra Settings > Password and authenticate once."
        }
        return nil
    }
}
