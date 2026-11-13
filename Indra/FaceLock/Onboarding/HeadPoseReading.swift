//
//  HeadPoseReading.swift
//  Indra Face Lock
//
//  v491: the head turn (yaw, pitch) used by guided enrollment. Vision's own reading is used when it has one; when it
//  gives none (or only one of the two), the missing angle is estimated from the face landmarks (where the nose sits
//  between the eyes and the mouth), so a turned head is never read as "no pose".
//

import Vision
import CoreGraphics

nonisolated struct HeadPoseReading: Sendable {
    /// Radians. Same signs as Vision: +yaw = the head turned to the user's left, +pitch = looking down.
    let yaw: Float
    let pitch: Float

    static func read(_ face: DetectedFace) -> HeadPoseReading? {
        let estimate = estimate(from: face.landmarks)
        guard let yaw = face.yaw ?? estimate?.yaw, let pitch = face.pitch ?? estimate?.pitch else { return nil }
        return HeadPoseReading(yaw: yaw, pitch: pitch)
    }

    private static func estimate(from landmarks: VNFaceLandmarks2D?) -> HeadPoseReading? {
        guard let landmarks,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let nose = landmarks.nose, let lips = landmarks.outerLips,
              let eyeA = centre(of: leftEye), let eyeB = centre(of: rightEye),
              let noseTip = centre(of: nose), let mouth = centre(of: lips) else { return nil }

        let eyeMid = CGPoint(x: (eyeA.x + eyeB.x) / 2, y: (eyeA.y + eyeB.y) / 2)
        let eyeGap = hypot(eyeA.x - eyeB.x, eyeA.y - eyeB.y)
        let eyeToMouth = eyeMid.y - mouth.y
        guard eyeGap > 0.01, eyeToMouth > 0.01 else { return nil }

        // Sideways: how far the nose sits from the middle of the eyes, in eye gaps. The picture is not mirrored, so the
        // nose moving to the right of the picture is a turn to the user's left (+yaw).
        let sideways = Double((noseTip.x - eyeMid.x) / eyeGap)
        let yaw = asin(min(max(sideways / 0.65, -1), 1))

        // Up and down: where the nose sits on the line from the eyes to the mouth (about 0.55 when looking straight).
        // Looking down brings the nose lower; looking up raises it.
        let ratio = Double((eyeMid.y - noseTip.y) / eyeToMouth)
        let pitch = (ratio - 0.55) * 1.4
        return HeadPoseReading(yaw: Float(yaw), pitch: Float(pitch))
    }

    private static func centre(of region: VNFaceLandmarkRegion2D) -> CGPoint? {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
