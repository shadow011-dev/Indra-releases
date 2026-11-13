import XCTest
@testable import Indra

/// v541: when an App Lock unlock stops counting. These are the cases that let a locked app open without asking.
final class AppLockSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testQuitAndReopenIsAnotherProcess() {
        // Same pid, different start time: a quit and reopen (or a reused pid) must never keep the old unlock.
        XCTAssertFalse(AppLockSessionRules.isSameProcess(storedLaunch: t0, currentLaunch: t0.addingTimeInterval(30), isTerminated: false))
    }

    func testSameProcessKeepsItsUnlock() {
        XCTAssertTrue(AppLockSessionRules.isSameProcess(storedLaunch: t0, currentLaunch: t0.addingTimeInterval(0.2), isTerminated: false))
    }

    func testTerminatedProcessNeverKeepsAnUnlock() {
        XCTAssertFalse(AppLockSessionRules.isSameProcess(storedLaunch: t0, currentLaunch: t0, isTerminated: true))
        XCTAssertFalse(AppLockSessionRules.isSameProcess(storedLaunch: nil, currentLaunch: nil, isTerminated: true))
    }

    func testProcessThatLostItsStartTimeIsGone() {
        XCTAssertFalse(AppLockSessionRules.isSameProcess(storedLaunch: t0, currentLaunch: nil, isTerminated: false))
    }

    func testClosedWindowsInFrontLockTheApp() {
        // The window was closed with the red button: the app keeps it off screen, so the total is above zero but nothing is shown.
        let kept = AppLockWindowCounts(total: 1, onScreen: 0, hasFullScreenWindow: false)
        XCTAssertTrue(AppLockSessionRules.windowsClosedWhileInFront(kept, isFront: true, isHidden: false))
    }

    func testVisibleWindowKeepsTheUnlock() {
        let shown = AppLockWindowCounts(total: 2, onScreen: 1, hasFullScreenWindow: false)
        XCTAssertFalse(AppLockSessionRules.windowsClosedWhileInFront(shown, isFront: true, isHidden: false))
    }

    func testFullScreenAppOnAnotherSpaceKeepsTheUnlock() {
        let away = AppLockWindowCounts(total: 1, onScreen: 0, hasFullScreenWindow: true)
        XCTAssertFalse(AppLockSessionRules.windowsClosedWhileInFront(away, isFront: true, isHidden: false))
    }

    func testAppNotInFrontOrHiddenIsNotJudgedByItsWindows() {
        let none = AppLockWindowCounts(total: 1, onScreen: 0, hasFullScreenWindow: false)
        XCTAssertFalse(AppLockSessionRules.windowsClosedWhileInFront(none, isFront: false, isHidden: false))
        XCTAssertFalse(AppLockSessionRules.windowsClosedWhileInFront(none, isFront: true, isHidden: true))
    }

    func testNoWindowAtAllIsGone() {
        XCTAssertTrue(AppLockSessionRules.windowsAllGone(AppLockWindowCounts()))
        XCTAssertFalse(AppLockSessionRules.windowsAllGone(AppLockWindowCounts(total: 1, onScreen: 0, hasFullScreenWindow: false)))
    }
}
