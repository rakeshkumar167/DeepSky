import Testing
import Foundation
@testable import DeepSkyProcessing

/// A flat sky at `level` with a linear ramp across it, plus optional stars.
private func gradientSky(width: Int, height: Int, level: Float,
                         rampX: Float, rampY: Float,
                         stars: [(Int, Int, Float)] = []) -> FloatImage {
    var pixels = [Float](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let fx = Float(x) / Float(width - 1)
            let fy = Float(y) / Float(height - 1)
            pixels[y * width + x] = level + rampX * fx + rampY * fy
        }
    }
    for (sx, sy, amplitude) in stars {
        for dy in -4...4 {
            for dx in -4...4 {
                let x = sx + dx, y = sy + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let r2 = Double(dx * dx + dy * dy)
                pixels[y * width + x] += amplitude * Float(exp(-r2 / 4.0))
            }
        }
    }
    return FloatImage(width: width, height: height, pixels: pixels)!
}

struct BackgroundExtractionTests {

    /// THE test. A known ramp must come out flat.
    @Test func removesALinearGradient() throws {
        let image = gradientSky(width: 256, height: 256, level: 0.02,
                                rampX: 0.06, rampY: 0.03)

        // Before: corners differ by the full ramp.
        #expect(abs(image[255, 255] - image[0, 0]) > 0.08)

        let flattened = BackgroundExtraction.removeGradient(image)
        let spread = abs(flattened[255, 255] - flattened[0, 0])
        #expect(spread < 0.002, "corners still differ by \(spread)")
    }

    /// Flattening must not change how bright the image is overall — it removes
    /// a ramp, it is not an exposure adjustment.
    @Test func preservesTheOverallLevel() {
        let image = gradientSky(width: 128, height: 128, level: 0.03,
                                rampX: 0.04, rampY: -0.02)
        let before = AutoStretch.median(of: image.pixels)
        let after = AutoStretch.median(of: BackgroundExtraction.removeGradient(image).pixels)
        #expect(abs(after - before) < 0.005, "level moved from \(before) to \(after)")
    }

    /// The point of removing the gradient: the image's own MAD becomes a
    /// usable noise estimate again instead of measuring the ramp.
    @Test func flatteningMakesMADAgreeWithTheTrueNoise() {
        let trueSigma: Float = 0.001
        var pixels = [Float](repeating: 0, count: 256 * 256)
        var seed: UInt64 = 12345
        func noise() -> Float {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 2 * trueSigma * 1.732
        }
        for y in 0..<256 {
            for x in 0..<256 {
                pixels[y * 256 + x] = 0.02 + 0.08 * Float(x) / 255 + noise()
            }
        }
        let image = FloatImage(width: 256, height: 256, pixels: pixels)!

        let before = AutoStretch.noiseSigma(image)
        let after = AutoStretch.noiseSigma(BackgroundExtraction.removeGradient(image))

        #expect(before > trueSigma * 10, "gradient should inflate MAD, got \(before)")
        #expect(after < trueSigma * 3, "flattened MAD should approach true noise, got \(after)")
    }

    /// The surface must be too rigid to swallow real structure. A star sitting
    /// on the sky has to survive flattening.
    @Test func leavesStarsAlone() {
        let image = gradientSky(width: 200, height: 200, level: 0.02,
                                rampX: 0.05, rampY: 0.0,
                                stars: [(100, 100, 0.6)])
        let flattened = BackgroundExtraction.removeGradient(image)
        let starHeight = flattened[100, 100] - AutoStretch.median(of: flattened.pixels)
        #expect(starHeight > 0.5, "star was flattened away, height \(starHeight)")
    }

    /// Tiles dominated by bright structure must be rejected, or the fit chases
    /// the signal and subtracts it.
    ///
    /// A handful of stars is deliberately NOT enough to reject a tile: the
    /// sample is that tile's median, which ignores a small minority of bright
    /// pixels by construction. What rejection is for is a lit horizon or a
    /// nebula core filling the tile — structure a rigid surface would
    /// otherwise try to follow.
    @Test func rejectsTilesThatAreMostlyBrightStructure() {
        let plain = gradientSky(width: 128, height: 128, level: 0.02,
                                rampX: 0.03, rampY: 0)

        // A lit band across the bottom quarter of the frame.
        var pixels = plain.pixels
        for y in 96..<128 {
            for x in 0..<128 { pixels[y * 128 + x] += 0.5 }
        }
        let withHorizon = FloatImage(width: 128, height: 128, pixels: pixels)!

        let plainSamples = BackgroundExtraction.backgroundSamples(plain).count
        let horizonSamples = BackgroundExtraction.backgroundSamples(withHorizon).count
        #expect(horizonSamples < plainSamples,
                "expected the lit band's tiles to be dropped: \(horizonSamples) vs \(plainSamples)")
    }

    /// A frame with no measurable background comes back untouched rather than
    /// having a fabricated surface subtracted from it.
    @Test func returnsTheImageUnchangedWhenTheFitIsUnconstrained() {
        let uniform = FloatImage(width: 4, height: 4,
                                 pixels: [Float](repeating: 0.5, count: 16))!
        let result = BackgroundExtraction.removeGradient(uniform)
        #expect(result.pixels == uniform.pixels)
    }

    @Test func solvesASmallLinearSystem() throws {
        // 2x + y = 5, x + 3y = 10  ->  x = 1, y = 3
        let solution = try #require(BackgroundExtraction.solve([[2, 1], [1, 3]], [5, 10]))
        #expect(abs(solution[0] - 1) < 1e-9)
        #expect(abs(solution[1] - 3) < 1e-9)
    }

    @Test func reportsASingularSystemRatherThanReturningNonsense() {
        #expect(BackgroundExtraction.solve([[1, 2], [2, 4]], [3, 6]) == nil)
    }
}
