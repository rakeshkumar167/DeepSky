import Foundation
import DeepSkyCore
import DeepSkyCapture
import DeepSkyMetrics

/// Everything the coordinator needs to know about the world that isn't the
/// camera. Injected so thermal, storage and motion conditions can be driven
/// deterministically in tests — on device, Plan 2 supplies a real implementation
/// backed by ProcessInfo, FileManager and CoreMotion.
public protocol EnvironmentSensor: Sendable {
    func thermalState() -> ThermalState
    func freeBytes() -> Int64
    func rmsAngularRate() -> Double
}

public actor CaptureCoordinator {
    private let camera: any CameraDevice
    private let store: SessionStore
    private let sensor: any EnvironmentSensor

    public init(camera: any CameraDevice, store: SessionStore, sensor: any EnvironmentSensor) {
        self.camera = camera
        self.store = store
        self.sensor = sensor
    }

    public func run(manifest: SessionManifest,
                    settings: CaptureSettings,
                    isDark: Bool) async throws -> SessionCompletion {
        let dir = try await store.create(manifest: manifest)
        try await camera.apply(settings)

        // Until a frame is actually captured we have no measured size, so
        // the policy is seeded with a conservative 12 MP ProRAW estimate.
        var bytesPerFrame = 25 * 1_048_576
        var written = 0
        var flagged = 0

        // A lens with no format is a malformed capability profile, not a
        // runtime condition — fail loudly rather than index-crash later.
        guard settings.lensIndex < manifest.capabilities.lenses.count,
              let format = manifest.capabilities.lenses[settings.lensIndex].formats.first else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }

        // Labelled so the exit is explicit. A bare `break` inside a `switch`
        // exits the switch, not the loop — a classic Swift trap.
        captureLoop: for index in 1...manifest.plan.frameCount {
            let decision = CapturePolicy.decide(
                thermal: sensor.thermalState(),
                freeBytes: sensor.freeBytes(),
                bytesPerFrame: bytesPerFrame,
                framesRemaining: manifest.plan.frameCount - written)

            switch decision {
            case .stop:
                // Abort, but finalise properly — an aborted session is still
                // a valid session with fewer frames (spec §39).
                break captureLoop

            case .pause:
                // Plan 2's UI drives the countdown and retry. Headless there
                // is nothing to wait on, so a pause ends the run; every frame
                // already written is kept.
                break captureLoop

            case .proceed:
                let stability = StabilityEstimator.reading(
                    rmsAngularRateRadPerSec: sensor.rmsAngularRate(),
                    exposureSeconds: settings.exposure.seconds,
                    format: format)

                let frame = try await camera.captureFrame(index: index)
                bytesPerFrame = frame.bytes

                let name = isDark
                    ? String(format: "darks/dark_%04d.dng", index)
                    : String(format: "frames/frame_%04d.dng", index)
                try frame.rawData.write(to: dir.appendingPathComponent(name))

                var flags: [FrameFlag] = []
                if stability.band == .poor { flags.append(.motion) }
                if !flags.isEmpty { flagged += 1 }

                let record = FrameRecord(
                    index: index, file: name, capturedAt: frame.capturedAt,
                    iso: frame.appliedSettings.iso,
                    exposureSeconds: frame.appliedSettings.exposure.seconds,
                    lensPosition: frame.appliedSettings.lensPosition,
                    whiteBalanceKelvin: frame.appliedSettings.whiteBalanceKelvin,
                    bytes: frame.bytes, thermalState: sensor.thermalState(),
                    stability: stability, flags: flags, isDark: isDark)

                try await store.append(record, to: dir)
                written += 1
            }
        }

        let completion = SessionCompletion(
            endedAt: Date(),
            framesWritten: isDark ? 0 : written,
            framesFlagged: flagged,
            darksWritten: isDark ? written : 0)
        try await store.complete(completion, at: dir)
        return completion
    }
}
