import Testing
import Foundation
@testable import DeepSkyProcessing

private func rampImage(size: Int, low: Float, high: Float) -> FloatImage {
    let pixels = (0..<(size * size)).map { i in
        low + (high - low) * Float(i) / Float(size * size - 1)
    }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

@Test func liftsSkyBackgroundToTheTargetLevel() {
    var pixels = [Float](repeating: 0.02, count: 64 * 64)
    for i in 0..<50 { pixels[i] = 0.4 }
    let mapped = ToneMapper.map(FloatImage(width: 64, height: 64, pixels: pixels)!)

    let sorted = mapped.pixels.sorted()
    let median = sorted[sorted.count / 2]
    #expect(abs(median - ToneMapper.targetBackground) < 0.06,
            "background landed at \(median), target \(ToneMapper.targetBackground)")
}

/// Crushing the black point loses the faintest real signal, which is the
/// opposite of the point of stacking.
@Test func doesNotCrushTheBackgroundToZero() {
    var pixels = [Float](repeating: 0.02, count: 64 * 64)
    for i in 0..<50 { pixels[i] = 0.4 }
    let mapped = ToneMapper.map(FloatImage(width: 64, height: 64, pixels: pixels)!)
    let sorted = mapped.pixels.sorted()
    #expect(sorted[sorted.count / 2] > 0.01)
}

@Test func isMonotonic() {
    let mapped = ToneMapper.map(rampImage(size: 32, low: 0.0, high: 1.0))
    for i in 1..<mapped.pixels.count {
        #expect(mapped.pixels[i] >= mapped.pixels[i - 1] - 1e-6)
    }
}

@Test func outputStaysInRange() {
    let mapped = ToneMapper.map(rampImage(size: 32, low: -0.5, high: 4.0))
    #expect(mapped.pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(mapped.pixels.allSatisfy { $0.isFinite })
}

/// Fixed, not adaptive: the same input must always give the same output, so
/// two sessions of one target are comparable.
@Test func isDeterministic() {
    let image = rampImage(size: 16, low: 0.01, high: 0.9)
    #expect(ToneMapper.map(image).pixels == ToneMapper.map(image).pixels)
}

@Test func handlesAUniformImageWithoutProducingNaN() {
    let flat = FloatImage(width: 16, height: 16, pixels: [Float](repeating: 0.3, count: 256))!
    #expect(ToneMapper.map(flat).pixels.allSatisfy { $0.isFinite })
}
