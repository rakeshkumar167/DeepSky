import Foundation

/// The result carries its own measurement, not just an image.
///
/// That is deliberate: "the stack looks cleaner" is unfalsifiable, and a
/// pipeline whose decode quietly applies a tone curve produces a
/// better-looking image while gathering no extra signal. The numbers are how
/// the difference is told.
public struct StackResult: Sendable {
    public let stacked: FloatImage
    public let singleFrame: FloatImage
    public let framesUsed: Int
    public let framesFailed: Int
    /// Spatial σ over a patch. Retained for diagnostics only — it is dominated
    /// by scene structure (about 92% on a real session), so it cannot see
    /// stacking work. Never present it as the result.
    public let noiseSingle: Double
    public let noiseStacked: Double

    /// Noise measured from differences between frames, which cancels scene
    /// structure. This is the honest measurement and the one to show.
    public let temporalNoiseSingle: Double?
    public let temporalNoiseStacked: Double?

    /// How much noise actually fell, by the temporal measurement.
    public var temporalImprovement: Double? {
        guard let single = temporalNoiseSingle, let stacked = temporalNoiseStacked,
              stacked > 0 else { return nil }
        return single / stacked
    }
    /// Per-frame translation removed before stacking, in pixels at the
    /// processing resolution. Empty when alignment was disabled.
    public let offsets: [Offset]

    /// Largest drift corrected. Worth surfacing: it is the difference between
    /// a session that stacks and one that smears.
    public var maxDriftPixels: Int {
        offsets.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
    }

    /// How much noise actually fell.
    public var improvementFactor: Double {
        noiseStacked > 0 ? noiseSingle / noiseStacked : 0
    }

    /// What perfect stacking of linear data would give.
    public var expectedImprovement: Double { Double(framesUsed).squareRoot() }
}

public enum StackPipeline {
    public enum PipelineError: Error, Sendable, Equatable {
        case noFramesDecoded
        case noBackgroundRegion
    }

    /// Region size for the noise measurement, per spec §6.
    static let measurementPatch = 256

    /// How far a frame may have drifted and still be corrected, as a fraction
    /// of the processing width. Real sessions showed 19–64px at full
    /// resolution; 8% leaves generous margin without making the search slow.
    static let maxShiftFraction = 0.08

    /// Decodes each frame, aligns it to the first, accumulates it, and discards
    /// it — memory stays flat regardless of frame count. A frame that fails to
    /// decode is skipped and counted, never fatal: one bad DNG must not lose a
    /// session.
    ///
    /// Alignment is on by default because it is not optional in practice: a
    /// deliberately braced phone still drifts tens of pixels per frame, and
    /// stacking that unaligned makes noise worse rather than better.
    public static func run(
        frameURLs: [URL],
        maxDimension: Int,
        align: Bool = true,
        progress: (@Sendable (Int, Int) -> Void)?
    ) throws -> StackResult {
        var stacker: FrameStacker?
        var reference: FloatImage?
        var failed = 0
        var offsets: [Offset] = []

        // Half-stacks for the temporal measurement, accumulated as frames
        // arrive. Retaining every aligned frame instead would grow with the
        // session — 3MB per frame at this resolution — and defeat the whole
        // point of streaming accumulation.
        var evenHalf: FrameStacker?
        var oddHalf: FrameStacker?
        /// The first two aligned frames, the only ones the per-frame
        /// measurement needs to difference.
        var firstPair: [FloatImage] = []
        var accepted = 0

        for (i, url) in frameURLs.enumerated() {
            // Stacking a long session takes real time; a user who leaves the
            // screen must not leave it running.
            try Task.checkCancellation()
            defer { progress?(i + 1, frameURLs.count) }
            guard let decoded = try? RAWDecoder.decodeLuminance(
                    contentsOf: url, maxDimension: maxDimension) else {
                failed += 1
                continue
            }
            if stacker == nil {
                stacker = FrameStacker(width: decoded.width, height: decoded.height)
                evenHalf = FrameStacker(width: decoded.width, height: decoded.height)
                oddHalf = FrameStacker(width: decoded.width, height: decoded.height)
                reference = decoded
            }
            guard let reference else { failed += 1; continue }

            var frame = decoded
            if align, decoded.width == reference.width, decoded.height == reference.height {
                let maxShift = max(Int(Double(reference.width) * maxShiftFraction), 1)
                let drift = FrameAligner.estimateOffset(of: decoded, against: reference,
                                                        maxShift: maxShift)
                offsets.append(drift)
                if drift.x != 0 || drift.y != 0,
                   let corrected = FrameAligner.shift(decoded,
                                                      by: Offset(x: -drift.x, y: -drift.y)) {
                    frame = corrected
                }
            }

            if stacker?.add(frame) == false {
                failed += 1
            } else {
                if accepted % 2 == 0 { evenHalf?.add(frame) } else { oddHalf?.add(frame) }
                if firstPair.count < 2 { firstPair.append(frame) }
                accepted += 1
            }
        }

        guard let stacker, let reference, let stacked = stacker.result() else {
            throw PipelineError.noFramesDecoded
        }

        // Measure both images over the SAME region. Comparing different
        // regions would measure scene variation rather than noise.
        let patch = min(measurementPatch, min(stacked.width, stacked.height))
        guard let region = NoiseMeasurement.backgroundRegion(stacked, size: patch) else {
            throw PipelineError.noBackgroundRegion
        }

        // Both halves must hold at least one frame, or their difference is not
        // a comparison of two independent stacks of the same scene.
        let halfStackNoise: Double? = {
            guard let even = evenHalf?.result(), let odd = oddHalf?.result(),
                  (evenHalf?.frameCount ?? 0) > 0, (oddHalf?.frameCount ?? 0) > 0 else {
                return nil
            }
            return TemporalNoise.ofHalves(even, odd, in: region)
        }()

        return StackResult(
            stacked: stacked,
            singleFrame: reference,
            framesUsed: stacker.frameCount,
            framesFailed: failed,
            noiseSingle: NoiseMeasurement.standardDeviation(reference, in: region),
            noiseStacked: NoiseMeasurement.standardDeviation(stacked, in: region),
            temporalNoiseSingle: firstPair.count >= 2
                ? TemporalNoise.perFrame(firstPair[0], firstPair[1], in: region)
                : nil,
            temporalNoiseStacked: halfStackNoise,
            offsets: offsets)
    }
}
