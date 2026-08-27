import Testing
import Foundation
@testable import DeepSkyProcessing

private func plane(_ size: Int, _ value: Float) -> FloatImage {
    FloatImage(width: size, height: size, pixels: [Float](repeating: value, count: size * size))!
}

/// A flat sky of the given colour with one brighter star in the middle.
private func colouredSky(size: Int, r: Float, g: Float, b: Float,
                         star: Float = 0) -> RGBImage {
    func channel(_ level: Float) -> FloatImage {
        var pixels = [Float](repeating: level, count: size * size)
        if star > 0 { pixels[(size / 2) * size + size / 2] = level + star }
        return FloatImage(width: size, height: size, pixels: pixels)!
    }
    return RGBImage(red: channel(r), green: channel(g), blue: channel(b))!
}

struct RGBImageTests {

    @Test func rejectsMismatchedPlanes() {
        #expect(RGBImage(red: plane(8, 0.1), green: plane(4, 0.1), blue: plane(8, 0.1)) == nil)
    }

    @Test func luminanceUsesRec709Weights() {
        let image = RGBImage(red: plane(4, 1), green: plane(4, 0), blue: plane(4, 0))!
        #expect(abs(image.luminance.pixels[0] - 0.2126) < 1e-6)

        let green = RGBImage(red: plane(4, 0), green: plane(4, 1), blue: plane(4, 0))!
        #expect(abs(green.luminance.pixels[0] - 0.7152) < 1e-6)
    }

    @Test func greyInitRepeatsTheChannel() {
        let image = RGBImage(grey: plane(4, 0.3))
        #expect(image.red.pixels == image.green.pixels)
        #expect(image.green.pixels == image.blue.pixels)
    }

    /// Every plane must be averaged over the SAME frames, or the channels end
    /// up divided by different counts and the result carries a colour cast
    /// that looks like real sky colour.
    @Test func stackerAveragesEveryPlaneOverTheSameFrames() throws {
        var stacker = RGBStacker(width: 4, height: 4)
        stacker.add(colouredSky(size: 4, r: 0.2, g: 0.4, b: 0.6))
        stacker.add(colouredSky(size: 4, r: 0.4, g: 0.6, b: 0.8))

        let result = try #require(stacker.result())
        #expect(stacker.frameCount == 2)
        #expect(abs(result.red.pixels[0] - 0.3) < 1e-6)
        #expect(abs(result.green.pixels[0] - 0.5) < 1e-6)
        #expect(abs(result.blue.pixels[0] - 0.7) < 1e-6)
    }

    @Test func stackerRejectsAMismatchedFrameWholesale() {
        var stacker = RGBStacker(width: 4, height: 4)
        #expect(stacker.add(colouredSky(size: 8, r: 0.2, g: 0.2, b: 0.2)) == false)
        #expect(stacker.frameCount == 0)
    }

    /// Channels shifted by different amounts would fringe every star.
    @Test func shiftMovesAllThreePlanesTogether() throws {
        let image = colouredSky(size: 16, r: 0.1, g: 0.2, b: 0.3, star: 0.5)
        let moved = try #require(FrameAligner.shift(image, by: Offset(x: 2, y: -1)))

        #expect(abs(moved.red[10, 7] - image.red[8, 8]) < 1e-6)
        #expect(abs(moved.green[10, 7] - image.green[8, 8]) < 1e-6)
        #expect(abs(moved.blue[10, 7] - image.blue[8, 8]) < 1e-6)
    }
}

struct ColourRenderTests {

    /// An orange sky — sodium light pollution — must come out neutral.
    @Test func neutralisationRemovesAColourCast() {
        let cast = colouredSky(size: 32, r: 0.10, g: 0.06, b: 0.03)
        let neutral = ColourRender.neutraliseBackground(cast)

        let medians = neutral.planes.map { AutoStretch.median(of: $0.pixels) }
        #expect(abs(medians[0] - medians[1]) < 1e-5)
        #expect(abs(medians[1] - medians[2]) < 1e-5)
    }

    /// The shift is additive, so signal ABOVE the background keeps its colour.
    /// A per-channel gain would rescale the star too and change its hue.
    @Test func neutralisationPreservesSignalAboveTheBackground() {
        let sky = colouredSky(size: 32, r: 0.10, g: 0.06, b: 0.03, star: 0.4)
        let neutral = ColourRender.neutraliseBackground(sky)

        let centre = 16 * 32 + 16
        func height(_ image: RGBImage, _ plane: Int) -> Float {
            image.planes[plane].pixels[centre] - AutoStretch.median(of: image.planes[plane].pixels)
        }
        for channel in 0..<3 {
            #expect(abs(height(neutral, channel) - height(sky, channel)) < 1e-5,
                    "channel \(channel) changed height above background")
        }
    }

    /// THE colour-safety property. One stretch for all three channels, so a
    /// neutral input stays neutral rather than drifting toward whichever
    /// channel had the most headroom.
    @Test func aNeutralImageStaysNeutralThroughTheStretch() {
        let grey = colouredSky(size: 32, r: 0.05, g: 0.05, b: 0.05, star: 0.3)
        let rendered = ColourRender.display(grey, measuredSigma: 0.001, gradient: .off)

        for i in stride(from: 0, to: 32 * 32, by: 97) {
            #expect(abs(rendered.red.pixels[i] - rendered.green.pixels[i]) < 1e-5)
            #expect(abs(rendered.green.pixels[i] - rendered.blue.pixels[i]) < 1e-5)
        }
    }

    /// Lower noise must still buy a harder stretch in colour, exactly as it
    /// does in luminance — that is the whole reason stacking is worth doing.
    @Test func lowerNoiseLiftsColourFurther() {
        let sky = colouredSky(size: 64, r: 0.05, g: 0.05, b: 0.05, star: 0.02)
        let centre = 32 * 64 + 32

        let noisy = ColourRender.display(sky, measuredSigma: 0.004, gradient: .off)
        let clean = ColourRender.display(sky, measuredSigma: 0.001, gradient: .off)

        #expect(clean.green.pixels[centre] > noisy.green.pixels[centre],
                "the same star must come out brighter from the quieter image")
    }

    /// Achromatic removal must not create a cast where there was none: a
    /// neutral ramp has to come out neutral. This is the one property that
    /// distinguishes it from the per-channel fit, and the reason it exists.
    @Test func achromaticRemovalCannotCreateAColourCast() {
        let size = 64
        func ramp(_ level: Float) -> FloatImage {
            var pixels = [Float](repeating: 0, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    pixels[y * size + x] = level * (1 + 0.8 * Float(x) / Float(size - 1))
                }
            }
            return FloatImage(width: size, height: size, pixels: pixels)!
        }
        // A neutral grey ramp: all three channels share one shape and level.
        let neutral = RGBImage(red: ramp(0.05), green: ramp(0.05), blue: ramp(0.05))!
        let flattened = ColourRender.removeGradient(neutral, mode: .achromatic)

        for i in stride(from: 0, to: size * size, by: 53) {
            #expect(abs(flattened.red.pixels[i] - flattened.green.pixels[i]) < 1e-5)
            #expect(abs(flattened.green.pixels[i] - flattened.blue.pixels[i]) < 1e-5)
        }
    }

    /// Whichever mode, the ramp itself must actually go.
    @Test func bothModesFlattenARamp() {
        let size = 64
        func ramp(_ level: Float) -> FloatImage {
            var pixels = [Float](repeating: 0, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    pixels[y * size + x] = level + 0.06 * Float(x) / Float(size - 1)
                }
            }
            return FloatImage(width: size, height: size, pixels: pixels)!
        }
        let sky = RGBImage(red: ramp(0.04), green: ramp(0.05), blue: ramp(0.06))!

        for mode in [ColourRender.GradientMode.achromatic, .perChannel] {
            let flattened = ColourRender.removeGradient(sky, mode: mode)
            let spread = abs(flattened.green[size - 1, size / 2] - flattened.green[0, size / 2])
            #expect(spread < 0.004, "\(mode) left a ramp of \(spread)")
        }
    }

    @Test func gradientModeOffChangesNothing() {
        let sky = colouredSky(size: 16, r: 0.1, g: 0.2, b: 0.3, star: 0.4)
        let same = ColourRender.removeGradient(sky, mode: .off)
        #expect(same.red.pixels == sky.red.pixels)
        #expect(same.blue.pixels == sky.blue.pixels)
    }

    /// The background lands on the target regardless of what colour it started.
    @Test func theBackgroundLandsOnTheTarget() {
        let cast = colouredSky(size: 32, r: 0.10, g: 0.06, b: 0.03)
        let rendered = ColourRender.display(cast, measuredSigma: 0.002, gradient: .off)
        let median = AutoStretch.median(of: rendered.luminance.pixels)
        #expect(abs(median - AutoStretch.targetBackground) < 0.02,
                "background landed at \(median)")
    }
}
