import Foundation

/// Measures noise from differences between frames rather than from variation
/// within one frame.
///
/// This exists because the spatial measurement it replaces was wrong for the
/// job, and wrong in a way that hid the entire benefit of stacking. Measured
/// on a real session: spatial σ over a 256×256 patch read 0.015, while the
/// frame-to-frame difference implied true sensor noise of about 0.0012. So
/// roughly 92% of what was being called "noise" was scene structure — and
/// structure does not average away, because it is the same in every frame.
///
/// Differencing two frames of a static scene cancels the structure exactly and
/// leaves only the random component. That is how sensor noise is measured from
/// a burst, and it is the only measurement here that can see what stacking
/// actually does.
public enum TemporalNoise {

    /// Per-frame noise σ, from the difference of two frames.
    ///
    /// Differencing doubles the variance, so σ(A−B) = σ_frame·√2.
    public static func perFrame(_ a: FloatImage, _ b: FloatImage,
                                in region: PatchRegion) -> Double? {
        guard let diff = difference(a, b) else { return nil }
        return NoiseMeasurement.standardDeviation(diff, in: region) / 2.0.squareRoot()
    }

    /// Noise σ of a stack of `frames`, estimated by splitting it into two
    /// independent half-stacks and differencing them.
    ///
    /// Each half holds N/2 frames, so its noise is σ_frame/√(N/2), and the
    /// difference of the two halves has σ = σ_frame·2/√N. The full stack's
    /// noise is σ_frame/√N — which is exactly half the measured difference.
    ///
    /// Splitting is what makes this honest: there is no noise-free reference
    /// image to compare a stack against, so the stack is compared against an
    /// independent stack of the same scene.
    public static func ofStack(_ frames: [FloatImage],
                               in region: PatchRegion) -> Double? {
        guard frames.count >= 2 else { return nil }

        var even = FrameStacker(width: frames[0].width, height: frames[0].height)
        var odd = FrameStacker(width: frames[0].width, height: frames[0].height)
        for (i, frame) in frames.enumerated() {
            _ = (i % 2 == 0 ? even.add(frame) : odd.add(frame))
        }
        guard let a = even.result(), let b = odd.result(),
              let diff = difference(a, b) else { return nil }

        return NoiseMeasurement.standardDeviation(diff, in: region) / 2.0
    }

    static func difference(_ a: FloatImage, _ b: FloatImage) -> FloatImage? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var pixels = [Float](repeating: 0, count: a.pixels.count)
        for i in 0..<pixels.count { pixels[i] = a.pixels[i] - b.pixels[i] }
        return FloatImage(width: a.width, height: a.height, pixels: pixels)
    }
}
