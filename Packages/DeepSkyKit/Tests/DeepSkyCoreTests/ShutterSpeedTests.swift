import Foundation
import Testing
import DeepSkyCore

@Test func formatsSubSecondAsReciprocal() {
    #expect(ShutterSpeed(seconds: 1.0 / 250.0).displayLabel == "1/250")
    #expect(ShutterSpeed(seconds: 0.5).displayLabel == "1/2")
    #expect(ShutterSpeed(seconds: 1.0 / 8000.0).displayLabel == "1/8000")
}

@Test func formatsWholeSecondsWithDecimal() {
    #expect(ShutterSpeed(seconds: 1.0).displayLabel == "1.0s")
    #expect(ShutterSpeed(seconds: 2.0).displayLabel == "2.0s")
    #expect(ShutterSpeed(seconds: 30.0).displayLabel == "30.0s")
}

@Test func ordersByDuration() {
    #expect(ShutterSpeed(seconds: 0.5) < ShutterSpeed(seconds: 1.0))
}

@Test func roundTripsThroughJSON() throws {
    let original = ShutterSpeed(seconds: 1.0 / 250.0)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ShutterSpeed.self, from: data)
    #expect(decoded == original)
}

@Test func handlesZeroSecondsGracefully() {
    #expect(ShutterSpeed(seconds: 0.0).displayLabel == "N/A")
}

@Test func handlesNegativeSecondsGracefully() {
    #expect(ShutterSpeed(seconds: -1.0).displayLabel == "N/A")
}

@Test func handlesNonFiniteSecondsGracefully() {
    #expect(ShutterSpeed(seconds: Double.nan).displayLabel == "N/A")
    #expect(ShutterSpeed(seconds: Double.infinity).displayLabel == "N/A")
}

@Test func handlesExtremelyTinyPositiveSecondsWithoutTrapping() {
    // Below ~1.08e-19 the reciprocal exceeds Int.max and `Int(reciprocal)`
    // traps. ShutterLadder can feed a probe-supplied minExposureSeconds
    // straight into this, so it must degrade gracefully instead.
    #expect(ShutterSpeed(seconds: 1e-30).displayLabel == "N/A")
    #expect(ShutterSpeed(seconds: .leastNonzeroMagnitude).displayLabel == "N/A")
}
