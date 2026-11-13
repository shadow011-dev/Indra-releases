import AppKit
import SwiftUI

/// The Pomodoro timer behind Duo's Zen space. One shared timer, so it keeps running while the notch is closed
/// and is still there when it opens again. It works from an end date, so sleeping or a busy Mac never drifts it.
/// Colours of the focus timer: spring green for focus, teal for a short break, cornflower for a long break.
enum TimerShades {
    static let spring = Color(red: 0.49, green: 0.72, blue: 0.29)
    static let shortBreak = Color(red: 0.25, green: 0.70, blue: 0.74)
    static let longBreak = Color(red: 0.45, green: 0.62, blue: 0.98)
}

@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    static let sessionsPerRound = 4

    enum Phase {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: return "Focus"
            case .shortBreak: return "Short break"
            case .longBreak: return "Long break"
            }
        }

        var isBreak: Bool { self != .focus }

        var tint: Color {
            switch self {
            case .focus: return TimerShades.spring
            case .shortBreak: return TimerShades.shortBreak
            case .longBreak: return TimerShades.longBreak
            }
        }
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var remaining: TimeInterval
    /// Focus sessions finished in the current round (0 ... 4); a long break ends the round.
    @Published private(set) var sessionsDone = 0

    private var endDate: Date?
    private var ticker: Timer?

    private init() {
        remaining = FocusTimer.length(of: .focus)
    }

    // MARK: - Lengths

    static var focusMinutes: Int {
        let value = UserDefaults.standard.object(forKey: Preferences.focusMinutesKey) as? Int ?? 25
        return min(max(value, 5), 120)
    }

    static func length(of phase: Phase) -> TimeInterval {
        let focus = Double(focusMinutes)
        switch phase {
        case .focus: return focus * 60
        case .shortBreak: return max(5, (focus / 5).rounded()) * 60
        case .longBreak: return max(10, (focus * 0.6).rounded()) * 60
        }
    }

    var total: TimeInterval { FocusTimer.length(of: phase) }
    var progress: Double { total > 0 ? min(max(1 - remaining / total, 0), 1) : 0 }

    /// A new focus length. It applies straight away when the timer is sitting untouched on a focus session.
    func setFocusMinutes(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: Preferences.focusMinutesKey)
        if !isRunning, phase == .focus { remaining = FocusTimer.length(of: .focus) }
        objectWillChange.send()
    }

    /// Switches between a focus session and a break (only while the timer is not running).
    func select(_ target: Phase) {
        guard !isRunning, phase.isBreak != target.isBreak else { return }
        phase = target
        remaining = total
    }

    /// The minutes the ruler shows: the length while idle, the time left while running or paused.
    var rulerMinutes: Double {
        (isRunning || progress > 0) ? remaining / 60 : total / 60
    }

    // MARK: - Controls

    func toggle(fromIsland: Bool = false) {
        isRunning ? pause() : start(fromIsland: fromIsland)
    }

    /// `fromIsland` is true when Start was pressed on the external monitor's notch: only that notch plays the start animation.
    func start(fromIsland: Bool = false) {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = total }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        NotificationCenter.default.post(name: .indraFocusStarted, object: nil,
                                        userInfo: ["fromIsland": fromIsland])
    }

    func pause() {
        guard isRunning else { return }
        tick()
        stopTicker()
        isRunning = false
    }

    /// Back to the start of the current session.
    func reset() {
        stopTicker()
        isRunning = false
        remaining = total
    }

    /// Jump to the next session (focus -> break -> focus), without counting a skipped focus session as done.
    func skip() {
        stopTicker()
        isRunning = false
        advance(finished: false)
    }

    // MARK: - Ticking

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { finish() }
    }

    private func finish() {
        stopTicker()
        isRunning = false
        if Preferences.timerSound { NSSound(named: NSSound.Name("Glass"))?.play() }
        Haptics.hf1()
        advance(finished: true)
    }

    private func advance(finished: Bool) {
        switch phase {
        case .focus:
            if finished { sessionsDone += 1 }
            phase = sessionsDone >= FocusTimer.sessionsPerRound ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            sessionsDone = 0
            phase = .focus
        }
        remaining = total
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }
}
