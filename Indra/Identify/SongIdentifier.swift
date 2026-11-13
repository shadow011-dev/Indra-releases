import AppKit
import AVFAudio
import ShazamKit

struct IdentifiedSong: Sendable {
    let title: String
    let artist: String
    let artworkURL: URL?
}

/// Thread-safe peak level, written from the audio queue and read on the main actor.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func note(_ level: Float) {
        lock.lock()
        if level > value { value = level }
        lock.unlock()
    }

    func take() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = 0
        return current
    }
}

/// Identifies whatever is playing on the Mac (browser video, any app) like Canopy:
/// short listening windows, a pause, repeat. Only runs while nothing is playing in
/// Apple Music or Spotify, and stops completely when switched off.
@MainActor
final class SongIdentifier: NSObject, ObservableObject, SHSessionDelegate {
    enum Phase: Equatable {
        case idle
        case listening
        case failed(String)
    }

    enum Outcome {
        case matched
        case noMatch
        case silent
        case failed(String)
        /// Nothing wrong, just not possible right now (no display while the screen sleeps): try again later.
        case unavailable
    }

    @Published private(set) var phase: Phase = .idle
    weak var media: MediaController?

    private let capture = SystemAudioCapture()
    private let meter = LevelMeter()
    private var session: SHSession?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var isAutomatic = false
    private var missCount = 0

    // MARK: - Automatic mode

    func setAutomatic(_ on: Bool) {
        guard on != isAutomatic else { return }
        isAutomatic = on
        autoTask?.cancel()
        autoTask = nil
        if on {
            phase = .idle
            autoTask = Task { [weak self] in
                await self?.autoLoop()
            }
        } else {
            resolve(.noMatch)
            phase = .idle
        }
    }

    private func autoLoop() async {
        while !Task.isCancelled {
            let source = media?.track?.source
            if (source == nil || source == .identified), SystemAudioCapture.screenIsAvailable {
                switch await listenOnce(seconds: 12) {
                case .matched:
                    break
                case .silent:
                    missCount = 0
                    media?.clearIdentified()
                case .noMatch:
                    missCount += 1
                    if missCount >= 2 { media?.clearIdentified() }
                case .unavailable:
                    break   // the normal pause below, then try again
                case .failed:
                    // Permission or ShazamKit problem: stop trying until switched off and on again.
                    return
                }
            }
            let pause: Double = media?.track?.source == .identified ? 25 : 45
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
    }

    // MARK: - One listening window

    private func listenOnce(seconds: Double) async -> Outcome {
        guard continuation == nil else { return .noMatch }
        phase = .listening
        _ = meter.take()

        let session = SHSession()
        session.delegate = self
        self.session = session
        let meter = self.meter
        capture.onBuffer = { [weak session] buffer in
            session?.matchStreamingBuffer(buffer, at: nil)
            meter.note(SongIdentifier.peak(of: buffer))
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            continuation = cont
            Task {
                do {
                    try await capture.start()
                } catch {
                    if case AudioCaptureError.notAllowed = error {
                        // Not a fault: the permission has simply not been given (yet). The Media settings page
                        // shows an Allow button, so this is only noted, not saved as a problem.
                        IndraLog.crumb("Song identify: Screen & System Audio Recording is not allowed")
                    } else if case AudioCaptureError.noDisplay = error {
                        // Screen asleep or locked: not a fault. Noted, and tried again after the usual pause.
                        IndraLog.crumb("Song identify: no display available, will try again")
                        resolve(.unavailable)
                        return
                    } else {
                        IndraLog.error("Song identify: could not start system audio capture", error)
                    }
                    resolve(.failed("Allow Indra under Screen & System Audio Recording in System Settings."))
                }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.resolve(self.meter.take() < 0.003 ? .silent : .noMatch)
            }
        }
    }

    private func resolve(_ outcome: Outcome) {
        guard let pending = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        capture.onBuffer = nil
        session = nil
        let capture = self.capture
        Task { await capture.stop() }
        if case .failed(let message) = outcome {
            phase = .failed(message)
        } else {
            phase = .idle
        }
        pending.resume(returning: outcome)
    }

    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var peak: Float = 0
        var index = 0
        while index < count {
            peak = max(peak, abs(samples[index]))
            index += 4
        }
        return peak
    }

    // MARK: - SHSessionDelegate (called on arbitrary queues)

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        let song = IdentifiedSong(title: item.title ?? "Unknown",
                                  artist: item.artist ?? "",
                                  artworkURL: item.artworkURL)
        Task { @MainActor [weak self] in
            self?.matched(song)
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // No match without an error just means "keep listening".
        guard let error else { return }
        let nsError = error as NSError
        let message = nsError.code == 202
            ? "Song ID unavailable: ShazamKit is not enabled for this app build."
            : error.localizedDescription
        Task { @MainActor [weak self] in
            self?.resolve(.failed(message))
        }
    }

    private func matched(_ song: IdentifiedSong) {
        guard continuation != nil else { return }
        // A real player took over while we were listening: leave it alone.
        if let source = media?.track?.source, source != .identified {
            resolve(.noMatch)
            return
        }
        missCount = 0
        media?.showIdentified(song, artwork: nil)
        resolve(.matched)

        guard let url = song.artworkURL else { return }
        Task {
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: result.0) else { return }
            media?.setIdentifiedArtwork(image, for: song)
        }
    }
}
