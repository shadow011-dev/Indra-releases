import AppKit
import EventKit

struct ReminderItem: Identifiable, Equatable {
    /// EventKit's own identifier for the reminder.
    let id: String
    let title: String
    let due: Date?
    /// False for a reminder that only has a day (no time of day).
    var hasTime: Bool = true
}

/// One line of the reminders page: an open reminder, or one that was just ticked off (it stays, struck through,
/// until you delete it or the page is rebuilt).
struct ReminderRow: Identifiable, Equatable {
    let item: ReminderItem
    let done: Bool
    var id: String { item.id }
}

/// The open reminders of the native Reminders app (every list). Reads and writes go through EventKit, so what
/// you add or finish in the notch shows up in Reminders (and on your other devices) and the other way round.
@MainActor
final class RemindersStore: ObservableObject {
    static let shared = RemindersStore()

    @Published private(set) var items: [ReminderItem] = []
    /// Ticked off in the notch: finished in Reminders, but still shown here (with the place they had in the list).
    @Published private(set) var finished: [(item: ReminderItem, index: Int)] = []
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private let maxItems = 200

    /// What the reminders page shows: the open reminders, with the ticked ones back in their old places.
    var rows: [ReminderRow] {
        var list = items.map { ReminderRow(item: $0, done: false) }
        for entry in finished.sorted(by: { $0.index < $1.index }) {
            list.insert(ReminderRow(item: entry.item, done: true), at: min(entry.index, list.count))
        }
        return list
    }

    var hasAccess: Bool { status == .fullAccess }
    var isDenied: Bool { status == .denied || status == .restricted }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    /// Called when the page opens (and when Reminders is switched on in the app): asks for access the first time.
    func activate() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            reload()
        case .notDetermined:
            Task { @MainActor in
                _ = try? await store.requestFullAccessToReminders()
                status = EKEventStore.authorizationStatus(for: .reminder)
                reload()
            }
        default:
            items = []
        }
    }

    func reload() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        guard hasAccess else {
            items = []
            return
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let calendar = Calendar.current
            let mapped = (reminders ?? []).map { reminder in
                ReminderItem(id: reminder.calendarItemIdentifier,
                             title: reminder.title ?? "",
                             due: reminder.dueDateComponents.flatMap { calendar.date(from: $0) },
                             hasTime: reminder.dueDateComponents?.hour != nil)
            }
            Task { @MainActor [weak self] in self?.apply(mapped) }
        }
    }

    private func apply(_ fetched: [ReminderItem]) {
        // One that was opened again in the Reminders app is a normal open reminder again.
        let fetchedIDs = Set(fetched.map(\.id))
        finished.removeAll { fetchedIDs.contains($0.item.id) }
        // Reminders with a due date first (soonest on top), then the rest alphabetically.
        let sorted = fetched.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        items = Array(sorted.prefix(maxItems))
    }

    /// New reminders go into the default list of the Reminders app.
    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAccess, !trimmed.isEmpty, items.count < maxItems,
              let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = list
        do {
            try store.save(reminder, commit: true)
            items.insert(ReminderItem(id: reminder.calendarItemIdentifier, title: trimmed, due: nil), at: 0)
        } catch {
            IndraLog.crumb("Reminders could not save a reminder")
        }
    }

    /// Ticks a reminder off (completed in the Reminders app) or, ticked again, puts it back. It stays in the list.
    func toggleDone(_ row: ReminderRow) {
        if row.done {
            let index = finished.first(where: { $0.item.id == row.id })?.index ?? 0
            finished.removeAll { $0.item.id == row.id }
            items.insert(row.item, at: min(index, items.count))
            setCompleted(false, for: row.item)
        } else {
            let index = rows.firstIndex(where: { $0.id == row.id }) ?? items.count
            items.removeAll { $0.id == row.id }
            finished.append((item: row.item, index: index))
            setCompleted(true, for: row.item)
        }
    }

    /// Deletes the reminder from the Reminders app.
    func delete(_ row: ReminderRow) {
        items.removeAll { $0.id == row.id }
        finished.removeAll { $0.item.id == row.id }
        guard hasAccess, let reminder = store.calendarItem(withIdentifier: row.id) as? EKReminder else { return }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            IndraLog.crumb("Reminders could not delete a reminder")
            reload()
        }
    }

    private func setCompleted(_ completed: Bool, for item: ReminderItem) {
        guard hasAccess, let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            IndraLog.crumb("Reminders could not change a reminder")
            reload()
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
}
