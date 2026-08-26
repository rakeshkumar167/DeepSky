import Testing
import Foundation
@testable import DeepSkyProcessing

/// Real DNGs are ~19MB each and are never committed, so these tests skip when
/// no exported session is present. The property that decides whether stacking
/// works — √N noise reduction — is proven hermetically in FrameStackerTests
/// and does not depend on any of this.
func sampleDNGs() -> [URL] {
    let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: downloads, includingPropertiesForKeys: nil) else { return [] }
    for dir in entries where dir.lastPathComponent.contains("-astro-") {
        let frames = dir.appendingPathComponent("frames")
        if let dngs = try? FileManager.default.contentsOfDirectory(
            at: frames, includingPropertiesForKeys: nil) {
            return dngs.filter { $0.pathExtension.lowercased() == "dng" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
    return []
}

@Test func decodesARealProRAWFrame() throws {
    let dngs = sampleDNGs()
    try #require(!dngs.isEmpty, "no exported session found — skipping")

    let image = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 512)
    #expect(image.width > 0 && image.height > 0)
    #expect(image.width <= 512 && image.height <= 512)
    #expect(image.pixels.allSatisfy { $0.isFinite })
    // A real frame is not uniform.
    #expect(Set(image.pixels.map { ($0 * 1000).rounded() }).count > 10)
}

@Test func decodingIsDeterministic() throws {
    let dngs = sampleDNGs()
    try #require(!dngs.isEmpty, "no exported session found — skipping")

    let a = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 256)
    let b = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 256)
    #expect(a.pixels == b.pixels)
}

@Test func framesFromOneSessionShareDimensions() throws {
    let dngs = sampleDNGs()
    try #require(dngs.count >= 2, "need at least two frames — skipping")

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
