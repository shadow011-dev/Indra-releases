import AppKit
import EventKit

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
}

/// Event-driven calendar data: refreshes on store changes and at midnight, never on a timer.
@MainActor
final class CalendarController: ObservableObject {
    @Published private(set) var today = Date()
    @Published private(set) var selectedDate = Date()
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Events of the selected day.
    @Published private(set) var events: [CalendarEvent] = []
    /// Up to two calendar colours per day-of-month, for the current month's dots.
    @Published private(set) var dayDots: [Int: [NSColor]] = [:]
    /// Bumped every time the notch has closed and the calendar went back to today (the day strip follows it).
    @Published private(set) var resetToken = 0

    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dayChanged() }
        })
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        })
    }

    /// Called when the calendar view appears.
    func activate() {
        today = Date()
        selectedDate = today
        status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            reload()
        case .notDetermined:
            Task {
                _ = try? await store.requestFullAccessToEvents()
                status = EKEventStore.authorizationStatus(for: .event)
                reload()
            }
        default:
            events = []
            dayDots = [:]
        }
    }

    /// Re-reads the events of the selected day and the month dots without changing the selection. Used by pages that
    /// can stay alive while the notch is closed (Duo), so they never show a stale, empty day.
    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { return }
        store.refreshSourcesIfNecessary()
        reload()
    }

    /// Selects today again (used once the notch is closed).
    func resetToToday() {
        today = Date()
        resetToken &+= 1
        guard !Calendar.current.isDate(selectedDate, inSameDayAs: today) else { return }
        selectedDate = today
        reloadDay()
    }

    func select(_ date: Date) {
        selectedDate = date
        reloadDay()
    }

    private func dayChanged() {
        today = Date()
        selectedDate = today
        reload()
    }

    private func reload() {
        reloadDay()
        reloadMonthDots()
    }

    private func reloadDay() {
        guard status == .fullAccess else {
            events = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return (lhs.startDate ?? .distantPast) < (rhs.startDate ?? .distantPast)
            }
            .prefix(20)
            .map { event in
                CalendarEvent(id: "\(event.eventIdentifier ?? "")-\(event.startDate?.timeIntervalSince1970 ?? 0)",
                              title: event.title ?? "Untitled",
                              start: event.startDate ?? start,
                              end: event.endDate ?? start,
                              isAllDay: event.isAllDay,
                              color: event.calendar?.color ?? .systemBlue)
            }
    }

    private func reloadMonthDots() {
        guard status == .fullAccess else {
            dayDots = [:]
            return
        }
        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: today) else { return }
        let predicate = store.predicateForEvents(withStart: month.start, end: month.end, calendars: nil)
        var dots: [Int: [NSColor]] = [:]
        for event in store.events(matching: predicate) {
            guard let eventStart = event.startDate, let eventEnd = event.endDate else { continue }
            let color = event.calendar?.color ?? .systemBlue
            var day = max(calendar.startOfDay(for: eventStart), month.start)
            let limit = min(eventEnd, month.end)
            var steps = 0
            while day < limit, steps < 31 {
                let number = calendar.component(.day, from: day)
                var colors = dots[number] ?? []
                if colors.count < 2, !colors.contains(color) { colors.append(color) }
                dots[number] = colors
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                steps += 1
            }
        }
        dayDots = dots
    }
}
