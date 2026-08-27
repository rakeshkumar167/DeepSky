import Foundation

/// Stretches an image as far as its own noise allows.
///
/// This exists because of a genuine misconception worth stating plainly:
/// **averaging frames does not make an image brighter.** The mean of N frames
/// has the same mean level as one frame. What falls is noise, by √N.
///
/// The benefit of stacking is second-order, and the mechanism is specific: the
/// black point sits at `median − 2.8σ`, so as σ falls the black point moves
/// closer to the background, and signal that was previously crushed into black
/// survives. A three-times quieter stack tolerates a three-times more
/// aggressive stretch, and that is where faint detail appears.
///
/// This is Siril's autostretch and PixInsight's screen transfer function:
/// clip the shadows a fixed number of σ below the background, then apply a
/// midtones transfer function chosen to land the background on a fixed target.
public enum AutoStretch {
    /// Where the background lands after stretching. 0.25 is the documented
    /// default in both PixInsight and Siril.
    public static let targetBackground: Float = 0.25

    /// How far below the background the black point sits, in units of σ.
    /// 2.8σ clips well under a tenth of a percent of a Gaussian background,
    /// so almost no real signal is lost while the floor is still cut.
    static let blackPointSigmas: Float = 2.8

    /// Floor for the noise estimate, so a perfectly flat synthetic image does
    /// not produce a degenerate stretch.
    static let minimumSigma: Float = 1e-6

    public struct Parameters: Sendable, Hashable {
        /// The shadow clipping point, in linear input units.
        public let black: Float
        /// Midtone balance for the transfer function. Smaller is more
        /// aggressive; 0.5 is a straight line.
        public let midtone: Float
        /// The noise estimate the stretch was scaled by.
        public let sigma: Float
        /// The background level the stretch was centred on.
        public let median: Float
    }

    /// Robust noise estimate: 1.4826 × median absolute deviation.
    ///
    /// **This is only a noise estimate on a flat, background-dominated
    /// image.** MAD is robust against a minority of outlying pixels — stars —
    /// but it is not robust against large-scale structure, and a sky gradient
    /// or a landscape in frame spreads the histogram so far that MAD reports
    /// the scene rather than the sensor. Measured on a real session it read
    /// 0.0326 where the true noise was 0.0013: wrong by a factor of 25, which
    /// is enough to destroy the stretch entirely.
    ///
    /// Prefer passing a measured σ from `TemporalNoise`, which cancels
    /// structure by differencing frames. This remains the fallback for a
    /// single image with no burst behind it.
    public static func noiseSigma(_ image: FloatImage) -> Float {
        guard !image.pixels.isEmpty else { return minimumSigma }
        let median = median(of: image.pixels)
        var deviations = image.pixels.map { abs($0 - median) }
        deviations.sort()
        return max(1.4826 * deviations[deviations.count / 2], minimumSigma)
    }

    static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        return sorted[sorted.count / 2]
    }

    /// - Parameter measuredSigma: true noise σ, when the caller has one. Falls
    ///   back to the image's own MAD, with the caveat documented above.
    public static func parameters(for image: FloatImage,
                                  measuredSigma: Double? = nil) -> Parameters {
        guard !image.pixels.isEmpty else {
            return Parameters(black: 0, midtone: 0.5, sigma: minimumSigma, median: 0)
        }
        let background = median(of: image.pixels)
        let sigma = measuredSigma.map { max(Float($0), minimumSigma) } ?? noiseSigma(image)

        let black = min(max(background - blackPointSigmas * sigma, 0), 1)
        let span = 1 - black
        // A background at or above white leaves nothing to stretch.
        guard span > minimumSigma else {
            return Parameters(black: black, midtone: 0.5, sigma: sigma, median: background)
        }

        let rescaledBackground = min(max((background - black) / span, 0), 1)
        let midtone = MidtonesTransfer.midtone(mappingBackground: rescaledBackground,
                                               to: targetBackground)
        return Parameters(black: black, midtone: midtone, sigma: sigma, median: background)
    }

    public static func map(_ image: FloatImage, measuredSigma: Double? = nil) -> FloatImage {
        let p = parameters(for: image, measuredSigma: measuredSigma)
        let span = max(1 - p.black, minimumSigma)

        // No sRGB transfer afterwards. The midtones function IS the stretch —
        // it takes linear input to display-referred output on its own, and
        // following it with a gamma curve would brighten the result twice.
        let mapped = image.pixels.map { value -> Float in
            let rescaled = (value - p.black) / span
            return MidtonesTransfer.apply(min(max(rescaled, 0), 1), midtone: p.midtone)
        }
        return FloatImage(width: image.width, height: image.height, pixels: mapped) ?? image
    }
}
