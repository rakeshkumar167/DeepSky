import Testing
import Foundation
import DeepSkyMetrics

/// Renders a Gaussian star of a given sigma into a square patch.
private func syntheticStar(size: Int, sigma: Double, background: Float = 0.02) -> LuminancePatch {
    var pixels = [Float](repeating: background, count: size * size)
    let c = Double(size - 1) / 2.0
    for y in 0..<size {
        for x in 0..<size {
            let dx = Double(x) - c, dy = Double(y) - c
            let v = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            pixels[y * size + x] += Float(v)
        }
    }
    return LuminancePatch(width: size, height: size, pixels: pixels)
}

@Test func tighterStarYieldsSmallerHFD() {
    let sharp = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 1.5))
    let blurry = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 4.0))
    #expect(sharp != nil && blurry != nil)
    #expect(sharp! < blurry!)
}

@Test func hfdIncreasesMonotonicallyWithDefocus() {
    // This monotonicity is the entire reason HFD was chosen over contrast metrics.
    let sigmas = [1.0, 2.0, 3.0, 4.0, 5.0]
    let measured = sigmas.compactMap { HalfFluxDiameter.measure(syntheticStar(size: 96, sigma: $0)) }
    #expect(measured.count == sigmas.count)
    for i in 1..<measured.count {
        #expect(measured[i] > measured[i - 1])
    }
}

@Test func returnsNilOnFeaturelessPatch() {
    let flat = LuminancePatch(width: 32, height: 32,
                              pixels: [Float](repeating: 0.05, count: 32 * 32))
    #expect(HalfFluxDiameter.measure(flat) == nil)
}

@Test func isRobustToBackgroundOffset() {
    // A brighter sky must not change the measured star size much.
    let dark = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 2.0, background: 0.01))!
    let bright = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 2.0, background: 0.30))!
    #expect(abs(dark - bright) < 0.5)
}

@Test func rejectsSharpSinglePixelSpike() {
    // A hot/stuck sensor pixel should return nil, not 0.0.
    let spike = LuminancePatch(width: 64, height: 64,
                               pixels: {
        var p = [Float](repeating: 0.02, count: 64 * 64)
        p[31 * 64 + 31] = 1.0
        return p
    }())
    #expect(HalfFluxDiameter.measure(spike) == nil)
}

@Test func acceptsStarWithArtifactualHotPixel() {
    // A real star with a hot pixel elsewhere should still be measurable.
    var pixels = [Float](repeating: 0.02, count: 64 * 64)
    // Normal σ=2.0 star at center
    let c = 31.5
    for y in 0..<64 {
        for x in 0..<64 {
            let dx = Double(x) - c, dy = Double(y) - c
            let v = exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0))
            pixels[y * 64 + x] += Float(v)
        }
    }
    // Add hot pixel elsewhere
    pixels[5 * 64 + 5] = 0.8

    let patch = LuminancePatch(width: 64, height: 64, pixels: pixels)
    let hfd = HalfFluxDiameter.measure(patch)
    #expect(hfd != nil)
    #expect(hfd! > 0.5 && hfd! < 8.0)  // Reasonable range for σ=2.0 star
}
