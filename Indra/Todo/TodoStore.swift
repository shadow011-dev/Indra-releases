import Foundation

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// Ticked off: it stays in the list (struck through and faded) until you delete it.
    var done = false

    init(title: String) {
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// Indra's own to-do list (separate from the Reminders app). Stored on this Mac only.
@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = []

    private let defaultsKey = "todoItems"
    private let maxItems = 200

    private init() {
        load()
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, items.count < maxItems else { return }
        items.insert(TodoItem(title: trimmed), at: 0)
        save()
    }

    /// The to-dos that are not ticked off (what the pop-ups and alarms work with).
    var openItems: [TodoItem] { items.filter { !$0.done } }

    /// Ticks a to-do off, or puts it back when it is ticked again. It stays where it is.
    func toggleDone(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].done.toggle()
        save()
    }

    func delete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
