import AVFoundation

/// Owns the camera. A fresh capture session is created every time the Mirror opens and
/// torn down when it closes, so reopening can never show a stale, blank preview.
@MainActor
final class MirrorController: ObservableObject {
    @Published private(set) var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var session: AVCaptureSession?
    /// False while the box only shows "Click to activate mirror"; true from the click until the box closes.
    @Published private(set) var activated = false

    private let queue = DispatchQueue(label: "indra.mirror.session")
    private var errorObserver: NSObjectProtocol?
    /// True between start() and stop(). A permission answer that arrives after the Mirror was closed
    /// must not switch the camera on with nothing to show it.
    private var wanted = false

    func start() {
        activated = true
        wanted = true
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        status = current
        switch current {
        case .authorized:
            run()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
                if granted, wanted { run() }
            }
        default:
            break
        }
    }

    /// Camera on -> off, off -> on. The box stays open either way (off shows "Click to activate mirror" again).
    func toggle() {
        if activated { stop() } else { start() }
    }

    func stop() {
        activated = false
        wanted = false
        if let token = errorObserver {
            NotificationCenter.default.removeObserver(token)
            errorObserver = nil
        }
        guard let old = session else { return }
        session = nil
        queue.async {
            old.stopRunning()
            old.beginConfiguration()
            for input in old.inputs { old.removeInput(input) }
            old.commitConfiguration()
        }
    }

    private func run() {
        guard session == nil else { return }
        let fresh = AVCaptureSession()
        session = fresh
        let serial = queue
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: fresh,
                                                               queue: nil) { [weak fresh] _ in
            serial.async {
                guard let running = fresh, !running.isRunning else { return }
                running.startRunning()
            }
        }
        serial.async {
            MirrorController.startWithRetries(fresh)
        }
    }

    /// The camera can still be busy for a moment after the previous Mirror closed, which used to
    /// leave an empty circle. Try again a few times instead of giving up.
    nonisolated private static func startWithRetries(_ session: AVCaptureSession) {
        for attempt in 0..<5 {
            if session.inputs.isEmpty { configure(session) }
            session.startRunning()
            if session.isRunning { return }
            Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
        }
    }

    nonisolated private static func configure(_ session: AVCaptureSession) {
        session.beginConfiguration()
        session.sessionPreset = .medium
        let device = AVCaptureDevice.default(for: .video)
            ?? AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                mediaType: .video,
                                                position: .unspecified).devices.first
        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
    }
}
