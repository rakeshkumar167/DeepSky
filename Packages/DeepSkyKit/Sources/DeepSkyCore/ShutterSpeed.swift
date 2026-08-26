import Foundation

public struct ShutterSpeed: Sendable, Hashable, Codable, Comparable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    /// Sub-second exposures read as reciprocals ("1/250"); one second and
    /// longer read as decimals ("2.0s"). Astrophotographers work in the
    /// second-and-longer range, where reciprocals are unreadable.
    public var displayLabel: String {
        // The magnitude floor guards the reciprocal below: for seconds
        // under ~1e-19 the reciprocal exceeds Int.max and `Int(reciprocal)`
        // traps. 1e-9 is far below any real shutter speed, so it costs
        // nothing in the valid range while closing the crash.
        guard seconds.isFinite && seconds >= 1e-9 else {
            return "N/A"
        }
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        }
        let reciprocal = (1.0 / seconds).rounded()
        return "1/\(Int(reciprocal))"
    }

    public static func < (lhs: ShutterSpeed, rhs: ShutterSpeed) -> Bool {
        lhs.seconds < rhs.seconds
    }
}
