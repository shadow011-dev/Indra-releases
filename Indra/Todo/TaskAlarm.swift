import Foundation

/// One alarm: "pop this to-do / reminder up in the notch at this time".
struct TaskAlarm: Identifiable, Codable, Equatable {
    var id = UUID()
    /// `TaskKind.rawValue`.
    var kind: String
    /// The to-do's id (its UUID as text) or the reminder's EventKit id.
    var itemID: String
    /// The title when the alarm was set; the live title is used when it goes off.
    var title: String
    var fireAt: Date
}

/// The alarms the user set in To Do settings, kept on this Mac. An alarm goes off once and is then removed. One
/// alarm per task: setting a new one for the same task replaces the old one.
@MainActor
final class TaskAlarmStore: ObservableObject {
    static let shared = TaskAlarmStore()

    @Published private(set) var alarms: [TaskAlarm] = []

    private let defaultsKey = "taskAlarms"
    private let maxAlarms = 50

    private init() {
        load()
    }

    func add(kind: TaskKind, itemID: String, title: String, afterMinutes minutes: Int) {
        let alarm = TaskAlarm(kind: kind.rawValue, itemID: itemID, title: title,
                              fireAt: Date().addingTimeInterval(Double(minutes) * 60))
        alarms.removeAll { $0.kind == alarm.kind && $0.itemID == alarm.itemID }
        guard alarms.count < maxAlarms else { return }
        alarms.append(alarm)
        alarms.sort { $0.fireAt < $1.fireAt }
        save()
    }

    func remove(_ alarm: TaskAlarm) {
        alarms.removeAll { $0.id == alarm.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TaskAlarm].self, from: data) else { return }
        alarms = decoded.sorted { $0.fireAt < $1.fireAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
