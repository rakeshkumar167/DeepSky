import Foundation

/// Takes a linear RGB stack to a display-ready colour image.
///
/// Three steps, in this order, each for a specific reason:
///
/// 1. **Gradient removal, per channel.** Skyglow is coloured — sodium street
///    lighting is strongly orange — so a single achromatic gradient fit would
///    leave a coloured ramp behind. Fitting each channel separately removes
///    the ramp and most of its colour with it.
/// 2. **Background neutralisation.** What remains after flattening is a
///    uniform cast: the sky sits orange rather than grey. Shifting each
///    channel so the three backgrounds agree makes the sky neutral while
///    leaving everything above it — star colour, nebula hue — intact, because
///    an additive shift preserves differences.
/// 3. **One stretch for all three channels.** The parameters come from
///    luminance and are applied unchanged to R, G and B. Stretching each
///    channel to its own histogram would push every hue toward grey, which is
///    the classic way colour dies in an astro pipeline.
public enum ColourRender {

    /// How the sky gradient is removed from a colour image.
    ///
    /// Measured on the only real session available — an indoor scene, not sky
    /// — mean chroma spread came out:
    ///
    ///     off 0.1413    achromatic 0.1974    per-channel 0.1928
    ///
    /// Removing the gradient raises chroma either way, and the two removal
    /// modes are indistinguishable. So the visible blotching on that footage
    /// is **not** per-channel fitting inventing colour, which was the first
    /// theory and is wrong: a common surface produces just as much. The far
    /// likelier explanation is that flattening lets the stretch push harder
    /// into regions that were previously compressed, amplifying colour that
    /// was genuinely there.
    ///
    /// That reading cannot be confirmed on an indoor frame, where the
    /// "gradient" is a lamp lighting a wall — real scene content that this
    /// step is right to leave alone and wrong to remove. On a night sky the
    /// gradient is skyglow, which is exactly what it should remove. **Neither
    /// mode is validated against sky data yet.**
    public enum GradientMode: Sendable {
        case off
        /// One surface fitted to luminance, scaled to each channel's level.
        /// Cannot turn a neutral ramp into a coloured one — but equally cannot
        /// remove a coloured one, which is the actual astro case.
        case achromatic
        /// A separate fit per channel: what PixInsight's DBE and Siril's
        /// subsky do, and the right shape for genuinely coloured skyglow.
        case perChannel
    }

    /// Neutralises the background cast by aligning the channel medians.
    ///
    /// Additive rather than multiplicative: light pollution *adds* photons to
    /// the frame, so removing it is a subtraction. A per-channel gain would
    /// also rescale real signal and change the colour of the stars.
    public static func neutraliseBackground(_ image: RGBImage) -> RGBImage {
        let medians = image.planes.map { AutoStretch.median(of: $0.pixels) }
        let target = medians.reduce(0, +) / Float(medians.count)

        let shifted = zip(image.planes, medians).map { plane, median -> FloatImage in
            let offset = target - median
            guard abs(offset) > .ulpOfOne else { return plane }
            return FloatImage(width: plane.width, height: plane.height,
                              pixels: plane.pixels.map { $0 + offset }) ?? plane
        }
        return image.withPlanes(shifted) ?? image
    }

    /// Removes the fitted background ramp by the chosen mode.
    public static func removeGradient(_ image: RGBImage, mode: GradientMode) -> RGBImage {
        switch mode {
        case .off:
            return image
        case .perChannel:
            return image.map { BackgroundExtraction.removeGradient($0) }
        case .achromatic:
            let luminance = image.luminance
            guard let surface = BackgroundExtraction.fitSurface(luminance) else { return image }
            let luminanceLevel = Double(AutoStretch.median(of: luminance.pixels))
            guard luminanceLevel > 1e-9 else { return image }

            let planes = image.planes.map { plane -> FloatImage in
                // Scale the common shape to this channel's own level, so a
                // brighter channel has a proportionally larger ramp removed.
                // Ratios between channels are preserved, which is what stops
                // this step from inventing colour.
                let scale = Double(AutoStretch.median(of: plane.pixels)) / luminanceLevel
                return BackgroundExtraction.subtract(surface.map { $0 * scale }, from: plane)
            }
            return image.withPlanes(planes) ?? image
        }
    }

    /// The full linear-to-display chain.
    ///
    /// - Parameter measuredSigma: true noise σ of the luminance, from
    ///   `TemporalNoise`. This is what makes a stack look better than a frame:
    ///   lower noise clips closer to the background and lifts faint signal
    ///   further.
    public static func display(_ image: RGBImage,
                               measuredSigma: Double? = nil,
                               gradient: GradientMode = .perChannel) -> RGBImage {
        let flattened = removeGradient(image, mode: gradient)
        let neutral = neutraliseBackground(flattened)

        let parameters = AutoStretch.parameters(for: neutral.luminance,
                                                measuredSigma: measuredSigma)
        return neutral.map { AutoStretch.apply(parameters, to: $0) }
    }
}
