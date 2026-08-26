import Foundation

/// Stretches an image as far as its own noise allows.
///
/// This exists because of a genuine misconception worth stating plainly:
/// **averaging frames does not make an image brighter.** The mean of N frames
/// has the same mean level as one frame. What falls is noise, by √N.
///
/// The benefit of stacking is second-order. A quieter image tolerates a far
/// harder stretch: push a noisy frame that far and you amplify grain into
/// mush; push a clean stack the same amount and faint detail emerges instead.
/// So the stretch is scaled by measured noise, and a stack with a third the
/// noise receives roughly three times the gain.
///
/// This is what Siril's autostretch and PixInsight's screen transfer function
/// do. Unlike `ToneMapper`'s fixed chain it is image-dependent — but still
/// deterministic, so the same input always produces the same output.
public enum AutoStretch {
    /// Where the background lands after stretching.
    public static let targetBackground: Float = 0.18

    /// How far below the background the black point sits, in units of σ.
    /// 2.8σ clips well under a tenth of a percent of a Gaussian background,
    /// so almost no real signal is lost while the floor is still cut.
    static let blackPointSigmas: Float = 2.8

    /// Floor for the noise estimate, so a perfectly flat synthetic image does
    /// not produce an infinite gain.
    static let minimumSigma: Float = 1e-6

    public struct Parameters: Sendable, Hashable {
        public let black: Float
        public let gain: Float
        public let sigma: Float
    }

    /// Robust noise estimate: 1.4826 × median absolute deviation.
    ///
    /// MAD rather than standard deviation because stars and any real structure
    /// would inflate an SD estimate — the very signal we are trying to keep.
    public static func noiseSigma(_ image: FloatImage) -> Float {
        guard !image.pixels.isEmpty else { return minimumSigma }
        var sorted = image.pixels.sorted()
        let median = sorted[sorted.count / 2]
        var deviations = image.pixels.map { abs($0 - median) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        sorted.removeAll(keepingCapacity: false)
        return max(1.4826 * mad, minimumSigma)
    }

    public static func parameters(for image: FloatImage) -> Parameters {
        guard !image.pixels.isEmpty else {
            return Parameters(black: 0, gain: 1, sigma: minimumSigma)
        }
        let sorted = image.pixels.sorted()
        let median = sorted[sorted.count / 2]
        let sigma = noiseSigma(image)

        let black = median - blackPointSigmas * sigma
        // Aim the background at the target IN LINEAR SPACE, so the sRGB
        // transfer afterwards lands it where intended rather than well above.
        let linearTarget = ToneMapper.inverseTransfer(targetBackground)
        let headroom = median - black
        let gain = headroom > minimumSigma ? linearTarget / headroom : 1

        return Parameters(black: black, gain: gain, sigma: sigma)
    }

    public static func map(_ image: FloatImage) -> FloatImage {
        let p = parameters(for: image)
        let mapped = image.pixels.map { value -> Float in
            let lifted = (value - p.black) * p.gain
            return ToneMapper.transfer(min(max(lifted, 0), 1))
        }
        return FloatImage(width: image.width, height: image.height, pixels: mapped) ?? image
    }
}
