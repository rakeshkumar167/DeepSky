import Testing
@testable import DeepSkyCore

@Test func packageBuildsAndExposesVersion() {
    #expect(DeepSkyCore.version == "0.1.0")
}
