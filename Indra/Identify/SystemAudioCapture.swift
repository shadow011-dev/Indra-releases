import AVFAudio
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum AudioCaptureError: Error, LocalizedError {
    /// No display was available (screen asleep, locked, or still waking up). Temporary: not a fault.
    case noDisplay
    /// Screen & System Audio Recording has not been allowed for this build of Indra.
    case notAllowed

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display was available for audio capture."
        case .notAllowed: return "Screen & System Audio Recording is not allowed."
        }
    }
}

/// Captures system audio only (video is reduced to a 1 fps, 16x16 stub that is discarded).
/// Needs the "Screen & System Audio Recording" permission.
extension SystemAudioCapture {
    /// False while the display is asleep or the Mac is locked: there is nothing to capture then, and macOS reports
    /// no display. Listening simply waits for the next round instead of failing.
    static var screenIsAvailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any],
           (info["CGSSessionScreenIsLocked"] as? Bool) == true { return false }
        return true
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "indra.audio.capture")
    /// Bumped by every start and stop. A start that finishes after a stop must shut its stream down
    /// again, otherwise the capture keeps running (and allocating buffers) forever.
    private let lock = NSLock()
    private var generation = 0

    private func beginStart() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    /// Keeps the stream when no stop arrived meanwhile; returns false when it is stale.
    private func commit(_ stream: SCStream, generation mine: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == mine else { return false }
        self.stream = stream
        return true
    }

    private func takeStream() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        let current = stream
        stream = nil
        return current
    }

    /// Called on a background queue with each chunk of audio.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called when macOS ends the capture by itself (display sleep, lock, a display change).
    var onStop: (@Sendable () -> Void)?

    func start() async throws {
        let mine = beginStart()
        // Never trigger the macOS permission prompt from the background; the Media settings page has an Allow button.
        guard CGPreflightScreenCaptureAccess() else { throw AudioCaptureError.notAllowed }
        // Right after launch, wake or unlock the display list can still be empty: look again a couple of times.
        var display: SCDisplay?
        for attempt in 0..<3 {
            // The first look uses on-screen windows only; later looks drop that filter, which still lists the display
            // while a screen saver or the lock screen is covering the windows.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: attempt == 0)
            display = content.displays.first
            if display != nil { break }
            if attempt < 2 { try await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        guard let display else { throw AudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 44100
        config.channelCount = 2
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if !commit(stream, generation: mine) {
            try? await stream.stopCapture()
        }
    }

    func stop() async {
        guard let stream = takeStream() else { return }
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let buffer = SystemAudioCapture.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        _ = takeStream()
        onStop?()
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var streamDescription = basic.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                                  at: 0,
                                                                  frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
