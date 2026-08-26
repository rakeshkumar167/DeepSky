import Foundation

/// What auto-exposure settled on before we took manual control.
public struct LightReading: Sendable, Hashable {
    public let iso: Float
    public let exposureSeconds: Double

    public init(iso: Float, exposureSeconds: Double) {
        self.iso = iso
        self.exposureSeconds = exposureSeconds
    }
}

/// Derives capture settings from what the hardware actually reported.
///
/// Nothing here is hardcoded to a device. Every value comes from a probed
/// `FormatCapability`, which matters because the two devices measured differ
/// sharply — 48MP on one lens versus three, and 2304 versus 7680 telephoto
/// ISO. A preset tuned to either one alone would be wrong on the other.
public enum AstroPreset {

    /// Past roughly this point, noise grows faster than signal on phone sensors.
    ///
    /// NOTE: this is conventional wisdom, NOT measured on these sensors. The
    /// wide reports a 12320 ceiling and may well stack better than this allows.
    /// It is the first thing worth validating on a real sky.
    public static let isoCeiling: Float = 6400

    /// The "500 rule": a star trails visibly after roughly 500/focal seconds.
    /// Frames are one second each, so this is also the frame ceiling.
    public static let trailingRuleConstant = 500.0

    /// Used when a lens reports no focal length. 24mm is the conventional phone
    /// wide; assuming a *shorter* lens would permit more frames and risk
    /// trailing, so this errs toward caution.
    static let fallbackFocalLength = 24

    /// Spec §21's astro-neutral range is 3000–5000K.
    public static let defaultWhiteBalanceKelvin = 3900

    /// The lens with the most ISO headroom is the light bucket. Derived rather
    /// than assumed: it happens to be the wide on both measured devices, but
    /// the rule is what generalises to hardware we have not seen.
    public static func recommendedLensIndex(_ capabilities: DeviceCapabilities) -> Int? {
        let scored = capabilities.lenses.enumerated().compactMap { index, lens -> (Int, Float)? in
            guard let maxISO = lens.formats.map(\.maxISO).max() else { return nil }
            return (index, maxISO)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// The format an astro capture uses: longest possible sensor exposure
    /// first, largest sensor area to break ties. The exposure ceiling dominates
    /// because it sets how few frames a given integration needs, and every
    /// extra frame is more accumulated drift.
    public static func astroFormat(for lens: LensCapability) -> FormatCapability? {
        lens.formats.max { a, b in
            a.maxExposureSeconds != b.maxExposureSeconds
                ? a.maxExposureSeconds < b.maxExposureSeconds
                : (a.width * a.height) < (b.width * b.height)
        }
    }

    /// Frames are one second each, so the 500-rule seconds figure is also the
    /// frame count. The app therefore cannot be driven into visible trailing.
    public static func maxFrames(for lens: LensCapability) -> Int {
        let focal = lens.focalLengthEquivalent ?? fallbackFocalLength
        guard focal > 0 else { return 1 }
        return max(1, Int(trailingRuleConstant / Double(focal)))
    }

    /// Scales the metered exposure onto our fixed shutter, then clamps.
    ///
    /// On a dark sky auto-exposure is already pinned at its own limits, so this
    /// correctly resolves to "ceiling ISO at the sensor's maximum exposure".
    public static func settings(
        capabilities: DeviceCapabilities,
        lensIndex: Int,
        light: LightReading
    ) -> CaptureSettings? {
        guard lensIndex >= 0, lensIndex < capabilities.lenses.count else { return nil }
        let lens = capabilities.lenses[lensIndex]
        guard let format = astroFormat(for: lens) else { return nil }

        let shutter = format.maxExposureSeconds
        guard shutter > 0, shutter.isFinite else { return nil }

        // Metering comes from hardware and can be degenerate; a NaN or infinite
        // ISO must not propagate into a capture request.
        let scaled = Double(light.iso) * (light.exposureSeconds / shutter)
        let upperBound = min(format.maxISO, isoCeiling)
        let candidate = Float(scaled.isFinite ? scaled : 0)
        let iso = min(max(candidate.isFinite ? candidate : format.minISO, format.minISO), upperBound)

        return CaptureSettings(
            lensIndex: lensIndex,
            iso: iso,
            exposure: ShutterSpeed(seconds: shutter),
            lensPosition: 1.0,                        // infinity
            whiteBalanceKelvin: defaultWhiteBalanceKelvin,
            exposureBias: 0)
    }
}
