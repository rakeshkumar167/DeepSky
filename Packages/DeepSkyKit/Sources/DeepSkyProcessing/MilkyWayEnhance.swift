import Foundation

/// Local contrast enhancement for the Milky Way band — spec §18.
///
/// The binding constraint is the spec's own: *"The algorithm should not
/// manufacture Milky Way structures where none exist."* That rules out
/// anything generative and it rules out a plain unsharp mask too, which
/// amplifies whatever it finds — including noise, which then reads as dust
/// lanes that were never photographed.
///
/// So this is a **band-pass**, not a high-pass. Structure is isolated between
/// two blur scales:
///
///     detail = blur(small) − blur(large)
///
/// - Below the small scale sits pixel noise and the stars. Excluded, which is
///   why this does not enlarge or brighten stars (§19 is a separate control)
///   and does not amplify grain.
/// - Above the large scale sits the sky gradient. Excluded, because that is
///   `BackgroundExtraction`'s job and boosting it would just make light
///   pollution more obvious.
/// - In between is the Milky Way's own scale: the band, the dust lanes, the
///   brightness variation across it.
///
/// Where the image is smooth, the two blurs agree, `detail` is zero, and the
/// output is the input. Structure has to already be present for anything to
/// happen — which is the spec's requirement expressed as arithmetic rather
/// than as an intention.
public enum MilkyWayEnhance {

    /// Small blur radius, in pixels. Wide enough to sit above pixel noise and
    /// typical star profiles, narrow enough to keep real structure.
    static let noiseScale = 2

    /// Large blur radius as a fraction of the short edge. About a twentieth of
    /// the frame: comfortably larger than dust-lane structure, comfortably
    /// smaller than a whole-frame gradient.
    static let structureScaleFraction = 0.05

    /// Detail multiplier at full slider. Beyond roughly this the result starts
    /// to look processed rather than photographed — haloes appear around the
    /// band edges, which is the classic over-cooked astrophoto.
    static let maxGain: Float = 2.0

    /// Saturation added at full slider — the spec's "colour separation".
    /// Deliberately modest: oversaturated stars are on §43's list of things to
    /// avoid.
    static let maxSaturation: Float = 0.35

    /// Ceiling on the per-pixel brightness ratio, so a near-black pixel cannot
    /// be multiplied into a bright artefact.
    static let maxRatio: Float = 4

    /// - Parameter amount: 0 (OFF) to 1 (MAX). Zero returns the input
    ///   unchanged, exactly — an "off" control that still perturbs the image
    ///   is a bug, not a subtlety.
    public static func apply(_ image: RGBImage, amount: Float) -> RGBImage {
        let strength = min(max(amount, 0), 1)
        guard strength > 0 else { return image }

        let luminance = image.luminance
        let largeRadius = max(Int(Double(min(image.width, image.height))
                                  * structureScaleFraction), noiseScale + 1)

        let fine = Blur.gaussianApproximation(luminance, radius: noiseScale)
        let coarse = Blur.gaussianApproximation(luminance, radius: largeRadius)

        let gain = strength * maxGain
        var enhanced = [Float](repeating: 0, count: luminance.pixels.count)
        for i in 0..<enhanced.count {
            let detail = fine.pixels[i] - coarse.pixels[i]
            enhanced[i] = max(luminance.pixels[i] + gain * detail, 0)
        }

        // Apply the luminance change to colour as a RATIO, so hue survives.
        // Adding the detail to each channel directly would desaturate
        // everything it brightened.
        var red = image.red.pixels
        var green = image.green.pixels
        var blue = image.blue.pixels
        let saturation = 1 + strength * maxSaturation

        for i in 0..<enhanced.count {
            let original = luminance.pixels[i]
            let ratio = original > 1e-6
                ? min(enhanced[i] / original, maxRatio)
                : 1
            let newLuminance = enhanced[i]

            // Scale to the new brightness, then push each channel away from
            // that brightness to separate the colours.
            let r = red[i] * ratio, g = green[i] * ratio, b = blue[i] * ratio
            red[i] = min(max(newLuminance + (r - newLuminance) * saturation, 0), 1)
            green[i] = min(max(newLuminance + (g - newLuminance) * saturation, 0), 1)
            blue[i] = min(max(newLuminance + (b - newLuminance) * saturation, 0), 1)
        }

        guard let r = FloatImage(width: image.width, height: image.height, pixels: red),
              let g = FloatImage(width: image.width, height: image.height, pixels: green),
              let b = FloatImage(width: image.width, height: image.height, pixels: blue),
              let result = RGBImage(red: r, green: g, blue: b) else { return image }
        return result
    }
}
