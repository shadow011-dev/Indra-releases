import Foundation

/// Tiny text log at ~/Library/Application Support/Indra/FaceLock/debug.log, safe to call from any thread.
enum FaceLockLog {
    private static let queue = DispatchQueue(label: "indra.facelock.debuglog")

    static func note(_ text: String) {
        let line = "\(Date()) \(text)\n"
        queue.async {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let dir = base.appendingPathComponent("Indra", isDirectory: true).appendingPathComponent("FaceLock", isDirectory: true)
            let file = dir.appendingPathComponent("debug.log")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            LogTrim.trimIfNeeded(file)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
