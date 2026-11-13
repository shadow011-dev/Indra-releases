import AppKit
import Foundation

enum MediaSource: String, Sendable {
    case music
    case spotify
    /// Any other app that reports to macOS "Now Playing" (browsers, YouTube, VLC ...).
    case system
    /// Recognised from system audio; cannot be controlled.
    case identified

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .system: return ""
        case .identified: return ""
        }
    }
}

enum RepeatMode: Sendable {
    case off, all, one
}

/// Plain playback data parsed off the main thread.
struct RawPlayback: Sendable {
    var source: MediaSource
    var state: String
    var title: String
    var artist: String
    var album: String
    var durationMs: Double?
    var positionSec: Double?
}

struct TrackInfo: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var isPlaying: Bool
    /// Playback position at `positionDate`.
    var position: TimeInterval
    var positionDate: Date
    /// For `.system` tracks: the app that is playing (Safari, Google Chrome ...).
    var appBundleID: String? = nil
    /// Whether the lock screen may open the vinyl, queue and lyrics view for this track.
    /// Always true: every song, video and audio that is playing can open it.
    var vinyl: Bool = true

    var identity: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    func elapsed(at date: Date) -> TimeInterval {
        let base = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        let floored = max(base, 0)
        return duration > 0 ? min(floored, duration) : floored
    }
}

/// A small image cache that evicts old pictures, so a long listening session cannot grow without limit.
/// v523: limited by bytes as well as by count (rule 5 in AGENTS.md). 80 covers of 900 px are 260 MB; a count alone let a long
/// session hold that much. The oldest pictures go first, and the newest is always kept. A cover that was dropped is read
/// again from the disk cache (or the player) the next time its song comes back.
final class BoundedImageCache<Key: Hashable> {
    private var images: [Key: NSImage] = [:]
    private var costs: [Key: Int] = [:]
    private var order: [Key] = []
    private var totalBytes = 0
    private let limit: Int
    private let byteLimit: Int

    init(limit: Int, byteLimit: Int = 48 * 1024 * 1024) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    /// What the picture takes in memory once decoded (pixels x 4 bytes).
    private static func cost(of image: NSImage) -> Int {
        var pixels = 0
        for rep in image.representations { pixels = max(pixels, rep.pixelsWide * rep.pixelsHigh) }
        if pixels <= 0 {
            let area = image.size.width * image.size.height
            pixels = area.isFinite && area > 0 ? Int(min(area, 100_000_000)) : 0
        }
        return pixels * 4
    }

    private func remove(_ key: Key) {
        images[key] = nil
        totalBytes -= costs.removeValue(forKey: key) ?? 0
        order.removeAll { $0 == key }
    }

    subscript(key: Key) -> NSImage? {
        get { images[key] }
        set {
            guard let newValue else {
                remove(key)
                return
            }
            if images[key] != nil { remove(key) }
            let cost = BoundedImageCache.cost(of: newValue)
            images[key] = newValue
            costs[key] = cost
            order.append(key)
            totalBytes += cost
            while order.count > limit || (totalBytes > byteLimit && order.count > 1) {
                remove(order[0])
            }
        }
    }
}
