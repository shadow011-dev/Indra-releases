import CoreGraphics
import Foundation

/// v547: Screen Recording permission, asked WITHOUT waiting on the main thread.
///
/// `CGPreflightScreenCaptureAccess` and `CGRequestScreenCaptureAccess` are calls to the TCC service (a separate process). On a
/// Mac where that service is slow, or where the permission question is on screen, the caller waits, and called from the notch
/// (every time it opened, and the first time with the request) that wait was the main thread: "Indra stopped responding" on a
/// Mac that had not allowed Screen Recording. Now the answer is a cached value that a background task refreshes, and the request
/// is made from a background task, once per run.
final class ScreenAccess: @unchecked Sendable {
    static let shared = ScreenAccess()

    private let lock = NSLock()
    private var granted = false
    private var checkedAt = Date.distantPast
    private var refreshing = false
    private var asked = false

    /// The last known answer, at once. Starts a background refresh when the answer is older than `maxAge` seconds.
    func isGranted(maxAge: TimeInterval = 5) -> Bool {
        lock.lock()
        let current = granted
        let stale = Date().timeIntervalSince(checkedAt) > maxAge && !refreshing
        if stale { refreshing = true }
        lock.unlock()
        if stale { refresh() }
        return current
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let now = CGPreflightScreenCaptureAccess()
            lock.lock()
            granted = now
            checkedAt = Date()
            refreshing = false
            lock.unlock()
        }
    }

    /// Reads the permission once, in the background, so the first answer is ready before the notch first needs it.
    func warmUp() { _ = isGranted(maxAge: 0) }

    /// Shows the system question once per run, from a background task.
    func askOnce() {
        lock.lock()
        let first = !asked
        asked = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        }
    }
}
