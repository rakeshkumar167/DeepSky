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
/// byte pattern varies with the driver's seed and the requested frame
/// index. Applied settings are recorded on the returned `CapturedFrame`
/// as metadata but do not influence the payload bytes.
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

    /// Combines the driver seed and frame index with a SplitMix64-style
    /// finalizer, rather than plain addition. Addition would make two
    /// different driver seeds collide on frames whenever
    /// `seedA + indexA == seedB + indexB` — e.g. seed 10's frame 1 would
    /// equal seed 11's frame 0. Multiplying the index before mixing, then
    /// running the finalizer, avoids that so distinct (seed, index) pairs
    /// reliably yield distinct byte streams.
    private static func mixedSeed(_ seed: UInt64, _ index: UInt64) -> UInt64 {
        var z = seed ^ (index &* 0x9E3779B97F4A7C15)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return z
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

        var rng = SeededGenerator(seed: Self.mixedSeed(seed, UInt64(index)))
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
