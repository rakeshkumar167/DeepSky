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

extension LensCapability {
    /// The format a full-resolution still capture actually uses.
    ///
    /// **Never use `formats.first`.** On a real iPhone the first entry is a
    /// tiny preview format — 192×144 on the 15 Pro's wide lens — with both a
    /// narrower pixel scale and a lower ISO ceiling (5280 against 12320) than
    /// the format a photo is actually taken with. Reading limits or field of
    /// view from it produces two silent failures: stability drift understated
    /// by ~20×, so smeared frames grade as excellent; and a legitimate
    /// high-ISO request rejected as out of range, which kills a session under
    /// exactly the dark skies this app exists for.
    ///
    /// Both were found by capturing real frames, not by any synthetic test —
    /// the committed fixtures all happened to be read one format at a time.
    ///
    /// Selection matches the capture path: longest sensor exposure first,
    /// largest sensor area to break ties.
    public var captureFormat: FormatCapability? {
        formats.max { a, b in
            a.maxExposureSeconds != b.maxExposureSeconds
                ? a.maxExposureSeconds < b.maxExposureSeconds
                : (a.width * a.height) < (b.width * b.height)
        }
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
