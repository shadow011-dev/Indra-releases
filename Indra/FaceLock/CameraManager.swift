//
//  CameraManager.swift
//  Indra Face Lock
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage. Runs entirely on-device.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
struct CameraFrame {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.indra.Indra.camera.session")

    /// Handed to the delegate outside the actor; only ever touched via `Task { @MainActor ... }`.
    private let framePublisher = FramePublisher()

    /// v491: bumped by every start() and stop(), so a watchdog or recovery that belongs to an older run goes inert.
    private var generation = 0
    /// When the newest frame arrived; the watchdog restarts a session that stops delivering frames.
    private var lastFrameAt: ContinuousClock.Instant?
    private var watchdog: Task<Void, Never>?
    /// True after stop() or a failed run: the next start puts a brand-new input on the session. Re-using the input of a
    /// stopped session is what left the preview black (no frames) when setup was cancelled and started again.
    private var needsFreshInput = false
    private var runtimeErrorObserver: NSObjectProtocol?
    /// v495: bumped by stop(). start() waits for the camera permission prompt, which can stay up for a long time; a stop()
    /// that happened meanwhile used to be ignored, and the camera then started with nothing left that would turn it off.
    private var stopCount = 0

    override init() {
        super.init()
        framePublisher.owner = self
    }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let stopsBefore = stopCount
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
            guard stopCount == stopsBefore else { return }
        default:
            permission = .denied
        }

        guard permission == .granted else {
            errorMessage = "Camera access not granted (status: \(describe(status))). " +
                (status == .restricted
                    ? "macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time content restrictions or an MDM/profile policy is blocking camera access for this app; toggling it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted."
                    : "Enable it in System Settings > Privacy & Security > Camera. If Indra isn't listed there, quit the app, run `tccutil reset Camera com.indra.Indra` in Terminal, then relaunch so macOS asks again.")
            return
        }

        errorMessage = nil
        generation += 1
        let run = generation
        configureSessionIfNeeded()
        observeRuntimeErrors()
        reconcileDeviceIfNeeded()

        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
        isRunning = true
        lastFrameAt = nil
        startWatchdog(run: run)
    }

    /// v498: puts the camera input on the session ahead of time (no light, no picture, nothing runs). On the lock screen the
    /// notch calls this while it waits, so a hover or the space key only has to start the session instead of building the
    /// input first, which blocked for a noticeable time on the main thread. Does nothing while the camera is running.
    func prepare() {
        guard !isRunning, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let previousError = errorMessage
        configureSessionIfNeeded()
        reconcileDeviceIfNeeded()
        errorMessage = previousError
    }

    func stop() {
        stopCount &+= 1
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
        isRunning = false
        currentFrame = nil
        lastFrameAt = nil
        needsFreshInput = true
    }

    // MARK: - v491: a camera that stops delivering frames is restarted

    /// Checks every second that frames keep arriving. If none came for a while (the preview shows black, or the capture
    /// froze in the middle of setup), the input is replaced with a fresh one and the session is started again.
    private func startWatchdog(run: Int) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            var attempts = 0
            try? await Task.sleep(for: .seconds(1.4))
            while !Task.isCancelled {
                guard let self, self.generation == run, self.isRunning else { return }
                let stale = self.lastFrameAt.map { ContinuousClock.now - $0 > .seconds(1.2) } ?? true
                if stale {
                    attempts += 1
                    if attempts > 8 {
                        self.errorMessage = "The camera is not sending pictures. Close other apps that use it and try again."
                        return
                    }
                    self.recover(run: run)
                } else {
                    attempts = 0
                }
                try? await Task.sleep(for: .seconds(stale ? 1.6 : 1.0))
            }
        }
    }

    /// Fresh input, stop, start. Runs on the main actor; the session calls themselves stay on the session queue.
    private func recover(run: Int) {
        guard generation == run, isRunning else { return }
        FaceLockLog.note("Camera recovery: no frames, rebuilding the capture input")
        needsFreshInput = true
        reconcileDeviceIfNeeded()
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
            session.startRunning()
        }
    }

    private func observeRuntimeErrors() {
        guard runtimeErrorObserver == nil else { return }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.recover(run: self.generation)
            }
        }
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
        // `activeFormat`, so leaving this at `.high` and locking the format separately below is sufficient.
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Called on every `start()` so a camera preference change in Settings takes effect without an app restart.
    private func reconcileDeviceIfNeeded() {
        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "No camera device found."
            return
        }
        guard needsFreshInput || currentInput == nil || device.uniqueID != currentInput?.device.uniqueID else { return }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        // Anything else left on the session (an input a failed run left behind) goes too.
        for input in session.inputs { session.removeInput(input) }
        currentInput = nil
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            needsFreshInput = false
            selectHighestResolutionFormat(for: device)
        } else {
            currentInput = nil
            errorMessage = "No camera device found."
        }
        session.commitConfiguration()
    }

    /// Highest resolution regardless of fps — Vision still works from the downscaled frame; this only affects
    /// what `CameraFrame.source` (and therefore `renderCrop`) has to work with.
    private func selectHighestResolutionFormat(for device: AVCaptureDevice) {
        let best = device.formats.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
        guard let best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            errorMessage = "Couldn't select the camera's highest-resolution format: \(error.localizedDescription)"
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        // v491: a frame that was still on its way when stop() ran must not bring the picture back.
        guard isRunning else { return }
        lastFrameAt = .now
        currentFrame = frame
    }

    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for spoof-cue extraction which
    /// needs pixel detail (screen texture, moiré, gloss) the downscaled working frame throws away.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Expand ~1.3x so device edges/bezels are captured for texture/moiré cues.
        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    /// `CIContext` is expensive to create and safe to reuse concurrently. Explicitly `nonisolated` since a `static let`
    /// on this `@MainActor` class would otherwise be main-actor-isolated, which the `nonisolated renderCrop` can't touch.
    private nonisolated static let cropRenderContext = SharedCI.context

    /// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there, then hops back.
    private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        private let ciContext = SharedCI.context
        /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
        /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceExtent = sourceImage.extent
            var ciImage = sourceImage
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(
                id: nextFrameID,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size
            )

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
