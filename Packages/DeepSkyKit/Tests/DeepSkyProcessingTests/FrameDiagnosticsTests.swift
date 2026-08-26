import Testing
import Foundation
@testable import DeepSkyProcessing

/// Diagnostics for a real session, printed rather than asserted.
///
/// Exists because stacking well-aligned real frames still raised measured
/// noise, which is impossible if the frames are what they appear to be. When
/// a result contradicts the mathematics, the assumption to check is what the
/// data actually contains.
struct FrameDiagnosticsTests {

    @Test(.enabled(if: SampleSession.hasAtLeastThreeFrames()))
    func reportsPerFrameStatistics() throws {
        let frames = SampleSession.frames()
        let decoded = try frames.map {
            try RAWDecoder.decodeLuminance(contentsOf: $0, maxDimension: 512)
        }
        let reference = decoded[0]
        let region = try #require(NoiseMeasurement.backgroundRegion(reference, size: 256))

        print("\n=== PER-FRAME DIAGNOSTICS ===")
        print("measurement region: x\(region.x) y\(region.y) \(region.width)x\(region.height)")

        for (i, image) in decoded.enumerated() {
            let sorted = image.pixels.sorted()
            let sigma = NoiseMeasurement.standardDeviation(image, in: region)
            let offset = FrameAligner.estimateOffset(of: image, against: reference, maxShift: 40)
            print(String(format: "frame %d  median %.6f  sigma(region) %.6f  offset (%d,%d)",
                         i + 1, sorted[sorted.count / 2], sigma, offset.x, offset.y))
        }

        // Difference between consecutive frames. For frames of one static
        // scene this should be pure noise, with sigma about √2 times a single
        // frame's. Much larger means the SCENE changed, not just the sensor.
        print("\n--- consecutive differences ---")
        for i in 1..<decoded.count {
            var diff = [Float](repeating: 0, count: reference.pixels.count)
            for p in 0..<diff.count {
                diff[p] = decoded[i].pixels[p] - decoded[i - 1].pixels[p]
            }
            guard let diffImage = FloatImage(width: reference.width,
                                             height: reference.height, pixels: diff) else { continue }
            let sigma = NoiseMeasurement.standardDeviation(diffImage, in: region)
            let mean = diff.reduce(0, +) / Float(diff.count)
            print(String(format: "frame %d - %d  mean %.6f  sigma(region) %.6f",
                         i + 1, i, mean, sigma))
        }
        // The measurement that can actually see stacking work. Frame 1 is
        // excluded: it is captured before manual exposure settles and comes
        // out at a different brightness, which would corrupt every difference
        // it appears in.
        let settled = Array(decoded.dropFirst())
        print("\n--- temporal noise (frame 1 excluded, exposure not settled) ---")
        if settled.count >= 2,
           let perFrame = TemporalNoise.perFrame(settled[0], settled[1], in: region),
           let stack = TemporalNoise.ofStack(settled, in: region) {
            print(String(format: "per-frame noise   %.6f", perFrame))
            print(String(format: "stack noise       %.6f", stack))
            print(String(format: "improvement       %.2fx", perFrame / stack))
            print(String(format: "ideal sqrt(%d)     %.2fx",
                         settled.count, Double(settled.count).squareRoot()))
        }
        print("=============================\n")

        #expect(decoded.count == frames.count)
    }
}
