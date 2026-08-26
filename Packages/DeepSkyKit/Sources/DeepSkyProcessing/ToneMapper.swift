import Foundation

/// A fixed tone chain — no adaptation, no per-image decisions.
///
/// Determinism matters more than cleverness here: two sessions of the same
/// target must be comparable, and an adaptive curve would make every result a
/// different rendering of a different scene.
public enum ToneMapper {
    /// Where sky background lands, as a fraction of full scale. Astro
    /// convention puts it dark but clearly off the floor — crushing it to zero
    /// discards the faintest real signal, which is what stacking exists to
    /// recover in the first place.
    public static let targetBackground: Float = 0.12

    /// Percentile used for the black point. Not the minimum: a single dead
    /// pixel would drag it down and undo the lift.
    static let blackPointPercentile = 0.001

    public static func map(_ image: FloatImage) -> FloatImage {
        let sorted = image.pixels.sorted()
        guard sorted.count > 1 else { return image }

        let blackIndex = min(Int(Double(sorted.count) * blackPointPercentile), sorted.count - 1)
        var black = sorted[blackIndex]
        let median = sorted[sorted.count / 2]

        // `targetBackground` is where the background should land in the FINAL
        // displayed image, so the linear gain must aim at the pre-transfer
        // value. Scaling to 0.12 in linear space would display at ~0.39.
        let linearTarget = inverseTransfer(targetBackground)

        var headroom = median - black
        if headroom <= 1e-6 {
            // Degenerate: the background is uniform, so the black percentile
            // coincides with the median and there is no floor beneath it to
            // subtract. Real frames always have noise so this is synthetic
            // input — but falling through would crush the background to
            // exactly zero, the one outcome this chain exists to avoid.
            black = 0
            headroom = median
        }
        let gain: Float = headroom > 1e-6 ? linearTarget / headroom : 1

        let mapped = image.pixels.map { value -> Float in
            let lifted = (value - black) * gain
            return transfer(min(max(lifted, 0), 1))
        }
        return FloatImage(width: image.width, height: image.height, pixels: mapped) ?? image
    }

    /// One fixed sRGB-style transfer, applied after the linear lift so the
    /// faint end is already off the floor before the curve compresses it.
    static func transfer(_ v: Float) -> Float {
        guard v.isFinite, v > 0 else { return 0 }
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Inverse of `transfer`, so a display-space target can be aimed at from
    /// linear space.
    static func inverseTransfer(_ v: Float) -> Float {
        guard v.isFinite, v > 0 else { return 0 }
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
