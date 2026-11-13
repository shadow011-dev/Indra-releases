import CryptoKit
import Foundation

/// v549: developer-only items (the GitHub access token row, and anything else added later) are hidden until the developer
/// types a secret passphrase once on a Mac. The passphrase itself is NOT in the app: only its SHA-256 hash is, and a hash cannot
/// be turned back into the passphrase. Tap the "Updates" row in Settings > About five times to open the code box.
/// This only hides things; it protects nothing secret, because no secret ships in the app (the token is typed in by hand).
enum DeveloperAccess {
    /// SHA-256 of the developer passphrase (made with:  echo -n "passphrase" | shasum -a 256).
    nonisolated private static let expectedHash = "fd1bab9bd3e4daad92648242b59d3ad2eb38e3e76380e1088b4c638baf5c3ecd"
    nonisolated private static let unlockKey = "developerUnlockedHash"

    nonisolated private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True on a Mac where the right passphrase was entered.
    nonisolated static var isUnlocked: Bool {
        UserDefaults.standard.string(forKey: unlockKey) == expectedHash
    }

    /// Checks the typed passphrase; on success this Mac stays unlocked until `lock()`.
    @discardableResult
    nonisolated static func unlock(_ code: String) -> Bool {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, hash(clean) == expectedHash else { return false }
        UserDefaults.standard.set(expectedHash, forKey: unlockKey)
        return true
    }

    nonisolated static func lock() {
        UserDefaults.standard.removeObject(forKey: unlockKey)
    }
}
