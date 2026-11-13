import Foundation

/// v495: the two small debug logs (FaceLock/debug.log and debug.log) only ever appended, so they grew for as long as the
/// Mac was in use. Before appending, a file past `maxBytes` is cut down to its newest `keepBytes`, on a line boundary.
enum LogTrim {
    static let maxBytes = 512 * 1024
    static let keepBytes = 128 * 1024

    static func trimIfNeeded(_ file: URL) {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > maxBytes, let data = try? Data(contentsOf: file) else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: file, options: .atomic)
    }
}
