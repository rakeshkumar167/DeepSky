import Testing
import Foundation
@testable import DeepSkyProcessing

private func flat(_ size: Int, _ level: Float) -> RGBImage {
    RGBImage(grey: FloatImage(width: size, height: size,
                              pixels: [Float](repeating: level, count: size * size))!)
}

/// A soft diagonal band — the Milky Way's own scale — on a flat sky.
private func bandedSky(size: Int, level: Float = 0.25, amplitude: Float = 0.08) -> RGBImage {
    var pixels = [Float](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            let across = Double(x + y) / Double(2 * size - 2)
            let band = exp(-pow((across - 0.5) / 0.18, 2))
            pixels[y * size + x] = level + amplitude * Float(band)
        }
    }
    let plane = FloatImage(width: size, height: size, pixels: pixels)!
    return RGBImage(grey: plane)
}

private struct Noise {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 | 1 }
    mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(state >> 40) / Float(1 << 24) - 0.5
    }
}

struct BlurTests {

    /// A blur must not change the overall level — a zero-padded implementation
    /// would darken every edge and put a frame around the image.
    @Test func preservesLevelAndDoesNotDarkenEdges() {
        let size = 32
        let image = FloatImage(width: size, height: size,
                               pixels: [Float](repeating: 0.4, count: size * size))!
        let blurred = Blur.gaussianApproximation(image, radius: 5)
        for value in blurred.pixels {
            #expect(abs(value - 0.4) < 1e-4, "level moved to \(value)")
        }
    }

    @Test func actuallySmoothsAStep() {
        let size = 32
        var pixels = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size { pixels[y * size + x] = x < size / 2 ? 0.2 : 0.8 }
        }
        let image = FloatImage(width: size, height: size, pixels: pixels)!
        let blurred = Blur.gaussianApproximation(image, radius: 4)

        // The hard step becomes a ramp: values either side of the boundary
        // must have moved toward each other.
        let row = (size / 2) * size
        #expect(blurred.pixels[row + size / 2 - 1] > 0.2 + 1e-3)
        #expect(blurred.pixels[row + size / 2] < 0.8 - 1e-3)
    }

    @Test func aZeroRadiusIsAnIdentity() {
        let image = FloatImage(width: 8, height: 8,
                               pixels: (0..<64).map { Float($0) / 64 })!
        #expect(Blur.gaussianApproximation(image, radius: 0).pixels == image.pixels)
    }
}

struct MilkyWayEnhanceTests {

    /// OFF must mean OFF, to the bit.
    @Test func zeroAmountIsExactlyTheIdentity() {
        let sky = bandedSky(size: 64)
        let result = MilkyWayEnhance.apply(sky, amount: 0)
        #expect(result.red.pixels == sky.red.pixels)
        #expect(result.green.pixels == sky.green.pixels)
        #expect(result.blue.pixels == sky.blue.pixels)
    }

    @Test func negativeAndExcessiveAmountsAreClamped() {
        let sky = bandedSky(size: 32)
        #expect(MilkyWayEnhance.apply(sky, amount: -1).red.pixels == sky.red.pixels)

        let maxed = MilkyWayEnhance.apply(sky, amount: 5)
        let atOne = MilkyWayEnhance.apply(sky, amount: 1)
        #expect(maxed.red.pixels == atOne.red.pixels)
    }

    /// **THE spec constraint** (§18, §43): where no structure exists, none may
    /// be created. A featureless sky must come back featureless.
    @Test func inventsNothingOnAFeaturelessSky() {
        let blank = flat(64, 0.3)
        let result = MilkyWayEnhance.apply(blank, amount: 1)

        for i in 0..<result.red.pixels.count {
            #expect(abs(result.red.pixels[i] - 0.3) < 2e-3,
                    "manufactured structure: \(result.red.pixels[i]) at \(i)")
        }
    }

    /// Structure that IS present must be amplified, and more so as the slider
    /// rises. Without this the control does nothing and the test above passes
    /// trivially.
    @Test func amplifiesStructureThatExists() {
        let sky = bandedSky(size: 96)

        func bandContrast(_ image: RGBImage) -> Float {
            let plane = image.luminance
            let centre = plane[48, 48]            // on the band
            let corner = plane[4, 4]              // off it
            return centre - corner
        }

        let original = bandContrast(sky)
        let half = bandContrast(MilkyWayEnhance.apply(sky, amount: 0.5))
        let full = bandContrast(MilkyWayEnhance.apply(sky, amount: 1))

        #expect(half > original, "half strength did not raise contrast")
        #expect(full > half, "the slider is not monotonic")
    }

    /// A band-pass, not a high-pass: noise sits below the small scale and must
    /// not be boosted along with the structure. This is what separates
    /// "enhance the Milky Way" from "make the grain louder".
    @Test func doesNotAmplifyPixelNoise() {
        let size = 96
        var rand = Noise(seed: 4242)
        var pixels = [Float](repeating: 0, count: size * size)
        for i in 0..<pixels.count { pixels[i] = 0.3 + rand.next() * 0.02 }
        let noisy = RGBImage(grey: FloatImage(width: size, height: size, pixels: pixels)!)

        func pixelToPixelVariation(_ image: RGBImage) -> Float {
            let plane = image.luminance
            var total: Float = 0
            for y in 0..<size {
                for x in 1..<size {
                    total += abs(plane[x, y] - plane[x - 1, y])
                }
            }
            return total / Float(size * (size - 1))
        }

        let before = pixelToPixelVariation(noisy)
        let after = pixelToPixelVariation(MilkyWayEnhance.apply(noisy, amount: 1))
        #expect(after < before * 1.25,
                "noise grew from \(before) to \(after) — this is a high-pass, not a band-pass")
    }

    /// Stars are below the small scale too, so they must not balloon. §19
    /// covers star enhancement; this control must stay out of it.
    @Test func doesNotEnlargeStars() {
        let size = 96
        var pixels = [Float](repeating: 0.2, count: size * size)
        pixels[48 * size + 48] = 0.9
        pixels[48 * size + 47] = 0.5
        pixels[48 * size + 49] = 0.5
        let starField = RGBImage(grey: FloatImage(width: size, height: size, pixels: pixels)!)

        let enhanced = MilkyWayEnhance.apply(starField, amount: 1).luminance
        // Four pixels out from the star should still be background.
        #expect(abs(enhanced[52, 48] - 0.2) < 0.02,
                "the star spread outward: \(enhanced[52, 48])")
    }

    /// Hue must survive. The brightness change is applied as a ratio precisely
    /// so a boosted region does not drift toward grey or toward one channel.
    @Test func preservesHue() {
        let size = 64
        var pixels = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let across = Double(x) / Double(size - 1)
                pixels[y * size + x] = Float(0.2 + 0.1 * exp(-pow((across - 0.5) / 0.2, 2)))
            }
        }
        let shape = FloatImage(width: size, height: size, pixels: pixels)!
        // A distinctly warm sky: red twice blue.
        let warm = RGBImage(red: shape,
                            green: FloatImage(width: size, height: size,
                                              pixels: shape.pixels.map { $0 * 0.7 })!,
                            blue: FloatImage(width: size, height: size,
                                             pixels: shape.pixels.map { $0 * 0.5 })!)!

        let enhanced = MilkyWayEnhance.apply(warm, amount: 0.6)
        let index = 32 * size + 32
        let originalRatio = warm.red.pixels[index] / warm.blue.pixels[index]
        let enhancedRatio = enhanced.red.pixels[index] / enhanced.blue.pixels[index]

        // Saturation deliberately widens the ratio a little; it must not
        // collapse or invert it.
        #expect(enhancedRatio > originalRatio * 0.95,
                "hue collapsed: \(originalRatio) -> \(enhancedRatio)")
        #expect(enhancedRatio < originalRatio * 1.8,
                "colour ran away: \(originalRatio) -> \(enhancedRatio)")
    }

    @Test func outputStaysInRangeAndFinite() {
        let sky = bandedSky(size: 48, level: 0.9, amplitude: 0.3)
        let enhanced = MilkyWayEnhance.apply(sky, amount: 1)
        for plane in enhanced.planes {
            for value in plane.pixels {
                #expect(value.isFinite)
                #expect(value >= 0 && value <= 1)
            }
        }
    }

    /// A near-black frame must not be multiplied into artefacts by the ratio.
    @Test func handlesNearBlackWithoutBlowingUp() {
        let dark = flat(32, 1e-8)
        let enhanced = MilkyWayEnhance.apply(dark, amount: 1)
        for value in enhanced.red.pixels {
            #expect(value.isFinite)
            #expect(value < 0.01, "a black frame produced \(value)")
        }
    }
}
