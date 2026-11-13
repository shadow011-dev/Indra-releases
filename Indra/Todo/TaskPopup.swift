import SwiftUI
import AppKit

/// Which list a pop-up in the notch comes from.
enum TaskKind: String, Equatable {
    case todo
    case reminder

    var symbol: String { self == .todo ? "checklist" : "bell.badge.fill" }
    var label: String { self == .todo ? "To do" : "Reminder" }
    /// Red for the to-do page, yellow for Reminders (the same colours as the two pages in the open notch).
    var color: Color {
        self == .todo ? Color(red: 0.882, green: 0.310, blue: 0.384) : Color(red: 1.0, green: 0.80, blue: 0.0)
    }
}

extension Notification.Name {
    /// Posted by the "Show now" buttons in the To Do settings (object: "todo" or "reminder").
    static let indraTaskPopupPreview = Notification.Name("indraTaskPopupPreview")
}

// MARK: - Settings values

struct TaskPopupConfig {
    var enabled: Bool
    /// Minutes between pop-ups of the list; 0 = never.
    var every: Int
    var unlock: Bool
    var daily: Bool
    /// Minutes after midnight.
    var dailyMinutes: Int
    /// To-do: "oldest", "newest" or "cycle". Reminders: "soonest" or "cycle".
    var order: String
    var seconds: Double
    // Reminders only.
    var onDue: Bool
    /// Minutes before the due time; 0 = no heads-up.
    var ahead: Int
    /// Minutes between nudges for overdue reminders; 0 = never.
    var overdueEvery: Int
}

enum TaskPopupPrefs {
    static let todoOnKey = "todoPopup"
    static let todoEveryKey = "todoPopupEvery"
    static let todoUnlockKey = "todoPopupUnlock"
    static let todoDailyKey = "todoPopupDaily"
    static let todoDailyTimeKey = "todoPopupDailyTime"
    static let todoOrderKey = "todoPopupOrder"
    static let todoSecondsKey = "todoPopupSeconds"

    static let remOnKey = "reminderPopup"
    static let remDueKey = "reminderPopupDue"
    static let remAheadKey = "reminderPopupAhead"
    static let remOverdueKey = "reminderPopupOverdue"
    static let remEveryKey = "reminderPopupEvery"
    static let remUnlockKey = "reminderPopupUnlock"
    static let remDailyKey = "reminderPopupDaily"
    static let remDailyTimeKey = "reminderPopupDailyTime"
    static let remOrderKey = "reminderPopupOrder"
    static let remSecondsKey = "reminderPopupSeconds"

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    private static func seconds(_ key: String) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? 5
        return min(max(value, 3), 10)
    }

    static var todo: TaskPopupConfig {
        let order = UserDefaults.standard.string(forKey: todoOrderKey) ?? "oldest"
        return TaskPopupConfig(enabled: bool(todoOnKey, false),
                               every: int(todoEveryKey, 60),
                               unlock: false, // no longer a setting
                               daily: bool(todoDailyKey, false),
                               dailyMinutes: int(todoDailyTimeKey, 540),
                               order: ["oldest", "newest", "cycle"].contains(order) ? order : "oldest",
                               seconds: 5, // fixed; "One by one" uses 3 s each
                               onDue: false, ahead: 0, overdueEvery: 0)
    }

    static var reminders: TaskPopupConfig {
        let order = UserDefaults.standard.string(forKey: remOrderKey) ?? "soonest"
        return TaskPopupConfig(enabled: bool(remOnKey, false),
                               every: 0, // no longer a setting
                               unlock: false, // no longer a setting
                               daily: bool(remDailyKey, false),
                               dailyMinutes: int(remDailyTimeKey, 540),
                               order: ["soonest", "cycle"].contains(order) ? order : "soonest",
                               seconds: 5, // fixed; "One by one" uses 3 s each
                               onDue: bool(remDueKey, true),
                               ahead: int(remAheadKey, 10),
                               overdueEvery: int(remOverdueKey, 15))
    }
}

// MARK: - Wording

enum TaskPopupText {
    /// "Due in 10 min", "Due today, 4:30 PM", "Overdue, was 9:00 AM" ...
    static func reminderDetail(_ item: ReminderItem, now: Date) -> String {
        guard let due = item.due else { return "No date" }
        let calendar = Calendar.current
        let time = due.formatted(date: .omitted, time: .shortened)
        let day = due.formatted(date: .abbreviated, time: .omitted)
        if item.hasTime {
            if due < now {
                if now.timeIntervalSince(due) < 180 { return "Due now" }
                return calendar.isDateInToday(due) ? "Overdue, was \(time)" : "Overdue since \(day)"
            }
            let minutes = Int(due.timeIntervalSince(now) / 60)
            if minutes < 1 { return "Due now" }
            if minutes < 90 { return "Due in \(minutes) min" }
            if calendar.isDateInToday(due) { return "Due today, \(time)" }
            if calendar.isDateInTomorrow(due) { return "Due tomorrow, \(time)" }
            return "Due \(day), \(time)"
        }
        if due < calendar.startOfDay(for: now) { return "Overdue since \(day)" }
        if calendar.isDateInToday(due) { return "Due today" }
        if calendar.isDateInTomorrow(due) { return "Due tomorrow" }
        return "Due \(day)"
    }
}

// MARK: - Scheduler

/// Decides when a task pops up in the notch, from the choices in To Do settings. It only looks at the clock every
/// 15 seconds, and never while the Mac is locked. The notch itself draws the card (see TaskDownlineView).
@MainActor
final class TaskPopupScheduler {
    /// (activity, seconds on screen, force) -> true when the notch showed it. Without `force` the notch may say no
    /// because something else is on screen; the scheduler then simply tries again on its next look.
    typealias Show = @MainActor (LiveActivity, Double, Bool) -> Bool

    private let show: Show
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var locked = false

    private var todoEvery = 0
    private var todoNext: Date?
    private var remEvery = 0
    private var remNext: Date?
    private var overdueEvery = 0
    private var overdueNext: Date?
    private var overdueCycle = 0
    /// "One by one": every task of a round pops up in turn, 3 seconds each (at most `sequenceLimit`).
    private static let overdueLastKey = "taskPopupOverdueLast"
    private static let sequenceSeconds = 3.0
    private static let sequenceLimit = 15
    private var sequenceTask: Task<Void, Never>?
    private var sequencePlaying = false
    private var fired = Set<String>()
    private var lastReload = Date()

    init(show: @escaping Show) {
        self.show = show
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.lockedNow() }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.unlocked() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .indraTaskPopupPreview,
                                                                object: nil, queue: .main) { [weak self] note in
            let raw = note.object as? String
            Task { @MainActor [weak self] in self?.preview(raw) }
        })
        // v429: looked at every 5 seconds (it was 15, with up to 5 more of timer slack): a due time or a heads-up now
        // appears within a few seconds of its moment, and the "Show now" / settings changes are picked up quickly.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The reminders are read now (only when the Reminders page is in use, so nobody who does not use it is asked
        // for access).
        if Preferences.remindersEnabled || TaskAlarmStore.shared.alarms.contains(where: { $0.kind == TaskKind.reminder.rawValue }) {
            RemindersStore.shared.activate()
        }
        lastReload = Date()
    }

    // MARK: Looking at the clock

    private func lockedNow() {
        locked = true
        sequenceTask?.cancel()
        sequencePlaying = false
    }

    /// The real state of the session, so a missed lock / unlock notification can never leave the pop-ups switched off.
    private func sessionIsLocked() -> Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (dict?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func tick() {
        // v429: the notification can be missed (a sleep, a fast user switch); the session itself is the truth.
        if locked, !sessionIsLocked() { unlocked() }
        guard !locked, !sequencePlaying else { return }
        let now = Date()
        if tickAlarms(now) { return }
        if Preferences.todoEnabled, TaskPopupPrefs.todo.enabled {
            tickTodo(now)
        } else if Preferences.remindersEnabled, TaskPopupPrefs.reminders.enabled {
            tickReminders(now)
        }
    }

    /// An alarm the user set goes off even when the pop-ups above are switched off. One alarm per look; a late one
    /// (the Mac was asleep or locked) says when it was meant to go off.
    private func tickAlarms(_ now: Date) -> Bool {
        let store = TaskAlarmStore.shared
        guard let alarm = store.alarms.first(where: { $0.fireAt <= now }) else { return false }
        let kind = TaskKind(rawValue: alarm.kind) ?? .todo
        var title = alarm.title
        switch kind {
        case .todo:
            guard let item = TodoStore.shared.openItems.first(where: { $0.id.uuidString == alarm.itemID }) else {
                store.remove(alarm) // finished or deleted since
                return false
            }
            title = item.title
        case .reminder:
            let reminders = RemindersStore.shared
            if let item = reminders.items.first(where: { $0.id == alarm.itemID }) {
                title = item.title
            } else if reminders.hasAccess, !reminders.items.isEmpty {
                store.remove(alarm) // finished or deleted since
                return false
            }
        }
        let seconds = max((kind == .todo ? TaskPopupPrefs.todo : TaskPopupPrefs.reminders).seconds, 5)
        let late = now.timeIntervalSince(alarm.fireAt) > 180
        let detail = late ? "Alarm, was \(alarm.fireAt.formatted(date: .omitted, time: .shortened))" : "Alarm"
        let shown = show(.task(kind: kind, title: title.isEmpty ? "Untitled" : title, detail: detail), seconds, false)
        if shown { store.remove(alarm) }
        return shown
    }

    private func tickTodo(_ now: Date) {
        let config = TaskPopupPrefs.todo
        let items = TodoStore.shared.openItems
        if config.every != todoEvery {
            todoEvery = config.every
            todoNext = nil
        }
        if config.every > 0 {
            let gap = Double(config.every) * 60
            if todoNext == nil { todoNext = now.addingTimeInterval(gap) }
            if let next = todoNext, now >= next {
                if items.isEmpty {
                    todoNext = now.addingTimeInterval(gap)
                } else if showTodo(items, config, force: false) {
                    todoNext = now.addingTimeInterval(gap)
                    return
                }
            }
        }
        if dailyDue(.todo, config, now), showTodo(items, config, force: false) {
            markDaily(.todo, now)
        }
    }

    private func tickReminders(_ now: Date) {
        let config = TaskPopupPrefs.reminders
        let store = RemindersStore.shared
        // v429: every minute (it was every 10 minutes, so a reminder added or changed elsewhere, or reminders that were
        // switched on after launch, stayed unseen for a long time). The store also reloads at once when Reminders changes.
        if now.timeIntervalSince(lastReload) > 60 {
            lastReload = now
            store.reload()
        }
        guard store.hasAccess else { return }
        let items = store.items
        if fired.count > 500 { fired.removeAll() }

        // 1. At the due time, and the heads-up before it. Only reminders with a time of day.
        if config.onDue || config.ahead > 0 {
            for item in items {
                guard item.hasTime, let due = item.due else { continue }
                let stamp = Int(due.timeIntervalSince1970)
                var moments: [(String, Date)] = []
                if config.onDue { moments.append(("due", due)) }
                if config.ahead > 0 { moments.append(("ahead\(config.ahead)", due.addingTimeInterval(-Double(config.ahead) * 60))) }
                for (name, moment) in moments {
                    let key = "\(name)|\(item.id)|\(stamp)"
                    // Within 2.5 minutes of the moment: a Mac that was asleep does not replay old ones.
                    guard now >= moment, now.timeIntervalSince(moment) < 150, !fired.contains(key) else { continue }
                    if showReminder(item, now: now, config: config, position: nil, force: false) {
                        fired.insert(key)
                        IndraLog.crumb("Reminder pop-up: \(name == "due" ? "due" : "heads-up")")
                        return
                    }
                }
            }
        }

        // 2. Nudges while something is overdue.
        // v429: the time of the last nudge is remembered (also across a restart of Indra). The first nudge comes as soon as
        // something is overdue and the interval since the last one has passed; before, it waited a whole interval after
        // first seeing the overdue reminder, and every unlock, restart or lock started that wait again, so with a Mac that
        // is locked or restarted more often than the interval the nudge never came.
        if config.overdueEvery != overdueEvery {
            overdueEvery = config.overdueEvery
            overdueNext = nil
        }
        if config.overdueEvery > 0 {
            let overdue = items.filter { isOverdue($0, now) }
            if overdue.isEmpty {
                overdueNext = nil
            } else {
                let gap = Double(config.overdueEvery) * 60
                if overdueNext == nil {
                    let last = UserDefaults.standard.object(forKey: Self.overdueLastKey) as? Date ?? Date.distantPast
                    overdueNext = last.addingTimeInterval(gap)
                }
                if let next = overdueNext, now >= next {
                    if config.order == "cycle" {
                        let list = Array(overdue.prefix(Self.sequenceLimit))
                        let activities = list.enumerated().map { entry in
                            reminderActivity(entry.element, now: now, position: "\(entry.offset + 1) of \(overdue.count) overdue")
                        }
                        if playSequence(activities, force: false) {
                            overdueNext = now.addingTimeInterval(gap)
                            UserDefaults.standard.set(now, forKey: Self.overdueLastKey)
                            IndraLog.crumb("Reminder pop-up: overdue nudge")
                            return
                        }
                    } else {
                        let index = overdueCycle % overdue.count
                        let position = overdue.count > 1 ? "\(index + 1) of \(overdue.count) overdue" : nil
                        if showReminder(overdue[index], now: now, config: config, position: position, force: false) {
                            overdueCycle = index + 1
                            overdueNext = now.addingTimeInterval(gap)
                            UserDefaults.standard.set(now, forKey: Self.overdueLastKey)
                            IndraLog.crumb("Reminder pop-up: overdue nudge")
                            return
                        }
                    }
                }
            }
        }

        // 3. The list every so often.
        if config.every != remEvery {
            remEvery = config.every
            remNext = nil
        }
        if config.every > 0 {
            let gap = Double(config.every) * 60
            if remNext == nil { remNext = now.addingTimeInterval(gap) }
            if let next = remNext, now >= next {
                if items.isEmpty {
                    remNext = now.addingTimeInterval(gap)
                } else if showReminderFromList(items, config, force: false) {
                    remNext = now.addingTimeInterval(gap)
                    return
                }
            }
        }

        // 4. Once a day.
        if dailyDue(.reminder, config, now), showReminderFromList(items, config, force: false) {
            markDaily(.reminder, now)
        }
    }

    private func isOverdue(_ item: ReminderItem, _ now: Date) -> Bool {
        guard let due = item.due else { return false }
        // A reminder with only a date is overdue once that day is over.
        return item.hasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }

    // MARK: Once a day

    private func dailyKey(_ kind: TaskKind) -> String { "taskPopupDaily.\(kind.rawValue)" }

    private func dayStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// True from the chosen time until two hours later, once per day.
    private func dailyDue(_ kind: TaskKind, _ config: TaskPopupConfig, _ now: Date) -> Bool {
        guard config.daily,
              let at = Calendar.current.date(bySettingHour: config.dailyMinutes / 60,
                                             minute: config.dailyMinutes % 60,
                                             second: 0, of: now),
              now >= at, now < at.addingTimeInterval(2 * 3600) else { return false }
        return UserDefaults.standard.string(forKey: dailyKey(kind)) != dayStamp(now)
    }

    private func markDaily(_ kind: TaskKind, _ now: Date) {
        UserDefaults.standard.set(dayStamp(now), forKey: dailyKey(kind))
    }

    // MARK: Unlock

    private func unlocked() {
        locked = false
        // v429: the intervals are NOT reset here any more. They were, so that an unlock pop-up would not be followed by
        // another one; that setting no longer exists, and the reset made every pop-up wait a whole interval again after
        // each unlock (a Mac that is unlocked more often than the interval never showed them).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.showOnUnlock()
        }
    }

    private func showOnUnlock() {
        guard !locked else { return }
        if Preferences.todoEnabled {
            let config = TaskPopupPrefs.todo
            if config.enabled, config.unlock { _ = showTodo(TodoStore.shared.openItems, config, force: false) }
        } else if Preferences.remindersEnabled {
            let config = TaskPopupPrefs.reminders
            if config.enabled, config.unlock {
                _ = showReminderFromList(RemindersStore.shared.items, config, force: false)
            }
        }
    }

    // MARK: Showing

    private func showTodo(_ items: [TodoItem], _ config: TaskPopupConfig, force: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        if config.order == "cycle" {
            // One by one: every to-do in turn, as they are listed in the notch.
            let activities = items.prefix(Self.sequenceLimit).enumerated().map { entry in
                LiveActivity.task(kind: .todo, title: entry.element.title, detail: "\(entry.offset + 1) of \(items.count)")
            }
            return playSequence(Array(activities), force: force)
        }
        let index = config.order == "newest" ? 0 : items.count - 1
        return show(.task(kind: .todo, title: items[index].title, detail: "\(items.count) open"), config.seconds, force)
    }

    private func showReminderFromList(_ items: [ReminderItem], _ config: TaskPopupConfig, force: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        let now = Date()
        // The store keeps them soonest first (overdue ones on top), then the ones without a date.
        if config.order == "cycle" {
            let activities = items.prefix(Self.sequenceLimit).enumerated().map { entry in
                reminderActivity(entry.element, now: now, position: "\(entry.offset + 1) of \(items.count)")
            }
            return playSequence(Array(activities), force: force)
        }
        return showReminder(items[0], now: now, config: config, position: nil, force: force)
    }

    private func reminderActivity(_ item: ReminderItem, now: Date, position: String?) -> LiveActivity {
        var detail = TaskPopupText.reminderDetail(item, now: now)
        if let position { detail += " \u{00B7} \(position)" }
        let title = item.title.isEmpty ? "Untitled reminder" : item.title
        return .task(kind: .reminder, title: title, detail: detail)
    }

    private func showReminder(_ item: ReminderItem, now: Date, config: TaskPopupConfig,
                              position: String?, force: Bool) -> Bool {
        show(reminderActivity(item, now: now, position: position), config.seconds, force)
    }

    /// Shows the tasks one after another, 3 seconds each. Each card replaces the one before it a moment before
    /// that one would end, so the notch does not close in between.
    private func playSequence(_ activities: [LiveActivity], force: Bool) -> Bool {
        guard let first = activities.first else { return false }
        sequenceTask?.cancel()
        let step = Self.sequenceSeconds
        guard show(first, activities.count > 1 ? step + 0.3 : step, force) else {
            sequencePlaying = false
            return false
        }
        sequencePlaying = true
        let rest = Array(activities.dropFirst())
        sequenceTask = Task { @MainActor [weak self] in
            for (offset, activity) in rest.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.locked {
                    self.sequencePlaying = false
                    return
                }
                let last = offset == rest.count - 1
                _ = self.show(activity, last ? step : step + 0.3, true)
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sequencePlaying = false
        }
        return true
    }

    // MARK: "Show now" in settings

    private func preview(_ raw: String?) {
        if raw == TaskKind.reminder.rawValue {
            let config = TaskPopupPrefs.reminders
            // v429: the list is read first and the pop-up follows when it has arrived (it used to show the old list).
            RemindersStore.shared.activate()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self else { return }
                if !self.showReminderFromList(RemindersStore.shared.items, config, force: true) {
                    _ = self.show(.task(kind: .reminder, title: "Your reminders show up here", detail: "Preview"),
                                  config.seconds, true)
                }
            }
        } else {
            let config = TaskPopupPrefs.todo
            if !showTodo(TodoStore.shared.openItems, config, force: true) {
                _ = show(.task(kind: .todo, title: "Your tasks show up here", detail: "Preview"),
                         config.seconds, true)
            }
        }
    }
}

// MARK: - In the notch

/// One task: its icon, the title and a second line (what list it is from, and when it is due).
struct TaskCardRow: View {
    let kind: TaskKind
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(kind.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(kind.label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(kind.color)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The pop-up under the closed notch (downline style), the same card as the volume bar and the Bluetooth name.
struct TaskDownlineView: View {
    let kind: TaskKind
    let title: String
    let detail: String
    let notchHeight: CGFloat
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            TaskCardRow(kind: kind, title: title, detail: detail)
                .padding(.horizontal, 34)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 4)
                .offset(y: shown ? 0 : 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.15)) { shown = true } }
    }
}

/// The same pop-up in the strip that hangs below the OPEN notch.
struct TaskStrip: View {
    let kind: TaskKind
    let title: String
    let detail: String

    var body: some View {
        TaskCardRow(kind: kind, title: title, detail: detail)
            .padding(.horizontal, 46)
            .padding(.top, 2)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Settings

private struct MinutesPickerRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @Binding var value: Int
    let options: [(Int, String)]

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            Picker("", selection: $value) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }
}

/// v496: a time field (hour and minute) with no background or border, so it sits on the row like the other pickers.
private struct ClearTimeField: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .hourMinute
        picker.isBordered = false
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.backgroundColor = .clear
        picker.alignment = .right
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.dateValue = date
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ClearTimeField
        init(_ parent: ClearTimeField) { self.parent = parent }
        @objc func changed(_ sender: NSDatePicker) { parent.date = sender.dateValue }
    }
}

/// "Daily at 9:00 AM": the switch and the time on one row.
private struct DailyAtRow: View {
    @Binding var on: Bool
    @Binding var minutes: Int

    private var date: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { newValue in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        })
    }

    var body: some View {
        SettingRow(symbol: "sunrise.fill", tint: Theme.orange, title: "Every day at") {
            HStack(spacing: 12) {
                // v496: no field background, like the other pickers on this page.
                ClearTimeField(date: date)
                    .frame(width: 84, height: 22)
                    .disabled(!on)
                    .opacity(on ? 1 : 0.45)
                PremiumSwitch(isOn: $on)
            }
        }
    }
}

private struct PopupPreviewRow: View {
    let kind: TaskKind

    var body: some View {
        SettingRow(symbol: "play.circle.fill", tint: Theme.green, title: "Preview") {
            ActionButton(title: "Show now", symbol: "bell") {
                NotificationCenter.default.post(name: .indraTaskPopupPreview, object: kind.rawValue)
            }
        }
    }
}

private let popupEveryOptions: [(Int, String)] = [
    (0, "Never"), (15, "Every 15 min"), (30, "Every 30 min"), (60, "Every hour"),
    (120, "Every 2 hours"), (240, "Every 4 hours")
]

/// To-do pop-ups: on or off, how often, a daily time, and which to-do.
struct TodoPopupCard: View {
    @AppStorage(TaskPopupPrefs.todoOnKey) private var enabled = false
    @AppStorage(TaskPopupPrefs.todoEveryKey) private var every = 60
    @AppStorage(TaskPopupPrefs.todoDailyKey) private var daily = false
    @AppStorage(TaskPopupPrefs.todoDailyTimeKey) private var dailyMinutes = 540
    @AppStorage(TaskPopupPrefs.todoOrderKey) private var order = "oldest"

    var body: some View {
        SettingsCard("Notch pop-ups") {
            ToggleRow(symbol: "bell.fill", tint: Theme.orange,
                      title: "Show pop-ups", isOn: $enabled)
            Group {
                RowDivider()
                MinutesPickerRow(symbol: "repeat", tint: Theme.blue, title: "Repeat",
                                 value: $every, options: popupEveryOptions)
                RowDivider()
                DailyAtRow(on: $daily, minutes: $dailyMinutes)
                RowDivider()
                SettingRow(symbol: "list.number", tint: Theme.teal, title: "Show") {
                    SegmentedChoice([("oldest", "Oldest first"), ("newest", "Newest first"), ("cycle", "All in turn")],
                                    selection: $order)
                        .frame(width: 260)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            RowDivider()
            PopupPreviewRow(kind: .todo)
        }
        .animation(.smooth(duration: 0.25), value: enabled)
    }
}

/// Reminder pop-ups: at the due time, a heads-up before, nudges while overdue, a daily time, and which reminder.
struct ReminderPopupCard: View {
    @AppStorage(TaskPopupPrefs.remOnKey) private var enabled = false
    @AppStorage(TaskPopupPrefs.remDueKey) private var onDue = true
    @AppStorage(TaskPopupPrefs.remAheadKey) private var ahead = 10
    @AppStorage(TaskPopupPrefs.remOverdueKey) private var overdue = 15
    @AppStorage(TaskPopupPrefs.remDailyKey) private var daily = false
    @AppStorage(TaskPopupPrefs.remDailyTimeKey) private var dailyMinutes = 540
    @AppStorage(TaskPopupPrefs.remOrderKey) private var order = "soonest"

    private let aheadOptions: [(Int, String)] = [
        (0, "Off"), (5, "5 min before"), (10, "10 min before"), (15, "15 min before"),
        (30, "30 min before"), (60, "1 hour before")
    ]
    private let overdueOptions: [(Int, String)] = [
        (0, "Never"), (5, "Every 5 min"), (10, "Every 10 min"), (15, "Every 15 min"),
        (30, "Every 30 min"), (60, "Every hour")
    ]

    var body: some View {
        SettingsCard("Notch pop-ups") {
            ToggleRow(symbol: "bell.fill", tint: Theme.yellow,
                      title: "Show pop-ups", isOn: $enabled)
            Group {
                RowDivider()
                ToggleRow(symbol: "alarm.fill", tint: Theme.orange,
                          title: "When due", isOn: $onDue)
                RowDivider()
                MinutesPickerRow(symbol: "clock.badge.fill", tint: Theme.blue, title: "Heads-up",
                                 value: $ahead, options: aheadOptions)
                RowDivider()
                MinutesPickerRow(symbol: "exclamationmark.circle.fill", tint: Theme.red, title: "When overdue",
                                 value: $overdue, options: overdueOptions)
                RowDivider()
                DailyAtRow(on: $daily, minutes: $dailyMinutes)
                RowDivider()
                SettingRow(symbol: "list.number", tint: Theme.teal, title: "Show") {
                    SegmentedChoice([("soonest", "Most urgent first"), ("cycle", "All in turn")], selection: $order)
                        .frame(width: 220)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            RowDivider()
            PopupPreviewRow(kind: .reminder)
        }
        .animation(.smooth(duration: 0.25), value: enabled)
    }
}

private let alarmDelayOptions: [(Int, String)] = [
    (1, "1 min"), (5, "5 min"), (10, "10 min"), (15, "15 min"), (30, "30 min"),
    (60, "1 hour"), (120, "2 hours"), (240, "4 hours"), (480, "8 hours"), (1440, "1 day")
]

/// "Alarm": pick one to-do (or reminder) and when it pops up, from 1 minute to 1 day from now.
struct TaskAlarmCard: View {
    let kind: TaskKind
    @ObservedObject private var alarms = TaskAlarmStore.shared
    @ObservedObject private var todo = TodoStore.shared
    @ObservedObject private var reminders = RemindersStore.shared
    @State private var chosen = ""
    @State private var minutes = 15

    private var noun: String { kind == .todo ? "to-do" : "reminder" }

    private var choices: [(String, String)] {
        if kind == .todo {
            return todo.openItems.map { ($0.id.uuidString, $0.title) }
        }
        return reminders.items.map { ($0.id, $0.title.isEmpty ? "Untitled reminder" : $0.title) }
    }

    private var pending: [TaskAlarm] {
        alarms.alarms.filter { $0.kind == kind.rawValue }
    }

    private func whenText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        SettingsCard("Alarm") {
            SettingRow(symbol: "checklist", tint: kind.color, title: kind == .todo ? "To-do" : "Reminder") {
                Picker("", selection: $chosen) {
                    Text("Choose a \(noun)").tag("")
                    ForEach(0..<choices.count, id: \.self) { index in
                        Text(choices[index].1).lineLimit(1).tag(choices[index].0)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            RowDivider()
            SettingRow(symbol: "alarm.fill", tint: Theme.orange, title: "After") {
                HStack(spacing: 10) {
                    Picker("", selection: $minutes) {
                        ForEach(0..<alarmDelayOptions.count, id: \.self) { index in
                            Text(alarmDelayOptions[index].1).tag(alarmDelayOptions[index].0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    ActionButton(title: "Set", symbol: "alarm") {
                        guard let entry = choices.first(where: { $0.0 == chosen }) else { return }
                        alarms.add(kind: kind, itemID: entry.0, title: entry.1, afterMinutes: minutes)
                        chosen = ""
                    }
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.45 : 1)
                }
            }
            ForEach(pending) { alarm in
                RowDivider()
                SettingRow(symbol: "bell.badge.fill", tint: kind.color, title: alarm.title,
                           subtitle: "Pops up at \(whenText(alarm.fireAt))") {
                    ActionButton(title: "Cancel", symbol: "xmark", kind: .destructive) {
                        alarms.remove(alarm)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: pending.count)
    }
}
