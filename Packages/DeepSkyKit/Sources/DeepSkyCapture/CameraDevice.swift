import Foundation
import DeepSkyCore

public enum CaptureError: Error, Sendable, Equatable {
    case settingsNotApplied
    case exposureOutOfRange(requested: Double, max: Double)
    case isoOutOfRange(requested: Float, max: Float)
    case invalidLensIndex(Int)
}

public struct CaptureSettings: Sendable, Codable, Hashable {
    public var lensIndex: Int
    public var iso: Float
    public var exposure: ShutterSpeed
    public var lensPosition: Float
    public var whiteBalanceKelvin: Int
    public var exposureBias: Float

    public init(lensIndex: Int, iso: Float, exposure: ShutterSpeed,
                lensPosition: Float, whiteBalanceKelvin: Int, exposureBias: Float) {
        self.lensIndex = lensIndex
        self.iso = iso
        self.exposure = exposure
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.exposureBias = exposureBias
    }
}

public struct CapturedFrame: Sendable {
    public let index: Int
    public let rawData: Data
    public let bytes: Int
    public let capturedAt: Date
    public let appliedSettings: CaptureSettings

    public init(index: Int, rawData: Data, capturedAt: Date, appliedSettings: CaptureSettings) {
        self.index = index
        self.rawData = rawData
        self.bytes = rawData.count
        self.capturedAt = capturedAt
        self.appliedSettings = appliedSettings
    }
}

/// The single seam between the app and the camera. `AVCaptureDriver`
/// (Plan 2) and `SyntheticDriver` both conform; nothing above this
/// protocol imports AVFoundation.
public protocol CameraDevice: Actor {
    var capabilities: DeviceCapabilities { get }
    func apply(_ settings: CaptureSettings) async throws
    func captureFrame(index: Int) async throws -> CapturedFrame
}
