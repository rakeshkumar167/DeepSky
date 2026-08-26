import Foundation
import DeepSkyCore
import DeepSkyCapture

/// Deterministic pseudo-random source so a given seed always yields the
/// same frames — that determinism is what makes it usable as a test fixture.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Stands in for a real camera. Emits small synthetic "RAW" payloads whose
/// byte pattern varies with seed, frame index and applied settings.
///
/// Deliberately NOT a real DNG: this plan tests capture orchestration, not
/// image encoding. Plan 2's AVCaptureDriver produces genuine ProRAW DNGs.
public actor SyntheticDriver: CameraDevice {
    public let capabilities: DeviceCapabilities
    private let seed: UInt64
    private var applied: CaptureSettings?
    public private(set) var appliedSettingsHistory: [CaptureSettings] = []

    /// Payload size per synthetic frame. Small enough to keep tests fast,
    /// large enough that byte-comparison is meaningful.
    static let syntheticFrameBytes = 4096

    public init(capabilities: DeviceCapabilities, seed: UInt64) {
        self.capabilities = capabilities
        self.seed = seed
    }

    public func apply(_ settings: CaptureSettings) async throws {
        guard settings.lensIndex >= 0, settings.lensIndex < capabilities.lenses.count else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        let lens = capabilities.lenses[settings.lensIndex]
        guard let format = lens.formats.first else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        guard settings.exposure.seconds <= format.maxExposureSeconds else {
            throw CaptureError.exposureOutOfRange(requested: settings.exposure.seconds,
                                                  max: format.maxExposureSeconds)
        }
        guard settings.iso <= format.maxISO else {
            throw CaptureError.isoOutOfRange(requested: settings.iso, max: format.maxISO)
        }
        applied = settings
        appliedSettingsHistory.append(settings)
    }

    public func captureFrame(index: Int) async throws -> CapturedFrame {
        guard let settings = applied else { throw CaptureError.settingsNotApplied }

        var rng = SeededGenerator(seed: seed &+ UInt64(index))
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.syntheticFrameBytes)
        for _ in 0..<Self.syntheticFrameBytes {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }

        return CapturedFrame(index: index, rawData: Data(bytes),
                             capturedAt: Date(timeIntervalSince1970: 776000000 + Double(index)),
                             appliedSettings: settings)
    }
}
