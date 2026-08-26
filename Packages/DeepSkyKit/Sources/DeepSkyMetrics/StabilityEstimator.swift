import Foundation
import DeepSkyCore

public enum StabilityEstimator {
    /// Drift below this many pixels over the exposure counts as excellent.
    static let excellentPixels = 0.5
    /// Drift below this many pixels still stacks cleanly.
    static let goodPixels = 1.5

    public static func reading(rmsAngularRateRadPerSec: Double,
                               exposureSeconds: Double,
                               format: FormatCapability) -> StabilityReading {
        let fovRadians = Double(format.horizontalFieldOfViewDegrees) * .pi / 180.0
        // A malformed format must not produce infinity and poison the manifest.
        let pixelsPerRadian = fovRadians > 0 ? Double(format.width) / fovRadians : 0

        let drift = rmsAngularRateRadPerSec * exposureSeconds * pixelsPerRadian

        let band: StabilityBand
        if drift < excellentPixels {
            band = .excellent
        } else if drift < goodPixels {
            band = .good
        } else {
            band = .poor
        }

        return StabilityReading(rmsAngularRateRadPerSec: rmsAngularRateRadPerSec,
                                predictedDriftPixels: drift, band: band)
    }
}
