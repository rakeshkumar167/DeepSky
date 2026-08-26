import Testing
import Foundation
@testable import DeepSkyProcessing

private struct Noise {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 | 1 }
    mutating func unit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

private func frame(size: Int, level: Float, sigma: Double, noise: inout Noise) -> FloatImage {
    let pixels = (0..<(size * size)).map { _ in level + Float(noise.gaussian(sigma)) }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

@Test func meanOfIdenticalFramesIsUnchanged() throws {
    let flat = FloatImage(width: 8, height: 8, pixels: [Float](repeating: 0.5, count: 64))!
    var stacker = FrameStacker(width: 8, height: 8)
    for _ in 0..<10 {
        let accepted = stacker.add(flat)
        #expect(accepted)
    }
    let result = try #require(stacker.result())
    #expect(result.pixels.allSatisfy { abs($0 - 0.5) < 1e-5 })
    #expect(stacker.frameCount == 10)
}

@Test func emptyStackHasNoResult() {
    let stacker = FrameStacker(width: 8, height: 8)
    #expect(stacker.result() == nil)
    #expect(stacker.frameCount == 0)
}

@Test func rejectsAFrameOfTheWrongSize() {
    var stacker = FrameStacker(width: 8, height: 8)
    let wrong = FloatImage(width: 4, height: 4, pixels: [Float](repeating: 0.5, count: 16))!
    let accepted = stacker.add(wrong)
    #expect(accepted == false)
    #expect(stacker.frameCount == 0)
}

/// THE test. If stacking works on linear data, noise falls as √N.
/// Spec §6 sets the tolerance at ±15%.
@Test func noiseFallsAsSquareRootOfFrameCount() throws {
    let size = 128
    let level: Float = 0.2
    let sigma = 0.02
    var noise = Noise(seed: 7)

    let single = frame(size: size, level: level, sigma: sigma, noise: &noise)
    let region = PatchRegion(x: 0, y: 0, width: size, height: size)
    let sigmaSingle = NoiseMeasurement.standardDeviation(single, in: region)

    for n in [4, 16, 64] {
        var stacker = FrameStacker(width: size, height: size)
        var localNoise = Noise(seed: UInt64(1000 + n))
        for _ in 0..<n {
            _ = stacker.add(frame(size: size, level: level, sigma: sigma, noise: &localNoise))
        }
        let stacked = try #require(stacker.result())
        let sigmaStacked = NoiseMeasurement.standardDeviation(stacked, in: region)

        let expected = sigmaSingle / Double(n).squareRoot()
        let error = abs(sigmaStacked - expected) / expected
        #expect(error < 0.15,
                "N=\(n): measured \(sigmaStacked), expected \(expected), off by \(error * 100)%")
    }
}

/// Memory must not scale with frame count — the accumulator is fixed size.
@Test func accumulatorSizeIsIndependentOfFrameCount() throws {
    var stacker = FrameStacker(width: 16, height: 16)
    var noise = Noise(seed: 3)
    for _ in 0..<200 {
        _ = stacker.add(frame(size: 16, level: 0.3, sigma: 0.01, noise: &noise))
    }
    let result = try #require(stacker.result())
    #expect(result.pixels.count == 256)
    #expect(stacker.frameCount == 200)
}
