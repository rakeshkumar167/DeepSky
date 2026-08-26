import Testing
import Foundation
@testable import DeepSkyProcessing

private struct Rand {
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

/// A fixed scene with strong structure, plus independent noise per frame.
/// Structure is identical across frames — exactly the situation that fooled
/// the spatial measurement.
private func sceneFrame(size: Int, noiseSigma: Double, seed: UInt64) -> FloatImage {
    var rand = Rand(seed: seed)
    var pixels = [Float](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            // Deterministic structure, an order of magnitude above the noise.
            let structure = 0.2 + 0.15 * Float(sin(Double(x) / 7)) * Float(cos(Double(y) / 11))
            pixels[y * size + x] = structure + Float(rand.gaussian(noiseSigma))
        }
    }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

struct TemporalNoiseTests {
    static let size = 128
    static let region = PatchRegion(x: 0, y: 0, width: 128, height: 128)

    /// The measurement must recover the TRUE noise level, not the structure.
    @Test func recoversTrueNoiseDespiteStrongStructure() throws {
        let trueSigma = 0.004
        let a = sceneFrame(size: Self.size, noiseSigma: trueSigma, seed: 1)
        let b = sceneFrame(size: Self.size, noiseSigma: trueSigma, seed: 2)

        let measured = try #require(TemporalNoise.perFrame(a, b, in: Self.region))
        #expect(abs(measured - trueSigma) / trueSigma < 0.15,
                "measured \(measured), true \(trueSigma)")
    }

    /// Demonstrates the failure this type exists to fix: spatial σ over the
    /// same frame is dominated by structure and reports noise many times too
    /// high.
    @Test func spatialMeasurementIsDominatedByStructure() {
        let trueSigma = 0.004
        let frame = sceneFrame(size: Self.size, noiseSigma: trueSigma, seed: 1)
        let spatial = NoiseMeasurement.standardDeviation(frame, in: Self.region)
        #expect(spatial > trueSigma * 5,
                "expected spatial sigma to be inflated by structure, got \(spatial)")
    }

    /// THE property. Stacking N frames must reduce temporal noise by √N, and
    /// this measurement must be able to see it.
    @Test func stackNoiseFallsAsSquareRootOfFrameCount() throws {
        let trueSigma = 0.01
        for n in [4, 8, 16] {
            let frames = (0..<n).map {
                sceneFrame(size: Self.size, noiseSigma: trueSigma, seed: UInt64(100 + $0))
            }
            let single = try #require(
                TemporalNoise.perFrame(frames[0], frames[1], in: Self.region))
            let stacked = try #require(TemporalNoise.ofStack(frames, in: Self.region))

            let improvement = single / stacked
            let ideal = Double(n).squareRoot()
            #expect(abs(improvement - ideal) / ideal < 0.20,
                    "N=\(n): improvement \(improvement), ideal \(ideal)")
        }
    }

    @Test func needsAtLeastTwoFrames() {
        let one = [sceneFrame(size: 32, noiseSigma: 0.01, seed: 1)]
        #expect(TemporalNoise.ofStack(one, in: PatchRegion(x: 0, y: 0, width: 32, height: 32)) == nil)
    }

    @Test func rejectsMismatchedDimensions() {
        let a = sceneFrame(size: 32, noiseSigma: 0.01, seed: 1)
        let b = sceneFrame(size: 64, noiseSigma: 0.01, seed: 2)
        #expect(TemporalNoise.perFrame(a, b, in: PatchRegion(x: 0, y: 0, width: 32, height: 32)) == nil)
    }
}
