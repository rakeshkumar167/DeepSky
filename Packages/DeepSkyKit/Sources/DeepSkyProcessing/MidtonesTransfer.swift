import Foundation

/// The midtones transfer function — the stretch every serious astro tool uses.
///
/// A linear gain cannot do this job, and that is not a matter of tuning. To
/// make a stack look like an astrophotograph the curve has to do three things
/// at once: hold the background dark, lift faint signal well clear of it, and
/// still not blow out the stars. Those demand three different slopes, and a
/// straight line has only one. This rational function has a steep slope near
/// black that flattens toward white, which is exactly the shape required.
///
/// `m` is the midtone balance, defined as the input that maps to 0.5. Below
/// 0.5 it brightens midtones; above, it darkens them.
public enum MidtonesTransfer {

    /// MTF(x, m), as specified by PixInsight's HistogramTransformation and
    /// used identically by Siril's autostretch.
    public static func apply(_ x: Float, midtone m: Float) -> Float {
        // The endpoints are fixed points of the function and are special-cased
        // because the general expression divides by zero at m = 0 and m = 1.
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if m <= 0 { return 1 }
        if m >= 1 { return 0 }
        if x == m { return 0.5 }

        let denominator = (2 * m - 1) * x - m
        guard abs(denominator) > .ulpOfOne else { return x }
        return (m - 1) * x / denominator
    }

    /// The midtone balance that maps `background` to `target`.
    ///
    /// Solving MTF(x, m) = target for m gives
    ///     m = x(1 − t) / (x − 2tx + t)
    /// which is algebraically identical to MTF(x, t) — the function is
    /// self-symmetric in its two arguments. That identity is why the whole
    /// auto-stretch needs no numerical root-finding, and it is verified
    /// against the definition in `MidtonesTransferTests`.
    public static func midtone(mappingBackground background: Float,
                               to target: Float) -> Float {
        apply(background, midtone: target)
    }
}
