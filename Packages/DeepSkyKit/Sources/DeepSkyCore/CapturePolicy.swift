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

        // Check if the raw value would overflow when converted to Int64.
        // We need to account for adding reserveBytes after the conversion.
        let maxSafeDouble = Double(Int64.max - reserveBytes)

        // Handle non-finite values or values that would overflow
        if !raw.isFinite || raw > maxSafeDouble {
            return Int64.max
        }

        return Int64(raw) + reserveBytes
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
