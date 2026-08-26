import Testing
import Foundation
import DeepSkyCore
import DeepSkyCapture
import DeepSkySynthetic

private func testCapabilities() -> DeviceCapabilities {
    let format = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: 68,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
    return DeviceCapabilities(deviceModel: "Synthetic", osVersion: "26.3",
                              supportsAppleProRAW: true,
                              lenses: [LensCapability(deviceType: "wide", localizedName: "Wide",
                                                      focalLengthEquivalent: 24, formats: [format])],
                              probedAt: Date(timeIntervalSince1970: 776000000))
}

private func settings() -> CaptureSettings {
    CaptureSettings(lensIndex: 0, iso: 1600, exposure: ShutterSpeed(seconds: 1.0),
                    lensPosition: 1.0, whiteBalanceKelvin: 3900, exposureBias: 0)
}

@Test func producesFrameDataOnCapture() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    try await driver.apply(settings())
    let frame = try await driver.captureFrame(index: 1)
    #expect(frame.index == 1)
    #expect(frame.bytes > 0)
    #expect(frame.rawData.count == frame.bytes)
}

@Test func isDeterministicForAGivenSeed() async throws {
    let a = SyntheticDriver(capabilities: testCapabilities(), seed: 7)
    let b = SyntheticDriver(capabilities: testCapabilities(), seed: 7)
    try await a.apply(settings())
    try await b.apply(settings())
    let fa = try await a.captureFrame(index: 1)
    let fb = try await b.captureFrame(index: 1)
    #expect(fa.rawData == fb.rawData)
}

@Test func differentSeedsProduceDifferentFrames() async throws {
    let a = SyntheticDriver(capabilities: testCapabilities(), seed: 1)
    let b = SyntheticDriver(capabilities: testCapabilities(), seed: 2)
    try await a.apply(settings())
    try await b.apply(settings())
    let fa = try await a.captureFrame(index: 1)
    let fb = try await b.captureFrame(index: 1)
    #expect(fa.rawData != fb.rawData)
}

@Test func recordsAppliedSettings() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    try await driver.apply(settings())
    let frame = try await driver.captureFrame(index: 1)
    #expect(frame.appliedSettings.iso == 1600)
    #expect(await driver.appliedSettingsHistory.count == 1)
}

@Test func rejectsExposureBeyondHardwareLimit() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    var bad = settings()
    bad.exposure = ShutterSpeed(seconds: 30.0)   // hardware max is 1.0s
    await #expect(throws: CaptureError.self) {
        try await driver.apply(bad)
    }
}

@Test func rejectsCaptureBeforeSettingsApplied() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    await #expect(throws: CaptureError.self) {
        _ = try await driver.captureFrame(index: 1)
    }
}
