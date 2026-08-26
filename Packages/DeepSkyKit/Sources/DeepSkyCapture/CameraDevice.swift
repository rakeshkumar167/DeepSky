import Foundation
import DeepSkyCore

public enum CaptureError: Error, Sendable, Equatable {
    case settingsNotApplied
    case exposureOutOfRange(requested: Double, max: Double)
    case isoOutOfRange(requested: Float, max: Float)
    case invalidLensIndex(Int)
}

// CaptureSettings lives in DeepSkyCore/CaptureSettings.swift. It moved out
// of this file so SessionManifest (DeepSkyCore) can carry a session's
// settings for persistence in session.json without DeepSkyCore taking on
// a dependency on DeepSkyCapture.

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
