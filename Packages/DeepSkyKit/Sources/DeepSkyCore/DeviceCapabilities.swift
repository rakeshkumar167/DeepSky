import Foundation

public struct FormatCapability: Sendable, Codable, Hashable {
    public let width: Int
    public let height: Int
    public let minExposureSeconds: Double
    public let maxExposureSeconds: Double
    public let minISO: Float
    public let maxISO: Float
    public let horizontalFieldOfViewDegrees: Float
    public let maxPhotoDimensions: [[Int]]
    public let rawPixelFormats: [String]

    public init(width: Int, height: Int,
                minExposureSeconds: Double, maxExposureSeconds: Double,
                minISO: Float, maxISO: Float,
                horizontalFieldOfViewDegrees: Float,
                maxPhotoDimensions: [[Int]], rawPixelFormats: [String]) {
        self.width = width
        self.height = height
        self.minExposureSeconds = minExposureSeconds
        self.maxExposureSeconds = maxExposureSeconds
        self.minISO = minISO
        self.maxISO = maxISO
        self.horizontalFieldOfViewDegrees = horizontalFieldOfViewDegrees
        self.maxPhotoDimensions = maxPhotoDimensions
        self.rawPixelFormats = rawPixelFormats
    }
}

public struct LensCapability: Sendable, Codable, Hashable {
    public let deviceType: String
    public let localizedName: String
    public let focalLengthEquivalent: Int?
    public let formats: [FormatCapability]

    public init(deviceType: String, localizedName: String,
                focalLengthEquivalent: Int?, formats: [FormatCapability]) {
        self.deviceType = deviceType
        self.localizedName = localizedName
        self.focalLengthEquivalent = focalLengthEquivalent
        self.formats = formats
    }
}

public struct DeviceCapabilities: Sendable, Codable, Hashable {
    public let deviceModel: String
    public let osVersion: String
    public let supportsAppleProRAW: Bool
    public let lenses: [LensCapability]
    public let probedAt: Date

    public init(deviceModel: String, osVersion: String, supportsAppleProRAW: Bool,
                lenses: [LensCapability], probedAt: Date) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.supportsAppleProRAW = supportsAppleProRAW
        self.lenses = lenses
        self.probedAt = probedAt
    }
}
