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

/// A star field: a handful of Gaussian points on a noisy background, shifted by
/// a known amount. Stars are what alignment actually keys on.
private func starField(size: Int, shiftX: Int, shiftY: Int,
                       sigma: Double = 0.004, seed: UInt64 = 42) -> FloatImage {
    var noise = Noise(seed: seed)
    var pixels = [Float](repeating: 0.05, count: size * size)
    for i in 0..<pixels.count { pixels[i] += Float(noise.gaussian(sigma)) }

    // Fixed star positions, offset by the requested shift.
    let stars: [(Int, Int, Float)] = [
        (30, 40, 0.9), (70, 25, 0.6), (55, 80, 0.75),
        (90, 95, 0.5), (20, 100, 0.65), (110, 60, 0.55),
    ]
    for (sx, sy, amplitude) in stars {
        let cx = sx + shiftX, cy = sy + shiftY
        for dy in -3...3 {
            for dx in -3...3 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < size, y >= 0, y < size else { continue }
                let r2 = Double(dx * dx + dy * dy)
                pixels[y * size + x] += amplitude * Float(exp(-r2 / 2.0))
            }
        }
    }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

struct FrameAlignerTests {

    /// THE test. If a known shift cannot be recovered, nothing downstream works.
    @Test func recoversAKnownShift() {
        let reference = starField(size: 128, shiftX: 0, shiftY: 0)
        for (dx, dy) in [(5, 3), (-7, 4), (12, -9), (0, 0), (-15, -11)] {
            let shifted = starField(size: 128, shiftX: dx, shiftY: dy, seed: 99)
            let offset = FrameAligner.estimateOffset(of: shifted, against: reference,
                                                     maxShift: 24)
            #expect(offset.x == dx && offset.y == dy,
                    "expected (\(dx), \(dy)), got (\(offset.x), \(offset.y))")
        }
    }

    /// Drift of the magnitude the real sessions showed — 19 to 64 pixels.
    @Test func recoversTheDriftSeenInRealSessions() {
        let reference = starField(size: 160, shiftX: 0, shiftY: 0)
        for (dx, dy) in [(19, 0), (-20, 14), (31, -22)] {
            let shifted = starField(size: 160, shiftX: dx, shiftY: dy, seed: 7)
            let offset = FrameAligner.estimateOffset(of: shifted, against: reference,
                                                     maxShift: 40)
            #expect(offset.x == dx && offset.y == dy,
                    "expected (\(dx), \(dy)), got (\(offset.x), \(offset.y))")
        }
    }

    @Test func identicalImagesAlignToZero() {
        let image = starField(size: 96, shiftX: 0, shiftY: 0)
        let offset = FrameAligner.estimateOffset(of: image, against: image, maxShift: 16)
        #expect(offset.x == 0 && offset.y == 0)
    }

    @Test func shiftingAnImageMovesContentByExactlyThatMuch() throws {
        let image = starField(size: 64, shiftX: 0, shiftY: 0)
        let moved = try #require(FrameAligner.shift(image, by: Offset(x: 3, y: -2)))
        // A pixel at (10, 10) in the original lands at (13, 8) in the result.
        #expect(abs(moved[13, 8] - image[10, 10]) < 1e-6)
    }

    /// Pixels shifted in from outside the frame have no data behind them and
    /// must not be invented — they come back as zero and are excluded from the
    /// stack by the coverage mask.
    @Test func shiftedEdgesAreMarkedRatherThanFabricated() throws {
        let image = starField(size: 64, shiftX: 0, shiftY: 0)
        let moved = try #require(FrameAligner.shift(image, by: Offset(x: 5, y: 0)))
        for y in 0..<moved.height {
            for x in 0..<5 { #expect(moved[x, y] == 0) }
        }
    }

    /// The whole point: aligning before stacking must actually reduce noise,
    /// where stacking the same frames unaligned makes it worse.
    @Test func aligningBeforeStackingBeatsNotAligning() throws {
        let size = 160
        let shifts = [(0, 0), (14, -9), (-21, 12), (8, 17), (-16, -6)]

        let frames = shifts.enumerated().map { index, shift in
            starField(size: size, shiftX: shift.0, shiftY: shift.1,
                      sigma: 0.02, seed: UInt64(100 + index))
        }
        let reference = frames[0]
        let region = PatchRegion(x: 60, y: 60, width: 40, height: 40)

        var naive = FrameStacker(width: size, height: size)
        for f in frames { _ = naive.add(f) }
        let naiveResult = try #require(naive.result())

        var aligned = FrameStacker(width: size, height: size)
        for f in frames {
            let offset = FrameAligner.estimateOffset(of: f, against: reference, maxShift: 32)
            let corrected = try #require(FrameAligner.shift(f, by: Offset(x: -offset.x, y: -offset.y)))
            _ = aligned.add(corrected)
        }
        let alignedResult = try #require(aligned.result())

        let sigmaSingle = NoiseMeasurement.standardDeviation(reference, in: region)
        let sigmaNaive = NoiseMeasurement.standardDeviation(naiveResult, in: region)
        let sigmaAligned = NoiseMeasurement.standardDeviation(alignedResult, in: region)

        #expect(sigmaAligned < sigmaNaive,
                "aligned \(sigmaAligned) should beat unaligned \(sigmaNaive)")
        #expect(sigmaAligned < sigmaSingle,
                "aligned \(sigmaAligned) should beat a single frame \(sigmaSingle)")
    }

    @Test func rejectsMismatchedDimensions() {
        let a = starField(size: 64, shiftX: 0, shiftY: 0)
        let b = starField(size: 32, shiftX: 0, shiftY: 0)
        let offset = FrameAligner.estimateOffset(of: b, against: a, maxShift: 8)
        #expect(offset == Offset(x: 0, y: 0))
    }
}
