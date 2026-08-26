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

        // A lens with no format is a malformed capability profile, not a
        // runtime condition — fail loudly rather than index-crash later.
        // Checked before `camera.apply` so this guard is the one that
        // actually fires; `apply` performs the same bounds check and would
        // otherwise make this guard unreachable dead code.
        guard settings.lensIndex >= 0, settings.lensIndex < manifest.capabilities.lenses.count,
              let format = manifest.capabilities.lenses[settings.lensIndex].captureFormat else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }

        do {
            try await camera.apply(settings)
        } catch {
            // A pre-loop configuration failure has no torn write to
            // protect — no frame was ever captured — so the session is
            // finalised as an empty completed session before the original
            // error is rethrown. Leaving it unfinalised would permanently
            // flag a session that never started as "incomplete", with
            // nothing for Resume/Keep/Discard to recover.
            let completion = SessionCompletion(endedAt: Date(), framesWritten: 0,
                                               framesFlagged: 0, darksWritten: 0)
            try await store.complete(completion, at: dir)
            throw error
        }

        // Until a frame is actually captured we have no measured size, so
        // the policy is seeded with a conservative 12 MP ProRAW estimate.
        // Seed for the pre-flight storage check only; replaced by the first
        // frame's real size. 20MB is measured — 12MP ProRAW from an iPhone 15
        // Pro came in at 17.7-19.1MB across a real session — rounded up so the
        // estimate errs toward refusing a session rather than filling the disk.
        var bytesPerFrame = 20 * 1_048_576
        var written = 0
        var flagged = 0

        // A zero (or negative) frame count is a degenerate plan, not an
        // error: `1...frameCount` would trap on an invalid range, so skip
        // the loop entirely and finalise as an empty completed session.
        if manifest.plan.frameCount > 0 {
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

                    // Deliberately NOT finalised on throw from here down: a
                    // mid-capture failure (captureFrame, the raw-data write,
                    // or store.append) leaves a genuinely interrupted session.
                    // The append-only frames.jsonl plus the Resume/Keep/Discard
                    // recovery flow exist precisely to recover it — writing
                    // completion.json here would misrepresent a torn session
                    // as a clean one.
                    let frame = try await camera.captureFrame(index: index)
                    bytesPerFrame = frame.bytes

                    let name = isDark
                        ? String(format: "darks/dark_%04d.dng", index)
                        : String(format: "frames/frame_%04d.dng", index)
                    try frame.rawData.write(to: dir.appendingPathComponent(name), options: .atomic)

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
