import Foundation

/// v541: how many windows a locked app has, from ONE look at the window list (see AppLockController.windowCounts).
struct AppLockWindowCounts: Equatable {
    /// Every normal window: on screen or not (minimized, closed-but-kept, other Spaces).
    var total = 0
    /// Only the normal windows that are on the screen right now.
    var onScreen = 0
    /// True when one of the app's windows is as large as a whole screen (a full-screen app lives on its own Space, so while
    /// the user is on another Space it has no window on this one, which is not the same as having closed it).
    var hasFullScreenWindow = false
}

/// v541: one unlock of one running app. It belongs to THAT process: the pid alone is not enough, because a pid can be reused
/// and a quit notification can be missed. Before v541 the unlock was keyed by the pid only, so any unlock that was not
/// removed by the quit notification (or by the window watcher) stayed valid for as long as something with that pid lived.
struct UnlockSession {
    let at: Date
    /// When the process was started (NSRunningApplication.launchDate): a quit and reopen is a different launch date.
    let launch: Date?
}

/// v541: the decisions about when an unlock stops counting, as plain functions (no AppKit, so the unit tests can run them).
enum AppLockSessionRules {
    /// True while `currentLaunch` is the process the unlock was given to. A terminated app, or one with another start
    /// time, is a different app: it must be asked again.
    static func isSameProcess(storedLaunch: Date?, currentLaunch: Date?, isTerminated: Bool) -> Bool {
        if isTerminated { return false }
        guard let storedLaunch else { return true }          // nothing to compare against: the pid check has to do
        guard let currentLaunch else { return false }        // it had a start time, and now it has none: it is gone
        return abs(storedLaunch.timeIntervalSince(currentLaunch)) < 1
    }

    /// The app is in front but has nothing on the screen: its windows were closed (or minimized) and only the process
    /// lives on. For the user that is "closed", so opening it again (Dock, Spotlight) must ask again. Never while the app
    /// is hidden (that has its own rule), and never when it has a full-screen window (it is just on another Space).
    static func windowsClosedWhileInFront(_ counts: AppLockWindowCounts, isFront: Bool, isHidden: Bool) -> Bool {
        isFront && !isHidden && counts.onScreen == 0 && !counts.hasFullScreenWindow
    }

    /// The app has no normal window at all, in a row of checks (the v503 rule).
    static func windowsAllGone(_ counts: AppLockWindowCounts) -> Bool { counts.total == 0 }
}
