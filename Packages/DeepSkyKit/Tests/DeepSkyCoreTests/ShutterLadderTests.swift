import Testing
import DeepSkyCore

private func format(min: Double, max: Double) -> FormatCapability {
    FormatCapability(width: 4032, height: 3024,
                     minExposureSeconds: min, maxExposureSeconds: max,
                     minISO: 55, maxISO: 12288,
                     horizontalFieldOfViewDegrees: 68,
                     maxPhotoDimensions: [[4032, 3024]],
                     rawPixelFormats: ["bgg4"])
}

@Test func neverOffersLongerThanHardwareAllows() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.000015, max: 1.0))
    #expect(ladder.allSatisfy { $0.seconds <= 1.0 })
    #expect(ladder.contains { $0.seconds == 1.0 })
    #expect(!ladder.contains { $0.seconds == 30.0 })
}

@Test func neverOffersShorterThanHardwareAllows() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.001, max: 1.0))
    #expect(ladder.allSatisfy { $0.seconds >= 0.001 })
}

@Test func includesHardwareEndpointsExactly() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.002, max: 0.7))
    #expect(ladder.first?.seconds == 0.002)
    #expect(ladder.last?.seconds == 0.7)
}

@Test func isSortedAscendingAndDeduplicated() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.000015, max: 1.0))
    #expect(ladder == ladder.sorted())
    #expect(Set(ladder).count == ladder.count)
}

@Test func extendsToThirtySecondsWhenHardwareAllows() {
    // If a future device reports a 30s ceiling, §4's full ladder appears.
    let ladder = ShutterLadder.ladder(for: format(min: 0.000015, max: 30.0))
    #expect(ladder.contains { $0.seconds == 30.0 })
    #expect(ladder.contains { $0.seconds == 15.0 })
}

@Test func handlesDegenerateRangeWithoutCrashing() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.5, max: 0.5))
    #expect(ladder.count == 1)
    #expect(ladder[0].seconds == 0.5)
}
