import AppKit

/// Every tap the app gives, in one place, so the notch, the main window and the lock screen all feel the same.
///
/// Four kinds, from the action itself to the finest ticks. Each is a single tap; the strength is chosen by the
/// trackpad actuation ID in `actuation` below, never by repeating taps:
///
///  * `action`  a thing happened: a page opened, a song changed, play / pause, the notch opened, the camera toggled
///  * `snap`    something locked into place: the pointer reached the notch, a lyric or a list row came into focus
///  * `step`    one notch of a slider or a strip: the date strip, the seek bar, the settings sliders
///  * `peak`    the one that must be felt through everything else: a new album cover coming into focus
///
/// Everything goes through the trackpad motor (`TrackpadActuator`) whenever it can be reached, in the main window
/// as well as in the notch and on the lock screen. The motor is driven from its own queue, so a tap costs the main
/// thread nothing and can be requested BEFORE the animation it belongs to starts, which keeps it in step with it.
/// If the motor cannot be reached, the closest system pattern is played instead (it only plays while Indra is the
/// active app, so on the notch and the lock screen that case is silent, and is noted in the problem report).
@MainActor
enum Haptics {
    enum Kind { case action, snap, step, peak }

    /// v428: where a tap comes from decides which switch can silence it. `.notch` (the notch, the main window) follows
    /// Settings > General > Haptic feedback; `.lock` (the lock screen) follows Settings > Lock Screen only.
    enum Scope { case notch, lock }

    private static func allowed(_ scope: Scope) -> Bool {
        switch scope {
        case .notch: return Preferences.hapticsEnabled
        case .lock: return Preferences.lockHapticsEnabled
        }
    }

    /// Trackpad motor actuation per kind. To make one feel different, change its number here. The IDs the
    /// trackpad answers to: 1 to 6, 15 and 16. 1-3 are light, 4 and 5 medium, 6 and 16 the strongest, 15 a short
    /// sharp click. `step` is fired in streams, so it stays one level under the strongest.
    private static let actuation: [Kind: Int32] = [
        .action: 16,
        .snap: 6,
        .step: 5,
        .peak: 6
    ]

    private static let fallback: [Kind: NSHapticFeedbackManager.FeedbackPattern] = [
        .action: .generic,
        .snap: .alignment,
        .step: .levelChange,
        .peak: .generic
    ]

    private static var lastTap = Date.distantPast
    private static var lastPrime = Date.distantPast
    private static var lastFallbackNote = Date.distantPast

    /// Two things that happen together (a page change that also closes the camera, say) give ONE tap, whichever
    /// comes first: no tap may follow another inside `lockout`. Streams (sliders, lyric focus) pass a shorter one.
    @discardableResult
    static func tap(_ kind: Kind, lockout: TimeInterval = 0.15, scope: Scope = .notch) -> Bool {
        // v426/v428: the switch of this tap's scope (see `Scope`). Nothing below runs when it is off, so no tap and no
        // system-pattern fallback can happen for that scope.
        guard allowed(scope) else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastTap) >= lockout else { return false }
        lastTap = now
        guard let id = actuation[kind] else { return false }
        let pattern = fallback[kind] ?? .generic
        TrackpadActuator.shared.fire(id) { fired in
            guard !fired else { return }
            // The motor could not be reached (even after opening it afresh): the system pattern stands in.
            let later = Date()
            if later.timeIntervalSince(lastFallbackNote) > 60 {
                lastFallbackNote = later
                IndraLog.crumb("Haptics: motor unreachable, used the system pattern")
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        return true
    }

    /// The one tap of a hover opening. It has its own, very short lockout: a hover tap must never be swallowed by an
    /// unrelated tap that happened a moment before (the 0.15 s every other tap uses), see `NotchWindowController`.
    static func hover(_ kind: Kind = .snap) {
        tap(kind, lockout: 0.03)
    }

    /// Call when a tap is about to be likely (the pointer is near the notch): the motor is checked and, if needed,
    /// opened now, so the tap itself finds it ready. Cheap, and at most once a second.
    static func prime() {
        guard Preferences.hapticsEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPrime) > 1.0 else { return }
        lastPrime = now
        TrackpadActuator.shared.prime()
    }

    // The older names, still used all over the app: hf1 = action, hf2 = snap, hf3 = step.
    static func hf1(lockout: TimeInterval = 0.15, scope: Scope = .notch) { tap(.action, lockout: lockout, scope: scope) }
    static func hf2(lockout: TimeInterval = 0.15, scope: Scope = .notch) { tap(.snap, lockout: lockout, scope: scope) }
    static func hf3(lockout: TimeInterval = 0.15, scope: Scope = .notch) { tap(.step, lockout: lockout, scope: scope) }
}
