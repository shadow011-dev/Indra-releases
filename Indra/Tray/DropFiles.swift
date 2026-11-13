import AppKit

/// v485: reads the files of a drag without ever letting the system leave a copy of them on the Desktop.
///
/// Reading the dragged items with `readObjects(forClasses: [NSURL.self])` is fine for real files (Finder), but when the
/// drag carries file PROMISES (Mail, Safari, Photos, a browser download bubble, Messages ...) that call makes the sending
/// app write the file to a default place, which was the Desktop: dropping a file on AirDrop or Blip left a copy there.
/// Now:
///  - files that already exist on disk are taken exactly as they are (no copy at all);
///  - promised files are received on purpose, into a private temporary folder of Indra that is cleaned up later.
@MainActor
enum DropFiles {
    /// v490: every pasteboard type that marks an item as a file PROMISE (the sender writes the file only when asked).
    /// An item carrying any of them is never read as a file URL: asking for its URL is exactly what made the sender write
    /// a copy to the Desktop. v485 looked at the plain URLs first, and a promise also lists a file URL among its types,
    /// so the copy was still made.
    static let promiseTypes: [NSPasteboard.PasteboardType] = {
        var names = NSFilePromiseReceiver.readableDraggedTypes
        names += ["com.apple.NSFilePromiseItemMetaData",
                  "com.apple.pasteboard.promised-file-url",
                  "com.apple.pasteboard.promised-file-content-type",
                  "com.apple.pasteboard.promised-suggested-file-name",
                  "NSFilesPromisePboardType",
                  "Apple files promise pasteboard type"]
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { NSPasteboard.PasteboardType($0) }
    }()

    /// v491: picture data a browser or an app drags (no file behind it). If the drop windows do not register for these,
    /// they are no valid target and macOS hands the drop to whatever is under the pointer: the Desktop, which then
    /// writes the picture there as a new file (a copy on the Desktop next to the notch's own copy).
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("public.webp")
    ]

    /// Everything the notch's drop windows register for: real files, promised files and dragged pictures.
    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")] + promiseTypes + imageTypes
    }

    private static func isPromise(_ item: NSPasteboardItem) -> Bool {
        let types = item.types
        return promiseTypes.contains { types.contains($0) }
    }

    /// True when the drag carries any promised file. Only looks at the declared types; never asks the sender for data.
    static func hasPromises(in pasteboard: NSPasteboard) -> Bool {
        (pasteboard.pasteboardItems ?? []).contains { isPromise($0) }
    }

    /// True when the drag carries files of any kind (real or promised). Only looks at the declared types.
    static func hasFiles(in pasteboard: NSPasteboard) -> Bool {
        for item in pasteboard.pasteboardItems ?? [] {
            let types = item.types
            if isPromise(item) || types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) {
                return true
            }
            if types.contains(where: { imageTypes.contains($0) }) { return true }
        }
        return false
    }

    /// Real files on disk: the items that carry a file URL themselves (and are not promises).
    static func plainFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            // A promise is received on purpose (see `receive`); its file URL must never be requested.
            guard !isPromise(item) else { continue }
            guard item.types.contains(.fileURL),
                  let text = item.string(forType: .fileURL),
                  let url = URL(string: text), url.isFileURL else { continue }
            let resolved = (url as NSURL).filePathURL ?? url
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            if !urls.contains(resolved) { urls.append(resolved) }
        }
        return urls
    }

    /// v500: the file URLs a drag declares, whether or not the files are still where they were (a drop that went to the
    /// Desktop has already moved them). Promises are skipped, and the sender is never asked for a file.
    static func declaredFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard !isPromise(item), item.types.contains(.fileURL),
                  let text = item.string(forType: .fileURL),
                  let url = URL(string: text), url.isFileURL else { continue }
            let resolved = ((url as NSURL).filePathURL ?? url).standardizedFileURL
            if !urls.contains(resolved) { urls.append(resolved) }
        }
        return urls
    }

    /// The promises of the drag (empty for a plain Finder drag).
    static func promiseReceivers(in pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        guard hasPromises(in: pasteboard) else { return [] }
        return (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// Older drags that offer neither of the above (a list of paths): the classic reader. Never used when the drag has any
    /// promise, because this reader would make the sender write the file to the Desktop.
    static func legacyFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        guard !hasPromises(in: pasteboard) else { return [] }
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// v491: a dragged picture that has no file behind it (an image dragged out of a web page). It is written into
    /// Indra's private folder (never the Desktop) and handled like a dropped file.
    static func imageFiles(in pasteboard: NSPasteboard) -> [URL] {
        guard let folder = makeFolder() else { return [] }
        var urls: [URL] = []
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            guard let type = imageTypes.first(where: { item.types.contains($0) }),
                  let data = item.data(forType: type), !data.isEmpty else { continue }
            let ext: String
            switch type.rawValue {
            case "public.jpeg": ext = "jpg"
            case "public.heic": ext = "heic"
            case "com.compuserve.gif": ext = "gif"
            case "public.webp": ext = "webp"
            default: ext = "png"
            }
            var output = data
            var name = ext
            if type == .tiff, let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                output = png
                name = "png"
            }
            let url = folder.appendingPathComponent("Image \(index + 1).\(name)")
            if (try? output.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }

    // MARK: - Receiving promised files

    /// Asks every promise to write its file into a private folder and calls `done` (on the main thread) with the files
    /// once all of them have arrived, or with what has arrived after 30 seconds. Never touches the Desktop.
    static func receive(_ receivers: [NSFilePromiseReceiver], done: @escaping ([URL]) -> Void) {
        guard !receivers.isEmpty, let folder = makeFolder() else { done([]); return }
        let batch = Batch(expected: receivers.reduce(0) { $0 + max($1.fileNames.count, 1) }, done: done)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                MainActor.assumeIsolated { batch.arrived(error == nil ? url : nil) }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            batch.finish()
        }
    }

    @MainActor
    private final class Batch {
        private var urls: [URL] = []
        private var count = 0
        private var finished = false
        private let expected: Int
        private let done: ([URL]) -> Void

        init(expected: Int, done: @escaping ([URL]) -> Void) {
            self.expected = expected
            self.done = done
        }

        func arrived(_ url: URL?) {
            count += 1
            if let url { urls.append(url) }
            if count >= expected { finish() }
        }

        func finish() {
            guard !finished else { return }
            finished = true
            done(urls)
        }
    }

    // MARK: - Private folder

    private static var prunedThisLaunch = false

    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("IndraDrops", isDirectory: true)
    }

    /// v554: a fresh private folder (same place and same clean-up as received files) for a file Indra makes for a share: the zip of a
    /// dropped folder or app (see DropArchive).
    static func privateFolder() -> URL? { makeFolder() }

    private static func makeFolder() -> URL? {
        let fm = FileManager.default
        if !prunedThisLaunch {
            prunedThisLaunch = true
            prune()
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// Received files older than a day are removed (they are only needed while they are being sent).
    private static func prune() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-24 * 3600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < limit { try? fm.removeItem(at: entry) }
        }
    }
}
