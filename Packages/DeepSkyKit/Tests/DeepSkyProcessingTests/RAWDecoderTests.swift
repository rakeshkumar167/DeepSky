import Testing
import Foundation
@testable import DeepSkyProcessing

/// Real DNGs are ~19MB each and are never committed, so these tests are gated
/// on a trait. `#require` FAILS rather than skips in Swift Testing, so gating
/// in the body would turn "no session present" into a red suite.

@Test(.enabled(if: SampleSession.exists()))
func decodesARealProRAWFrame() throws {
    let image = try RAWDecoder.decodeLuminance(
        contentsOf: SampleSession.frames()[0], maxDimension: 512)
    #expect(image.width > 0 && image.height > 0)
    #expect(image.width <= 512 && image.height <= 512)
    #expect(image.pixels.allSatisfy { $0.isFinite })
    // A real frame is not uniform.
    #expect(Set(image.pixels.map { ($0 * 1000).rounded() }).count > 10)
}

@Test(.enabled(if: SampleSession.exists()))
func decodingIsDeterministic() throws {
    let url = SampleSession.frames()[0]
    let a = try RAWDecoder.decodeLuminance(contentsOf: url, maxDimension: 256)
    let b = try RAWDecoder.decodeLuminance(contentsOf: url, maxDimension: 256)
    #expect(a.pixels == b.pixels)
}

@Test(.enabled(if: SampleSession.exists()))
func framesFromOneSessionShareDimensions() throws {
    let dngs = SampleSession.frames()
    let first = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 256)
    for url in dngs.dropFirst() {
        let next = try RAWDecoder.decodeLuminance(contentsOf: url, maxDimension: 256)
        #expect(next.width == first.width && next.height == first.height)
    }
}

@Test func throwsOnAFileThatIsNotRAW() throws {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-a-raw-\(UUID().uuidString).dng")
    try Data("hello".utf8).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    #expect(throws: (any Error).self) {
        try RAWDecoder.decodeLuminance(contentsOf: bogus, maxDimension: 128)
    }
}
