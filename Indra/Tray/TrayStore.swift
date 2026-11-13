import AppKit

struct TrayItem: Identifiable {
    let id = UUID()
    let url: URL
    let bookmark: Data
    /// True when `startAccessingSecurityScopedResource` succeeded and must be balanced.
    let scoped: Bool
    let icon: NSImage

    var name: String { url.lastPathComponent }
}

/// Files held in the notch. Persisted as app-scoped security bookmarks only
/// (no broad disk access, no copies of the files).
@MainActor
final class TrayStore: ObservableObject {
    @Published private(set) var items: [TrayItem] = []

    static let maxItems = 30
    private let defaultsKey = "trayBookmarks"

    init() {
        load()
    }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls where url.isFileURL {
            let standard = url.standardizedFileURL
            guard items.count < TrayStore.maxItems,
                  !items.contains(where: { $0.url.standardizedFileURL == standard }) else { continue }
            // A secure bookmark keeps the file in the tray across launches. If macOS refuses to
            // create one, the file still goes into the tray for this session.
            let data = (try? url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)) ?? Data()
            let scoped = data.isEmpty ? false : url.startAccessingSecurityScopedResource()
            items.append(TrayItem(url: url, bookmark: data, scoped: scoped, icon: TrayStore.icon(for: url)))
            changed = true
        }
        if changed { persist() }
    }

    func remove(_ item: TrayItem) {
        // The tile leaves first; the bookkeeping happens after the screen has updated.
        items.removeAll { $0.id == item.id }
        persist()
        if item.scoped {
            let url = item.url
            DispatchQueue.global(qos: .utility).async { url.stopAccessingSecurityScopedResource() }
        }
    }

    func removeAll() {
        let scopedURLs = items.filter { $0.scoped }.map { $0.url }
        items.removeAll()
        persist()
        DispatchQueue.global(qos: .utility).async {
            for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] else { return }
        for data in stored.prefix(TrayStore.maxItems) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            guard FileManager.default.fileExists(atPath: url.path) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                continue
            }
            var fresh = data
            if stale,
               let renewed = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) {
                fresh = renewed
            }
            items.append(TrayItem(url: url, bookmark: fresh, scoped: scoped, icon: TrayStore.icon(for: url)))
        }
        persist()
    }

    /// Saved off the main thread, so removing files never waits for the disk.
    private func persist() {
        let data = items.map(\.bookmark).filter { !$0.isEmpty }
        let key = defaultsKey
        DispatchQueue.global(qos: .utility).async {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func icon(for url: URL) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 44, height: 44)
        return image
    }
}
