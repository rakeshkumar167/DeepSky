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

private func noisyField(size: Int, level: Float, sigma: Double, seed: UInt64) -> FloatImage {
    var noise = Noise(seed: seed)
    let pixels = (0..<(size * size)).map { _ in level + Float(noise.gaussian(sigma)) }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

/// A faint feature sitting just above the background — the thing stacking is
/// supposed to make visible.
private func fieldWithFaintDetail(size: Int, level: Float, sigma: Double,
                                  featureAmplitude: Float, seed: UInt64) -> FloatImage {
    var noise = Noise(seed: seed)
    var pixels = [Float]()
    pixels.reserveCapacity(size * size)
    for y in 0..<size {
        for x in 0..<size {
            let inFeature = x >= size / 2
            let base = level + (inFeature ? featureAmplitude : 0)
            pixels.append(base + Float(noise.gaussian(sigma)))
        }
    }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

struct AutoStretchTests {
    @Test func noiseSigmaTracksTheActualNoiseLevel() {
        let quiet = noisyField(size: 128, level: 0.2, sigma: 0.002, seed: 1)
        let loud = noisyField(size: 128, level: 0.2, sigma: 0.02, seed: 1)
        #expect(AutoStretch.noiseSigma(loud) > AutoStretch.noiseSigma(quiet) * 5)
    }

    /// THE point of this type. A cleaner image must receive a stronger stretch,
    /// because that is the mechanism by which stacking reveals faint detail —
    /// not by adding brightness, which averaging cannot do.
    @Test func cleanerImageReceivesAStrongerStretch() {
        let noisy = noisyField(size: 128, level: 0.2, sigma: 0.02, seed: 5)
        let clean = noisyField(size: 128, level: 0.2, sigma: 0.005, seed: 5)

        // A SMALLER midtone is a more aggressive stretch: it is the input that
        // maps to 0.5, so pulling it down lifts everything below it.
        let noisyMidtone = AutoStretch.parameters(for: noisy).midtone
        let cleanMidtone = AutoStretch.parameters(for: clean).midtone

        #expect(cleanMidtone < noisyMidtone / 2,
                "clean midtone \(cleanMidtone) should be far below noisy \(noisyMidtone)")
    }

    /// The stretch must scale with the noise it is given, not with the image's
    /// own histogram spread — that is the whole reason a stack looks better
    /// than a frame. Same image, three times less noise, three times harder
    /// stretch.
    @Test func aMeasuredSigmaDrivesTheStretchInsteadOfTheHistogram() {
        let image = noisyField(size: 128, level: 0.2, sigma: 0.02, seed: 3)

        let asSingle = AutoStretch.parameters(for: image, measuredSigma: 0.003)
        let asStack = AutoStretch.parameters(for: image, measuredSigma: 0.001)

        #expect(asStack.midtone < asSingle.midtone,
                "lower measured noise must stretch harder")
        #expect(asStack.black > asSingle.black,
                "lower measured noise must clip closer to the background")
    }

    /// Both images land their background on the same target — that is the
    /// definition of the stretch. The difference has to show up in the faint
    /// signal above it, not in the background level.
    @Test func theBackgroundLandsOnTheTargetRegardlessOfNoise() {
        let image = noisyField(size: 128, level: 0.2, sigma: 0.02, seed: 4)
        for sigma in [0.0005, 0.002, 0.01] {
            let mapped = AutoStretch.map(image, measuredSigma: sigma)
            let median = AutoStretch.median(of: mapped.pixels)
            #expect(abs(median - AutoStretch.targetBackground) < 0.02,
                    "sigma \(sigma) landed background at \(median)")
        }
    }

    /// The user-visible consequence, stated in absolute terms: a fixed faint
    /// signal is lifted higher when the noise behind it is lower.
    @Test func aFixedFaintSignalIsLiftedHigherWhenNoiseIsLower() {
        let level: Float = 0.2
        let signal: Float = 0.2 + 0.004
        let image = noisyField(size: 64, level: level, sigma: 0.001, seed: 9)

        func lifted(_ sigma: Double) -> Float {
            let p = AutoStretch.parameters(for: image, measuredSigma: sigma)
            let span = max(1 - p.black, 1e-6)
            return MidtonesTransfer.apply(min(max((signal - p.black) / span, 0), 1),
                                          midtone: p.midtone)
        }

        #expect(lifted(0.001) > lifted(0.004),
                "the same signal must come out brighter from a quieter image")
    }

    /// The user-visible consequence: faint detail that is buried in a noisy frame
    /// becomes separable once the image is clean enough to stretch harder.
    @Test func faintDetailBecomesMoreSeparableInACleanerImage() {
        let amplitude: Float = 0.004
        let noisy = fieldWithFaintDetail(size: 128, level: 0.2, sigma: 0.02,
                                         featureAmplitude: amplitude, seed: 11)
        let clean = fieldWithFaintDetail(size: 128, level: 0.2, sigma: 0.004,
                                         featureAmplitude: amplitude, seed: 11)

        func featureContrast(_ image: FloatImage) -> Double {
            let stretched = AutoStretch.map(image)
            var left = [Double](), right = [Double]()
            for y in 0..<stretched.height {
                for x in 0..<stretched.width {
                    (x >= stretched.width / 2 ? { right.append(Double(stretched[x, y])) }
                                              : { left.append(Double(stretched[x, y])) })()
                }
            }
            let meanLeft = left.reduce(0, +) / Double(left.count)
            let meanRight = right.reduce(0, +) / Double(right.count)
            return abs(meanRight - meanLeft)
        }

        #expect(featureContrast(clean) > featureContrast(noisy),
                "the same faint feature should read stronger in the cleaner image")
    }

    @Test func backgroundLandsNearTheTarget() {
        let image = noisyField(size: 128, level: 0.2, sigma: 0.01, seed: 3)
        let stretched = AutoStretch.map(image)
        let sorted = stretched.pixels.sorted()
        let median = sorted[sorted.count / 2]
        #expect(abs(median - AutoStretch.targetBackground) < 0.08,
                "background landed at \(median), target \(AutoStretch.targetBackground)")
    }

    @Test func outputStaysInRange() {
        let image = noisyField(size: 64, level: 0.2, sigma: 0.01, seed: 9)
        let stretched = AutoStretch.map(image)
        #expect(stretched.pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(stretched.pixels.allSatisfy { $0.isFinite })
    }

    @Test func isDeterministic() {
        let image = noisyField(size: 32, level: 0.2, sigma: 0.01, seed: 4)
        #expect(AutoStretch.map(image).pixels == AutoStretch.map(image).pixels)
    }

    @Test func isMonotonic() {
        let ramp = FloatImage(width: 32, height: 32,
                              pixels: (0..<1024).map { Float($0) / 1023 })!
        let stretched = AutoStretch.map(ramp)
        for i in 1..<stretched.pixels.count {
            #expect(stretched.pixels[i] >= stretched.pixels[i - 1] - 1e-6)
        }
    }

    @Test func handlesAUniformImageWithoutProducingNaN() {
        let flat = FloatImage(width: 16, height: 16, pixels: [Float](repeating: 0.3, count: 256))!
        #expect(AutoStretch.map(flat).pixels.allSatisfy { $0.isFinite })
    }
}
