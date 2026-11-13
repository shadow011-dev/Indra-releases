import AppKit

/// v500: undoes what a drop on the notch can do to the Desktop.
///
/// When a dragged file is released and none of Indra's windows takes the drop at that very moment, macOS hands the drop to
/// the Desktop and Finder puts the file there. On the same disk that is a MOVE, not a copy: the file leaves its folder, so
/// deleting the "copy" on the Desktop deleted the only file (v498/v499 only handled a real copy, and never fired).
///
/// For every file that was dragged to the notch, for about a minute, this looks for a file of the same name that was just
/// added to the Desktop (and is not the original itself) and:
///  - the original is gone from its folder (it was moved)  -> the file is moved straight back to where it came from;
///  - the original is still there (it was a real copy)     -> the copy on the Desktop goes to the Trash.
/// Only the Desktop's top level is looked at. Nothing is ever deleted for good. If macOS has not allowed Indra to read the
/// Desktop, nothing happens.
///
/// v534: (1) apps (.app), other packages, folders and links are handled too: before, only a plain file of the same size
/// counted as the copy, so a copied .app (or any folder) stayed on the Desktop. A folder or package counts as the copy when
/// it has the same top-level contents. (2) The copy is dealt with 2 s after it is first seen, not at once: sending it to
/// Blip / AirDrop right at the drop sometimes showed "no file found" because the file had just been moved under it.
/// (3) A copy that Finder renamed ("name 2") is found as well. (4) If the original was moved to the Desktop and a share
/// (Blip / AirDrop) was started from it, it is not moved back for 20 minutes (see `resolved`; v553: it was 30 s, which could
/// take the file from under a transfer that was still running, so Blip failed "sometimes").
@MainActor
enum DesktopCopyGuard {
    /// What the original is, to tell a real duplicate from an unrelated file with the same name.
    private enum Kind: Sendable, Equatable {
        case file(size: Int64)
        /// A folder or a package (.app, .pages, ...): its top-level names.
        case folder(fingerprint: String)
        case link
        /// Already left its folder, or could not be read: it can never be matched as a copy.
        case other
    }

    private struct Entry: Sendable {
        let name: String
        let origin: String
        let kind: Kind
        /// When the stray file was first seen on the Desktop.
        var seenAt: Date?
    }

    /// How long the stray file stays after it is first seen.
    nonisolated private static let settle: TimeInterval = 2

    private static var lastKey = ""
    private static var lastAt = Date.distantPast

    static func watch(sources: [URL], since: Date) {
        guard !sources.isEmpty,
              let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let desktopPath = desktop.resolvingSymlinksInPath().standardizedFileURL.path

        // The same drop is reported by several places; one watcher per drop is enough.
        let key = sources.map { $0.standardizedFileURL.path }.sorted().joined(separator: "|")
        if key == lastKey, Date().timeIntervalSince(lastAt) < 3 { return }
        lastKey = key
        lastAt = Date()

        var entries: [Entry] = []
        for url in sources {
            let origin = url.standardizedFileURL
            // A file that itself lives on the Desktop cannot have been put there by the drop.
            guard origin.deletingLastPathComponent().resolvingSymlinksInPath().path != desktopPath else { continue }
            entries.append(Entry(name: origin.lastPathComponent, origin: origin.path, kind: kind(of: origin), seenAt: nil))
        }
        guard !entries.isEmpty else { return }
        let notBefore = max(since.addingTimeInterval(-1), Date().addingTimeInterval(-180))
        let toFind = entries

        // In the background: the first look at the Desktop can make macOS ask for permission, and that question blocks
        // whichever thread asks. It must never be Indra's main thread.
        Task.detached(priority: .utility) {
            var remaining = toFind
            // v544: 12 quick looks, then 20 slow ones (it was 80 looks, 20 of them every quarter second, at the Desktop folder,
            // which may be an iCloud folder that is busy while a file moves). The first look waits half a second.
            for round in 0..<32 {
                try? await Task.sleep(nanoseconds: round < 12 ? 500_000_000 : 2_000_000_000)
                var next: [Entry] = []
                for index in remaining.indices {
                    var entry = remaining[index]
                    if !fix(&entry, desktop: desktop, notBefore: notBefore) { next.append(entry) }
                }
                remaining = next
                if remaining.isEmpty { break }
            }
            // v553: a file that a share is reading from the Desktop is looked at again every 10 s until its hold has run out
            // (the quick rounds above end after about 46 s, long before a big transfer is over).
            while !remaining.isEmpty {
                let holdEnd = remaining.compactMap { desktopCopyHolds.until($0.origin) }.max() ?? .distantPast
                guard holdEnd.addingTimeInterval(10) > Date() else { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                var next: [Entry] = []
                for index in remaining.indices {
                    var entry = remaining[index]
                    if !fix(&entry, desktop: desktop, notBefore: notBefore) { next.append(entry) }
                }
                remaining = next
            }
            Trace.log("DROP guard finished: \(toFind.count - remaining.count) of \(toFind.count) Desktop files put right")
        }
    }

    /// The paths to hand to Blip / AirDrop for the dropped files. A file that the drop MOVED to the Desktop is no longer at
    /// its own path, and a share started from that path shows "no file found": the file is taken from the Desktop instead
    /// (waiting up to 1.5 s for it to arrive), and is not moved back for 20 minutes so the share can read it. Runs in the background.
    static func resolved(_ urls: [URL]) async -> [URL] {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return urls }
        return await Task.detached(priority: .userInitiated) { () -> [URL] in
            var result: [URL] = []
            for url in urls {
                if FileManager.default.fileExists(atPath: url.path) { result.append(url); continue }
                let notBefore = Date().addingTimeInterval(-180)
                var hit: URL?
                for _ in 0..<6 {
                    hit = recentOnDesktop(named: url.lastPathComponent, desktop: desktop, notBefore: notBefore)?.url
                    if hit != nil { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if let hit {
                    desktopCopyHolds.set(url.standardizedFileURL.path, until: Date().addingTimeInterval(20 * 60))
                    Trace.log("DROP: \"\(url.lastPathComponent)\" was moved to the Desktop by the drop; the share uses it from there")
                    result.append(hit)
                } else {
                    result.append(url)
                }
            }
            return result
        }.value
    }

    nonisolated private static func kind(of url: URL) -> Kind {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .other }
        if values.isSymbolicLink == true { return .link }
        if values.isDirectory == true {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return .other }
            return .folder(fingerprint: "\(names.count):" + names.sorted().prefix(64).joined(separator: "/"))
        }
        if values.isRegularFile == true, let bytes = values.fileSize { return .file(size: Int64(bytes)) }
        return .other
    }

    /// The names Finder gives a file that lands next to one with the same name: "name.ext", then "name 2.ext".
    nonisolated private static func names(for name: String) -> [String] {
        let text = name as NSString
        let ext = text.pathExtension
        let base = text.deletingPathExtension
        return ext.isEmpty ? [name, "\(name) 2"] : [name, "\(base) 2.\(ext)"]
    }

    /// A file of that name (or Finder's renamed one) added to the Desktop after `notBefore`.
    nonisolated private static func recentOnDesktop(named name: String, desktop: URL, notBefore: Date) -> (url: URL, added: Date)? {
        let fm = FileManager.default
        for candidateName in names(for: name) {
            let candidate = desktop.appendingPathComponent(candidateName)
            guard fm.fileExists(atPath: candidate.path),
                  let values = try? candidate.resourceValues(forKeys: [.addedToDirectoryDateKey]),
                  let added = values.addedToDirectoryDate, added >= notBefore else { continue }
            return (candidate, added)
        }
        return nil
    }

    /// True when the file was found on the Desktop and handled.
    nonisolated private static func fix(_ entry: inout Entry, desktop: URL, notBefore: Date) -> Bool {
        let fm = FileManager.default
        let originExists = fm.fileExists(atPath: entry.origin)
        var found: URL?
        for candidateName in names(for: entry.name) {
            guard let hit = recentOnDesktop(named: candidateName, desktop: desktop, notBefore: notBefore)?.url,
                  hit.standardizedFileURL.path != entry.origin else { continue }
            // A real copy: only something of the same kind and content counts as the duplicate.
            if originExists, entry.kind == .other || kind(of: hit) != entry.kind { continue }
            found = hit
            break
        }
        guard let found else { return false }

        // The stray file stays for a moment (see the notes at the top), counted from when it was first seen.
        let seen = entry.seenAt ?? Date()
        entry.seenAt = seen
        guard Date().timeIntervalSince(seen) >= settle else { return false }

        if originExists {
            do {
                try fm.trashItem(at: found, resultingItemURL: nil)
                Trace.log("DROP: the copy of \"\(entry.name)\" left on the Desktop was moved to the Trash")
                return true
            } catch { return false }
        }

        // The original is gone: the drop MOVED it to the Desktop. Put it back where it came from (not while a share that
        // started from the Desktop file may still be reading it).
        if let until = desktopCopyHolds.until(entry.origin), until > Date() { return false }
        let origin = URL(fileURLWithPath: entry.origin)
        guard fm.fileExists(atPath: origin.deletingLastPathComponent().path) else { return false }
        do {
            try fm.moveItem(at: found, to: origin)
            Trace.log("DROP: \"\(entry.name)\" was moved to the Desktop by the drop and has been put back in its folder")
            return true
        } catch { return false }
    }
}

/// Files that must not be moved back yet (a share is reading them from the Desktop). Safe to use from any thread.
private final class DesktopCopyHoldStore: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [String: Date] = [:]

    func set(_ path: String, until date: Date) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        dates = dates.filter { $0.value > now }
        dates[path] = date
    }

    func until(_ path: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return dates[path]
    }
}

private let desktopCopyHolds = DesktopCopyHoldStore()
