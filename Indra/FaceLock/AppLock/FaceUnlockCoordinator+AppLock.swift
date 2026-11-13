import Foundation
import CoreGraphics

enum AppLockFaceResult {
    case matched, wrongFace, spoofSuspected, noFace, unavailable, cancelled
}

/// Numbers each app-lock scan so a cancelled scan can't touch the camera of a newer one.
enum AppLockScanGate {
    static var generation = 0
    /// Number of scans currently inside runAppLockFaceScan (so the last one out switches the camera off).
    static var running = 0
}

extension FaceUnlockCoordinator {
    /// True when a face check for app lock can run right now.
    var canScanFaceForAppLock: Bool {
        guard !LockMonitor.isScreenActuallyLocked() else { return false }
        AppLockIdentityCache.refresh()
        return !AppLockIdentityCache.identities.isEmpty
    }

    /// Same recognition + liveness as the lock-screen scan, but never types a password.
    func runAppLockFaceScan(duration: TimeInterval, generation: Int) async -> AppLockFaceResult {
        guard canScanFaceForAppLock else { return .unavailable }

        NSLog("AppLock: scan %ld starting camera", generation)
        AppLockScanGate.running += 1
        // The newest scan, or the last scan to finish, switches the camera off. A scan that was cancelled while the
        // camera was still starting used to leave it running (and the Mac's edge light on) with nothing on screen.
        defer {
            AppLockScanGate.running -= 1
            if (generation == AppLockScanGate.generation || AppLockScanGate.running <= 0),
               !LockMonitor.isScreenActuallyLocked() {
                camera.stop()
            }
        }
        // v555: the notch is opening right now. Building the camera input runs on the main thread and used to land in the middle of
        // that opening (the stutter of the scan animation). It now waits until the opening spring has settled; the scan still has
        // its whole time (the deadline starts after this).
        if FaceLockSettings.shared.showUnlockAnimation, NotchOverlayController.shared.phase == .scanning {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard generation == AppLockScanGate.generation else { return .cancelled }
        }
        await camera.start()
        guard generation == AppLockScanGate.generation else { return .cancelled }
        if let error = camera.errorMessage {
            NSLog("AppLock: camera error %@", error)
            return .unavailable
        }

        let deadline = Date().addingTimeInterval(duration)
        let wrongFaceGrace: Duration = .seconds(2)
        let livenessEnabled = FaceLockSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { FaceLockSettings.shared.livenessMode }

        var wrongFaceStartedAt: ContinuousClock.Instant?
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        // The frame already sitting in the camera when the scan starts can be seconds old (from an earlier scan). Never judge
        // it: a match must come from a frame captured after this scan began.
        var lastProcessedFrameID: UInt64? = camera.currentFrame?.id
        // v490: if nothing new arrives from the camera for a moment (something else switched it off right after it started,
        // as the lock screen's own scan could after a face unlock), start it again, a few times at most.
        var lastFrameAt = Date()
        var cameraRestarts = 0

        while Date() < deadline, !Task.isCancelled, generation == AppLockScanGate.generation {
            guard !LockMonitor.isScreenActuallyLocked() else { return .cancelled }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                if cameraRestarts < 3, Date().timeIntervalSince(lastFrameAt) > 1.2 {
                    cameraRestarts += 1
                    lastFrameAt = Date()
                    NSLog("AppLock: scan %ld got no camera picture, starting the camera again (%ld)", generation, cameraRestarts)
                    await camera.start()
                    guard generation == AppLockScanGate.generation else { return .cancelled }
                    if camera.errorMessage != nil { return .unavailable }
                    continue
                }
                // v543: three restarts and still no picture: the camera is not working (another app holds it, it was switched
                // off by the system). Say so now, instead of running the animation to the end with nothing to look at.
                if cameraRestarts >= 3, Date().timeIntervalSince(lastFrameAt) > 1.6 {
                    Trace.log("APPLOCK SCAN: no camera picture after \(cameraRestarts) restarts: camera unavailable")
                    return .unavailable
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id
            lastFrameAt = Date()

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let ringLit = RingLight.shared.isLit   // v543: read here, on the main actor
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop, ignoreGlare: ringLit))
            }.value

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied: return .spoofSuspected
                case .confirmed: livenessConfirmed = true
                case .pending: break
                }
            }

            let scored = pipeline.score(result.embedding, against: AppLockIdentityCache.identities)
            if let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold) {
                wrongFaceStartedAt = nil
                readyMatch = matched
            } else {
                readyMatch = nil
                if wrongFaceStartedAt == nil { wrongFaceStartedAt = .now }
                if ContinuousClock.now - wrongFaceStartedAt! >= wrongFaceGrace { return .wrongFace }
            }

            if readyMatch != nil, livenessConfirmed { return .matched }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return generation == AppLockScanGate.generation ? .noFace : .cancelled
    }
}
