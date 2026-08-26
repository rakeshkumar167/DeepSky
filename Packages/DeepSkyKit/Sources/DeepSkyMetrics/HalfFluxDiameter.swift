import Foundation

public struct LuminancePatch: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    /// Returns nil rather than trapping on a malformed patch.
    ///
    /// Live capture buffers are sliced by stride and crop arithmetic this type
    /// does not control. A bad slice must cost one frame, not the session — so
    /// this cannot be a precondition once real buffers reach it.
    public init?(width: Int, height: Int, pixels: [Float]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Float { pixels[y * width + x] }
}

public enum HalfFluxDiameter {
    /// Neighbourhood half-width searched around the peak, in pixels.
    /// 2 gives a 5x5 box: 24 candidate neighbours.
    static let neighbourhoodRadius = 2
    /// Neighbours must exceed this many sigma above background to count as
    /// real signal rather than noise.
    static let significanceSigma = 5.0
    /// Floor for the noise estimate, so a perfectly flat synthetic patch
    /// does not collapse the threshold to zero.
    static let minimumSigma = 1e-6

    /// Returns the half-flux diameter in pixels, or nil when the patch holds
    /// no usable point source.
    ///
    /// 1. background = median of the patch
    /// 2. reject the patch if the peak barely exceeds the background
    /// 3. reject a point source with no significant spatial extent (see below)
    /// 4. flux-weighted centroid of the above-background signal
    /// 5. find the radius enclosing half the total flux
    /// 6. HFD = 2 * that radius
    public static func measure(_ patch: LuminancePatch) -> Double? {
        let sorted = patch.pixels.sorted()
        guard !sorted.isEmpty else { return nil }
        let background = Double(sorted[sorted.count / 2])
        let peak = Double(sorted[sorted.count - 1])

        // A featureless patch has nothing to focus on.
        guard peak - background > 0.05 else { return nil }

        guard let (peakX, peakY) = peakLocation(patch, peak: peak) else { return nil }
        let sigma = noiseSigma(patch, background: background)

        // Reject a point source with no significant spatial extent — a hot or
        // stuck sensor pixel, or a cosmic-ray hit. Without this, such a pixel
        // collapses the centroid onto itself, the r=0 sample already encloses
        // half the flux, and measure() returns 0.0 — which reads as PERFECT
        // FOCUS. Long exposures produce stuck pixels reliably, so this is a
        // routine input, not an exotic one.
        //
        // Two earlier formulations both failed, for opposite reasons:
        //
        //   peakFlux / totalFlux < 0.3 rejected genuinely sharp stars. A
        //   Gaussian landing on a pixel centre concentrates over 40% of its
        //   flux in the peak pixel below ~1.8px FWHM — the sharp end of a
        //   focus sweep, exactly where this metric must not blank out.
        //
        //   "at least 4 neighbours carrying any residual above background"
        //   only discriminates on noise-free data. Background is the MEDIAN,
        //   so on a real sensor roughly half of all pixels sit above it by
        //   some nonzero amount; the count is satisfied by noise alone and
        //   the guard silently becomes a no-op.
        //
        // So significance is measured against the patch's own noise, and the
        // count is scoped to the peak's immediate neighbourhood. Scoping
        // matters: over 24 candidates at 5 sigma (one-tailed p ~ 2.9e-7) the
        // expected false-positive rate is ~7e-6 per patch, whereas counting
        // across a whole 4096-pixel patch would let unrelated bright noise
        // anywhere in frame vouch for a defect pixel.
        let threshold = significanceSigma * sigma
        guard significantNeighbours(patch, peakX: peakX, peakY: peakY,
                                    background: background, threshold: threshold) >= 4
        else { return nil }

        var totalFlux = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for y in 0..<patch.height {
            for x in 0..<patch.width {
                let f = max(0.0, Double(patch[x, y]) - background)
                totalFlux += f
                sumX += f * Double(x)
                sumY += f * Double(y)
            }
        }
        guard totalFlux > 0 else { return nil }

        let cx = sumX / totalFlux
        let cy = sumY / totalFlux

        // Collect (radius, flux) and accumulate outward until half the flux
        // is enclosed.
        var samples: [(r: Double, f: Double)] = []
        samples.reserveCapacity(patch.width * patch.height)
        for y in 0..<patch.height {
            for x in 0..<patch.width {
                let f = max(0.0, Double(patch[x, y]) - background)
                guard f > 0 else { continue }
                let dx = Double(x) - cx, dy = Double(y) - cy
                samples.append((r: (dx * dx + dy * dy).squareRoot(), f: f))
            }
        }
        samples.sort { $0.r < $1.r }

        let halfFlux = totalFlux / 2.0
        var accumulated = 0.0
        for sample in samples {
            accumulated += sample.f
            if accumulated >= halfFlux {
                return 2.0 * sample.r
            }
        }
        return nil
    }

    /// Robust noise estimate from the patch itself — `measure` receives no
    /// calibration input. MAD is used rather than standard deviation because
    /// the star being measured would inflate an SD estimate; 1.4826 is the
    /// standard MAD-to-sigma scaling for Gaussian noise.
    static func noiseSigma(_ patch: LuminancePatch, background: Double) -> Double {
        var deviations = [Double]()
        deviations.reserveCapacity(patch.pixels.count)
        for pixel in patch.pixels {
            deviations.append(abs(Double(pixel) - background))
        }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        return max(1.4826 * mad, minimumSigma)
    }

    static func peakLocation(_ patch: LuminancePatch, peak: Double) -> (Int, Int)? {
        for y in 0..<patch.height {
            for x in 0..<patch.width where Double(patch[x, y]) >= peak {
                return (x, y)
            }
        }
        return nil
    }

    /// Counts pixels within Chebyshev distance `neighbourhoodRadius` of the
    /// peak (excluding the peak itself) whose residual clears `threshold`.
    static func significantNeighbours(
        _ patch: LuminancePatch, peakX: Int, peakY: Int,
        background: Double, threshold: Double
    ) -> Int {
        var count = 0
        let r = neighbourhoodRadius
        for y in (peakY - r)...(peakY + r) {
            guard y >= 0, y < patch.height else { continue }
            for x in (peakX - r)...(peakX + r) {
                guard x >= 0, x < patch.width else { continue }
                if x == peakX && y == peakY { continue }
                if Double(patch[x, y]) - background > threshold { count += 1 }
            }
        }
        return count
    }
}
