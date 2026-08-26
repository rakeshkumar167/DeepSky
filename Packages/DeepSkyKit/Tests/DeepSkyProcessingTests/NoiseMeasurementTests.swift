import Testing
import Foundation
@testable import DeepSkyProcessing

private func noisyImage(size: Int, level: Float, sigma: Double, seed: UInt64) -> FloatImage {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407 | 1
    func nextUnit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    func gaussian() -> Double {
        let u1 = max(nextUnit(), 1e-12), u2 = nextUnit()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    let pixels = (0..<(size * size)).map { _ in level + Float(gaussian()) }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

@Test func measuresKnownNoiseAccurately() {
    let image = noisyImage(size: 128, level: 0.2, sigma: 0.01, seed: 42)
    let region = PatchRegion(x: 0, y: 0, width: 128, height: 128)
    let measured = NoiseMeasurement.standardDeviation(image, in: region)
    #expect(abs(measured - 0.01) / 0.01 < 0.10)   // within 10% of truth
}

/// A star inside the measurement region must not masquerade as noise.
@Test func excludesTheBrightestPixelsSoAStarCannotDominate() {
    var pixels = [Float](repeating: 0.2, count: 64 * 64)
    for i in 0..<40 { pixels[i] = 5.0 }
    let image = FloatImage(width: 64, height: 64, pixels: pixels)!
    let region = PatchRegion(x: 0, y: 0, width: 64, height: 64)
    #expect(NoiseMeasurement.standardDeviation(image, in: region) < 0.01)
}

@Test func backgroundRegionAvoidsTheBrightestArea() throws {
    var pixels = [Float](repeating: 0.1, count: 256 * 256)
    for y in 0..<64 { for x in 0..<64 { pixels[y * 256 + x] = 3.0 } }
    let image = FloatImage(width: 256, height: 256, pixels: pixels)!
    let region = try #require(NoiseMeasurement.backgroundRegion(image, size: 64))
    #expect(!(region.x < 64 && region.y < 64))
}

@Test func rejectsAnOutOfBoundsRegion() {
    let image = FloatImage(width: 32, height: 32, pixels: [Float](repeating: 0.5, count: 1024))!
    let outside = PatchRegion(x: 20, y: 20, width: 40, height: 40)
    #expect(NoiseMeasurement.standardDeviation(image, in: outside) == 0)
}

@Test func floatImageRejectsMismatchedPixelCount() {
    #expect(FloatImage(width: 4, height: 4, pixels: [Float](repeating: 0, count: 15)) == nil)
    #expect(FloatImage(width: 0, height: 0, pixels: []) == nil)
}
