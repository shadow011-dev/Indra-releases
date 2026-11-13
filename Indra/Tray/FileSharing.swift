import AppKit

@MainActor
enum FileSharing {
    static let blipBundleID = "net.blip.macos"

    static var trayDragStartedAt = Date.distantPast
    /// True while a file that was picked up from the tray is still being dragged.
    static var isDraggingFromTray: Bool {
        Date().timeIntervalSince(trayDragStartedAt) < 30 && NSEvent.pressedMouseButtons & 1 != 0
    }

    /// v546: while this is in the future a file is being handed to Blip / AirDrop: Indra moves no window between Spaces and
    /// inspects no other process (see `blip`). Only ever grows.
    private(set) static var handoffUntil = Date.distantPast
    static var isHandingOff: Bool { Date() < handoffUntil }
    static func beginHandoff(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if until > handoffUntil { handoffUntil = until }
    }

    /// v546: runs `body` only after the drag that delivered the files is completely over: the mouse button is up, the drop
    /// callback has returned, and the notch has had a moment to close. Blip used to be launched INSIDE the drop callback, with
    /// the drag session still open and the notch's windows still changing; the launch brings another app to the front at that
    /// very moment, and the window server was then left waiting for a drag that never finished (the whole-Mac freeze after
    /// "blip: handed to Blip"). Never more than 3 s of waiting, whatever the mouse does.
    private static func afterDragEnded(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let started = Date()
            try? await Task.sleep(nanoseconds: 700_000_000)
            while NSEvent.pressedMouseButtons != 0, Date().timeIntervalSince(started) < 3 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            body()
        }
    }

    /// Resolved once per launch.
    static let blipURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: blipBundleID)

    /// v534: the files of a drop that macOS moved to the Desktop are not at their own paths any more; they are taken from the
    /// Desktop (in the background) so the share does not show "no file found".
    ///
    /// v554: (1) only files that really exist are handed over (before, a file that could not be found was still handed to Blip /
    /// AirDrop, which is what their error windows are made of); when none is left nothing is started and the notch just closes.
    /// (2) A dropped folder or app is handed over as one zip (see DropArchive).
    private static func withExistingFiles(_ urls: [URL], zip scope: DropArchive.Scope,
                                          _ body: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var files = urls
            if !urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                files = await DesktopCopyGuard.resolved(urls)
            }
            let usable = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !usable.isEmpty else {
                Trace.log("SHARE: none of the \(urls.count) dropped file(s) could be found; nothing was sent")
                FreezeTrail.mark("share: no file found, nothing started")
                NotificationCenter.default.post(name: .indraAirDropFinished, object: nil)
                return
            }
            if usable.count < urls.count {
                Trace.log("SHARE: \(urls.count - usable.count) of \(urls.count) dropped file(s) could not be found and were left out")
            }
            let handOver = await DropArchive.prepared(usable, scope: scope)
            // v558: what really goes to AirDrop / Blip, written down (a zip in Indra's folder, or the item as it is).
            for item in handOver {
                Trace.log("SHARE: handing over \"\(item.lastPathComponent)\" (\(item.pathExtension.isEmpty ? "no extension" : item.pathExtension))")
            }
            body(handOver)
        }
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else {
            // Nothing in the tray: open the AirDrop window instead.
            let airDropApp = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
            NSWorkspace.shared.open(airDropApp)
            return
        }
        TrackpadActuator.shared.stayQuiet(for: 180, why: "send to AirDrop")
        beginHandoff(for: 30)   // v546: see `blip`
        FreezeTrail.mark("airdrop: \(urls.count) file(s) handed over")
        FreezeTrail.beginHeartbeat(for: 60, why: "send to AirDrop")
        // v553: the files are looked for AFTER the drag has ended (not before the wait): a drop that macOS moved to the Desktop
        // does so a moment after the release, and a path taken before that moment was already out of date when it was used.
        afterDragEnded {
            withExistingFiles(urls, zip: .packagesOnly) { files in
                NSApp.activate()
                guard let service = NSSharingService(named: .sendViaAirDrop) else {
                    NotificationCenter.default.post(name: .indraAirDropFinished, object: nil)
                    return
                }
                // Cancelling the picker, finishing, or failing all end the same way: the notch closes at once.
                airDropSession = AirDropSession()
                service.delegate = airDropSession
                airDropService = service
                service.perform(withItems: files)
            }
        }
    }

    private static var airDropSession: AirDropSession?
    private static var airDropService: NSSharingService?

    /// True while Blip is running.
    static var isBlipRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: blipBundleID).isEmpty
    }

    static func blip(_ urls: [URL]) {
        guard let appURL = blipURL else { return }
        guard !urls.isEmpty else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // v544: from the moment the files are handed over, until well after Blip has taken them, nothing of the private trackpad
        // driver is touched (see TrackpadActuator.stayQuiet) and every step is written to the freeze trail.
        // v546: the same for window-server Space changes (`handoffUntil`), and Blip is opened after the drag is over.
        TrackpadActuator.shared.stayQuiet(for: 180, why: "send to Blip")
        beginHandoff(for: 30)
        FreezeTrail.mark("blip: \(urls.count) file(s) handed over")
        FreezeTrail.beginHeartbeat(for: 60, why: "send to Blip")
        // v553: the files are looked for AFTER the drag has ended (see `airDrop`): "no file found" in Blip came from a path that
        // was read before the drop had finished moving the file.
        afterDragEnded {
            withExistingFiles(urls, zip: .foldersAndPackages) { files in
                FreezeTrail.mark("blip: opening Blip with \(files.count) file(s)")
                // v552: Indra never closes Blip (the "Close Blip after sending" option and the watch of the Blip process are gone).
                openInBlip(files, app: appURL)
                FreezeTrail.mark("blip: handed to Blip")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    NotificationCenter.default.post(name: .indraAirDropFinished, object: nil)
                }
            }
        }
    }

    /// v548: Blip is opened by the system's own `open` tool in a separate process, started from a background task. Whatever
    /// LaunchServices or the window server do while another app is launched and brought to the front, Indra's main thread is not
    /// the one that talks to them. (If `open` cannot be started, the normal call is used.)
    ///
    /// v553: sending to Blip failed "sometimes, in the first and second try". Three things are done about it, none of which looks
    /// into the Blip process (that was the whole-Mac freeze):
    ///  - a Blip that is NOT running is started first, given a moment to get ready, and only then handed the files (files that came
    ///    with the launch itself could be lost);
    ///  - the answer of the `open` tool is read: when it did not take the files it is tried again (up to 3 times), then the normal call;
    ///  - the files are looked for after the drag is over (see `blip`), and a file taken from the Desktop stays there for 20 minutes.
    private static func openInBlip(_ files: [URL], app appURL: URL) {
        let paths = files.map { $0.standardizedFileURL.path }   // absolute paths only, so none can look like an option
        let appPath = appURL.path
        let wasRunning = isBlipRunning
        Task { @MainActor in
            if !wasRunning {
                _ = await runOpen(app: appPath, paths: [])
                FreezeTrail.mark("blip: started, waiting until it is ready")
                var waited = 0
                while !isBlipRunning, waited < 40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waited += 1
                }
                // The app is up; its window and its file handler need a moment more.
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
            for attempt in 1...3 {
                if await runOpen(app: appPath, paths: paths) {
                    FreezeTrail.mark("blip: open started in its own process (try \(attempt))")
                    return
                }
                FreezeTrail.mark("blip: open tool did not take the files (try \(attempt))")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            FreezeTrail.mark("blip: open tool failed, using NSWorkspace")
            NSWorkspace.shared.open(files, withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    /// Runs `/usr/bin/open -a <app> <paths>` in its own process and says whether it finished without an error. Nothing waits for
    /// it on the main thread: the answer comes from the process's termination handler, and it is stopped after 20 s.
    nonisolated private static func runOpen(app: String, paths: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", app] + paths
            // v558: what the open tool says when it fails goes to the trace (a file, never a pipe that could fill up).
            let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("indra-open-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: errorFile.path, contents: nil)
            let errorHandle = try? FileHandle(forWritingTo: errorFile)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle ?? FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let watchdog = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if process.isRunning { process.terminate() }
            }
            process.terminationHandler = { finished in
                watchdog.cancel()
                try? errorHandle?.close()
                if finished.terminationStatus != 0 {
                    let text = ((try? String(contentsOf: errorFile, encoding: .utf8)) ?? "")
                        .replacingOccurrences(of: "\n", with: " ")
                    Trace.log("SHARE: open exited with \(finished.terminationStatus): \(text.isEmpty ? "no message" : String(text.prefix(300)))")
                }
                try? FileManager.default.removeItem(at: errorFile)
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                watchdog.cancel()
                try? errorHandle?.close()
                try? FileManager.default.removeItem(at: errorFile)
                Trace.log("SHARE: the open tool could not be started: \(error.localizedDescription)")
                continuation.resume(returning: false)
            }
        }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension Notification.Name {
    /// The AirDrop picker was cancelled, finished or failed.
    static let indraAirDropFinished = Notification.Name("indraAirDropFinished")
}

final class AirDropSession: NSObject, NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        // v554: the reason AirDrop gave (the window only says "Unknown error") goes to the trace.
        let reason = error as NSError
        Trace.log("AIRDROP failed: \(reason.domain) \(reason.code) \(reason.localizedDescription)")
        finish()
    }

    private func finish() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .indraAirDropFinished, object: nil)
        }
    }
}
