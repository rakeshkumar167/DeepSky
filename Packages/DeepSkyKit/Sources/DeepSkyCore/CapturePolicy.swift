import Foundation

public enum CaptureDecision: Sendable, Equatable {
    case proceed
    case pause(reason: String)
    case stop(reason: String)
}

public enum CapturePolicy {
    /// 15% headroom for frame-size variance, plus a fixed reserve so the
    /// device never fills its disk completely.
    static let headroomMultiplier = 1.15
    static let reserveBytes: Int64 = 500 * 1_048_576

    public static func storageRequirement(plan: CapturePlan, bytesPerFrame: Int) -> Int64 {
        let raw = Double(plan.frameCount) * Double(bytesPerFrame) * headroomMultiplier
        return Int64(raw) + reserveBytes
    }

    public static func decide(thermal: ThermalState,
                              freeBytes: Int64,
                              bytesPerFrame: Int,
                              framesRemaining: Int) -> CaptureDecision {
        // Thermal criticality outranks everything — it can damage hardware.
        if thermal == .critical {
            return .stop(reason: "Device temperature critical")
        }

        let needed = Int64(Double(framesRemaining) * Double(bytesPerFrame) * headroomMultiplier)
            + reserveBytes
        if freeBytes < needed {
            return .stop(reason: "Insufficient storage")
        }

        if thermal == .serious {
            return .pause(reason: "Device temperature high")
        }
        return .proceed
    }
}
