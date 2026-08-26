import Testing
import Foundation
@testable import DeepSkyProcessing

@Test(.enabled(if: SampleSession.exists()))
func skipsFramesItCannotDecodeRatherThanFailing() throws {
    let frames = SampleSession.frames()
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("broken-\(UUID().uuidString).dng")
    try Data("nonsense".utf8).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    let result = try StackPipeline.run(frameURLs: [frames[0], bogus, frames[1]],
                                       maxDimension: 256, progress: nil)
    #expect(result.framesUsed == 2)
    #expect(result.framesFailed == 1)
}

@Test func failsWhenNoFrameDecodes() throws {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("broken-\(UUID().uuidString).dng")
    try Data("nonsense".utf8).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    #expect(throws: (any Error).self) {
        try StackPipeline.run(frameURLs: [bogus], maxDimension: 128, progress: nil)
    }
}

@Test(.enabled(if: SampleSession.exists()))
func reportsProgressForEveryFrame() throws {
    final class Counter: @unchecked Sendable { var seen: [Int] = [] }
    let counter = Counter()
    let subset = Array(SampleSession.frames().prefix(3))
    _ = try StackPipeline.run(frameURLs: subset, maxDimension: 128) { done, _ in
        counter.seen.append(done)
    }
    #expect(counter.seen.count == subset.count)
}

/// Always-on measurement against whatever session is present. Asserts only
/// that the pipeline produces a result — the number is the point, and it is
/// printed so a run against a new session reports its own figure.
@Test(.enabled(if: SampleSession.hasAtLeastThreeFrames()))
func reportsStackingMeasurementOnRealFrames() throws {
    let frames = SampleSession.frames()
    let result = try StackPipeline.run(frameURLs: frames, maxDimension: 512, progress: nil)
    let flagged = SampleSession.motionFlaggedFraction() ?? 1

    print("""

    === REAL DATA: stacking measurement ===
    frames used         \(result.framesUsed)
    frames failed       \(result.framesFailed)
    flagged for motion  \(Int(flagged * 100))%
    sigma single        \(result.noiseSingle)
    sigma stacked       \(result.noiseStacked)
    improvement         \(result.improvementFactor)x
    ideal sqrt(N)       \(result.expectedImprovement)x
    =======================================

    """)

    #expect(result.framesUsed > 0)
}

/// THE real-data check, gated on a session that can actually validate it.
///
/// This measures *spatial* σ over a patch, which only means "noise" when the
/// patch is flat sky and the frames are aligned. There is no alignment stage
/// by design (the frame ceiling keeps integration under the trailing
/// threshold instead), so a session whose frames moved smears scene structure
/// into the patch and σ rises.
///
/// Gating on the session's own recorded stability is not weakening the
/// assertion — asserting against data known to violate the premise would be.
/// The ideal √N is reported rather than asserted, since even a tripod session
/// carries residual drift.
@Test(.enabled(if: SampleSession.isStableEnoughForUnalignedStacking()))
func stackingRealFramesReducesNoise() throws {
    let frames = SampleSession.frames()
    let result = try StackPipeline.run(frameURLs: frames, maxDimension: 512, progress: nil)

    #expect(result.noiseStacked < result.noiseSingle,
            "stacking must reduce noise; got \(result.noiseStacked) vs \(result.noiseSingle)")
    #expect(result.improvementFactor > 1.2,
            "expected a clear improvement, got \(result.improvementFactor)x")
}
