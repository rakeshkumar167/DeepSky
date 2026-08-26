import Foundation

public struct CapturePlan: Sendable, Codable, Hashable {
    public var sensorExposure: ShutterSpeed
    public var intervalSeconds: Double
    public var frameCount: Int

    public init(sensorExposure: ShutterSpeed, intervalSeconds: Double, frameCount: Int) {
        self.sensorExposure = sensorExposure
        self.intervalSeconds = intervalSeconds
        self.frameCount = frameCount
    }

    /// What the stack is *equivalent* to. Always presented alongside the
    /// sensor exposure, never in place of it (spec §27).
    public var effectiveExposureSeconds: Double {
        sensorExposure.seconds * Double(frameCount)
    }

    /// Wall-clock duration the user will stand in the cold for.
    public var totalCaptureSeconds: Double {
        (sensorExposure.seconds + intervalSeconds) * Double(frameCount)
    }

    /// Spec §6: the user picks a total; frame count is derived. Rounds
    /// down so the session never runs longer than the requested total.
    public static func solve(totalCaptureSeconds: Double,
                             sensorExposure: ShutterSpeed,
                             intervalSeconds: Double) -> CapturePlan {
        let perFrame = sensorExposure.seconds + intervalSeconds
        let count: Int
        if perFrame > 0 && totalCaptureSeconds.isFinite {
            let quotient = (totalCaptureSeconds / perFrame).rounded(.down)
            if quotient >= Double(Int.max) {
                count = Int.max
            } else if quotient <= Double(Int.min) {
                count = Int.min
            } else {
                count = Int(quotient)
            }
        } else {
            count = 1
        }
        return CapturePlan(sensorExposure: sensorExposure,
                           intervalSeconds: intervalSeconds,
                           frameCount: max(1, count))
    }
}
