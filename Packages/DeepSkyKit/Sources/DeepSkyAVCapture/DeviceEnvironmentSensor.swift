import Foundation
import DeepSkyCore
import DeepSkySession

#if os(iOS)
import CoreMotion

/// Real environment readings for the capture loop.
///
/// `CaptureCoordinator` already consumes `EnvironmentSensor` and is fully
/// tested against a stub; this supplies the hardware-backed one. Its methods
/// are synchronous by design so the coordinator can read them inline per
/// frame, which is why gyro samples accumulate in the background and are read
/// under a lock rather than awaited.
public final class DeviceEnvironmentSensor: EnvironmentSensor, @unchecked Sendable {
    private let motion = CMMotionManager()
    private let lock = NSLock()
    private var samples: [Double] = []

    /// Bounded so a long session cannot grow this without limit. At 50Hz this
    /// is ten seconds of history, far more than one exposure needs.
    private static let maxSamples = 500

    public init() {
        motion.gyroUpdateInterval = 1.0 / 50.0
        guard motion.isGyroAvailable else { return }

        // A dedicated queue keeps sampling off the main thread, which is busy
        // rendering the capture UI while a session runs.
        let queue = OperationQueue()
        queue.name = "com.deepsky.motion"
        queue.maxConcurrentOperationCount = 1

        motion.startGyroUpdates(to: queue) { [weak self] data, _ in
            guard let self, let rate = data?.rotationRate else { return }
            let magnitude = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
            self.lock.lock()
            self.samples.append(magnitude)
            if self.samples.count > Self.maxSamples {
                self.samples.removeFirst(self.samples.count - Self.maxSamples)
            }
            self.lock.unlock()
        }
    }

    deinit { motion.stopGyroUpdates() }

    public func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        // An unrecognised state is unsafe, not fine. Reporting .nominal here
        // would let a future OS silently keep capturing on a hot device.
        @unknown default: return .serious
        }
    }

    public func freeBytes() -> Int64 {
        let url = URL.documentsDirectory
        guard let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            // Unknown free space must read as "none", never "plenty" — the
            // capture policy stops on insufficient storage, and stopping a
            // session wrongly is far cheaper than filling the disk.
            return 0
        }
        return capacity
    }

    /// RMS of the gyro magnitudes collected since the previous read, then
    /// clears. The coordinator calls this once per exposure, so each reading
    /// describes exactly the interval its frame was captured over.
    public func rmsAngularRate() -> Double {
        lock.lock()
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !taken.isEmpty else { return 0 }
        let meanSquare = taken.reduce(0) { $0 + $1 * $1 } / Double(taken.count)
        return meanSquare.squareRoot()
    }
}
#endif
