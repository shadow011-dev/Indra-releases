import AppKit

/// v554: a dropped folder or app (.app and other packages) is handed to Blip / AirDrop as ONE zip file, made by the system's own
/// `ditto` tool (the same way Finder's "Compress" does it).
///
/// Why: both sharing paths were seen failing only when the dropped item was an app bundle (Indra.app): AirDrop ended with
/// "Sending to ... failed (Unknown error)" and Blip showed its own "unexpected error (error code -8060)" window. A package is a
/// folder that looks like one file, and neither sender is built to walk through one. A single zip is an ordinary file for both.
///
/// What this never does (see AGENTS.md):
///  - nothing waits on the main thread: the zip is made by a separate process, started from a background task, and the answer
///    comes from its termination handler; it is stopped after 180 seconds (the original is handed over then);
///  - nothing looks into another app's process;
///  - the zip goes into Indra's private folder (`DropFiles.privateFolder`, cleaned up after a day), never to the Desktop;
///  - if anything goes wrong the original item is handed over exactly as before.
@MainActor
enum DropArchive {
    enum Scope {
        /// Blip: every folder and every package is sent as a zip.
        case foldersAndPackages
        /// AirDrop: only packages (an .app ...) are sent as a zip; a plain folder travels the way it always did.
        case packagesOnly
    }

    /// The items to hand over: each folder / package that needs it replaced by its zip, everything else unchanged.
    static func prepared(_ urls: [URL], scope: Scope) async -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard await needsZip(url, scope: scope) else {
                result.append(url)
                continue
            }
            guard let folder = DropFiles.privateFolder() else {
                result.append(url)
                continue
            }
            let zip = folder.appendingPathComponent(url.lastPathComponent + ".zip")
            FreezeTrail.mark("share: zipping \"\(url.lastPathComponent)\"")
            if await makeZip(of: url, to: zip) {
                Trace.log("SHARE: \"\(url.lastPathComponent)\" is a folder / package and goes as a zip")
                FreezeTrail.mark("share: zip ready")
                result.append(zip)
            } else {
                try? FileManager.default.removeItem(at: folder)
                Trace.log("SHARE: could not zip \"\(url.lastPathComponent)\"; it goes as it is")
                FreezeTrail.mark("share: zip failed, original used")
                result.append(url)
            }
        }
        return result
    }

    /// True for a folder or package that must go as a zip. Looked at in the background.
    private static func needsZip(_ url: URL, scope: Scope) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            if values.isSymbolicLink == true { return false }
            guard values.isDirectory == true else { return false }
            switch scope {
            case .packagesOnly: return values.isPackage == true
            case .foldersAndPackages: return true
            }
        }.value
    }

    /// v558: the zip is made by the system's `ditto` (what Finder's Compress uses); when that does not produce a file, by `/usr/bin/zip`
    /// (links kept as links). Whatever each tool says on its error output is written to the trace, so a send that still shows the
    /// raw app in AirDrop / Blip says WHY the zip was not made. Nothing waits for them on the main thread.
    nonisolated private static func makeZip(of source: URL, to destination: URL) async -> Bool {
        let errors = destination.deletingLastPathComponent().appendingPathComponent("zip-error.txt")
        let viaDitto = await run("/usr/bin/ditto",
                                 ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path],
                                 in: nil, errors: errors)
        if viaDitto, fileSize(destination) > 0 { return true }
        Trace.log("SHARE: ditto could not zip \"\(source.lastPathComponent)\": \(note(errors))")
        try? FileManager.default.removeItem(at: destination)

        let viaZip = await run("/usr/bin/zip",
                               ["-q", "-r", "-y", destination.path, source.lastPathComponent],
                               in: source.deletingLastPathComponent(), errors: errors)
        if viaZip, fileSize(destination) > 0 { return true }
        Trace.log("SHARE: zip could not zip \"\(source.lastPathComponent)\": \(note(errors))")
        try? FileManager.default.removeItem(at: destination)
        return false
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// The first part of what a tool wrote on its error output, on one line.
    nonisolated private static func note(_ file: URL) -> String {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "no message" : String(line.prefix(300))
    }

    /// Runs one tool in its own process and says whether it finished without an error. Its error output goes to a file (never a
    /// pipe that could fill up and hold the tool). It is stopped after 180 seconds.
    nonisolated private static func run(_ tool: String, _ arguments: [String], in directory: URL?, errors: URL) async -> Bool {
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let errorHandle = try? FileHandle(forWritingTo: errors)
        let finished: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle ?? FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let watchdog = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                if process.isRunning { process.terminate() }
            }
            process.terminationHandler = { done in
                watchdog.cancel()
                continuation.resume(returning: done.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                watchdog.cancel()
                continuation.resume(returning: false)
            }
        }
        try? errorHandle?.close()
        return finished
    }
}
