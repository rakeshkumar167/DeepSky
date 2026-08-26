import Foundation

public enum FrameFlag: String, Sendable, Codable, Hashable, CaseIterable {
    case motion
    case thermalPause
    case sessionInterrupted
    case writeRetry
    case settingsDrift
}

public enum StabilityBand: String, Sendable, Codable, Hashable {
    case excellent, good, poor
}

public enum ThermalState: String, Sendable, Codable, Hashable {
    case nominal, fair, serious, critical
}

public struct StabilityReading: Sendable, Codable, Hashable {
    public let rmsAngularRateRadPerSec: Double
    public let predictedDriftPixels: Double
    public let band: StabilityBand

    public init(rmsAngularRateRadPerSec: Double, predictedDriftPixels: Double, band: StabilityBand) {
        self.rmsAngularRateRadPerSec = rmsAngularRateRadPerSec
        self.predictedDriftPixels = predictedDriftPixels
        self.band = band
    }
}

public struct FrameRecord: Sendable, Codable, Hashable {
    public let index: Int
    public let file: String
    public let capturedAt: Date
    public let iso: Float
    public let exposureSeconds: Double
    public let lensPosition: Float
    public let whiteBalanceKelvin: Int
    public let bytes: Int
    public let thermalState: ThermalState
    public let stability: StabilityReading
    public let flags: [FrameFlag]
    public let isDark: Bool

    public init(index: Int, file: String, capturedAt: Date, iso: Float,
                exposureSeconds: Double, lensPosition: Float, whiteBalanceKelvin: Int,
                bytes: Int, thermalState: ThermalState, stability: StabilityReading,
                flags: [FrameFlag], isDark: Bool) {
        self.index = index
        self.file = file
        self.capturedAt = capturedAt
        self.iso = iso
        self.exposureSeconds = exposureSeconds
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.bytes = bytes
        self.thermalState = thermalState
        self.stability = stability
        self.flags = flags
        self.isDark = isDark
    }

    // Unknown flags from a newer writer are dropped rather than thrown on.
    // Every other field is required — a frame record with no exposure is a bug,
    // not a compatibility question.
    private enum CodingKeys: String, CodingKey {
        case index, file, capturedAt, iso, exposureSeconds, lensPosition
        case whiteBalanceKelvin, bytes, thermalState, stability, flags, isDark
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        file = try c.decode(String.self, forKey: .file)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        iso = try c.decode(Float.self, forKey: .iso)
        exposureSeconds = try c.decode(Double.self, forKey: .exposureSeconds)
        lensPosition = try c.decode(Float.self, forKey: .lensPosition)
        whiteBalanceKelvin = try c.decode(Int.self, forKey: .whiteBalanceKelvin)
        bytes = try c.decode(Int.self, forKey: .bytes)
        thermalState = try c.decode(ThermalState.self, forKey: .thermalState)
        stability = try c.decode(StabilityReading.self, forKey: .stability)
        isDark = try c.decode(Bool.self, forKey: .isDark)
        let rawFlags = try c.decode([String].self, forKey: .flags)
        flags = rawFlags.compactMap(FrameFlag.init(rawValue:))
    }
}

public struct SessionManifest: Sendable, Codable, Hashable {
    public let id: String
    public let name: String
    public let startedAt: Date
    public let plan: CapturePlan
    public let capabilities: DeviceCapabilities
    public let settings: CaptureSettings

    public init(id: String, name: String, startedAt: Date,
                plan: CapturePlan, capabilities: DeviceCapabilities,
                settings: CaptureSettings) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.plan = plan
        self.capabilities = capabilities
        self.settings = settings
    }
}

public struct SessionCompletion: Sendable, Codable, Hashable {
    public let endedAt: Date
    public let framesWritten: Int
    public let framesFlagged: Int
    public let darksWritten: Int

    public init(endedAt: Date, framesWritten: Int, framesFlagged: Int, darksWritten: Int) {
        self.endedAt = endedAt
        self.framesWritten = framesWritten
        self.framesFlagged = framesFlagged
        self.darksWritten = darksWritten
    }
}
