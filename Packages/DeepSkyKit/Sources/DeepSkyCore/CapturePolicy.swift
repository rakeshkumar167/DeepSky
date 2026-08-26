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

    /// Calculates required storage bytes, clamping against overflow.
    /// Multiplies frames × bytesPerFrame × 1.15, then adds the reserve.
    /// Clamps non-finite or oversized values to prevent conversion overflow.
    private static func requiredBytes(frames: Int, bytesPerFrame: Int) -> Int64 {
        let raw = Double(frames) * Double(bytesPerFrame) * headroomMultiplier

        // Close both ends explicitly rather than trusting a rounded Double
        // comparison: `Int64(exactly:)` and `addingReportingOverflow` fail
        // cleanly instead of trapping, however `raw` lands. A negative
        // frame count still needs the reserve, so it clamps to
        // `reserveBytes` rather than to a negative requirement.
        guard raw.isFinite, raw >= 0,
              let base = Int64(exactly: raw.rounded(.down))
        else {
            return raw.isFinite && raw < 0 ? reserveBytes : Int64.max
        }
        let (sum, overflow) = base.addingReportingOverflow(reserveBytes)
        return overflow ? Int64.max : sum
    }

    public static func storageRequirement(plan: CapturePlan, bytesPerFrame: Int) -> Int64 {
        return requiredBytes(frames: plan.frameCount, bytesPerFrame: bytesPerFrame)
    }

    public static func decide(thermal: ThermalState,
                              freeBytes: Int64,
                              bytesPerFrame: Int,
                              framesRemaining: Int) -> CaptureDecision {
        let needed = requiredBytes(frames: framesRemaining, bytesPerFrame: bytesPerFrame)

        // Thermal criticality outranks everything — it can damage hardware.
        switch thermal {
        case .critical:
            return .stop(reason: "Device temperature critical")
        case .serious:
            if freeBytes < needed {
                return .stop(reason: "Insufficient storage")
            }
            return .pause(reason: "Device temperature high")
        case .fair, .nominal:
            if freeBytes < needed {
                return .stop(reason: "Insufficient storage")
            }
            return .proceed
        }
    }
}
