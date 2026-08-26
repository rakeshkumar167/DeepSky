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
    await #expect(throws: CaptureError.exposureOutOfRange(requested: 30.0, max: 1.0)) {
        try await driver.apply(bad)
    }
}

@Test func rejectsCaptureBeforeSettingsApplied() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    await #expect(throws: CaptureError.settingsNotApplied) {
        _ = try await driver.captureFrame(index: 1)
    }
}

@Test func exposureIsCheckedBeforeISOWhenBothAreInvalid() async throws {
    // Format's max exposure is 1.0s and max ISO is 12288; violate both
    // and confirm the exposure error wins, because `apply` is required
    // to check exposure before ISO. If the checks were ever reordered,
    // this test — not just the happy-path ordering comment — would fail.
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    var bad = settings()
    bad.exposure = ShutterSpeed(seconds: 30.0)   // exceeds max 1.0s
    bad.iso = 99999                              // also exceeds max ISO 12288
    await #expect(throws: CaptureError.exposureOutOfRange(requested: 30.0, max: 1.0)) {
        try await driver.apply(bad)
    }
}

@Test func adjacentSeedsProduceNoOverlappingFramesAcrossIndices() async throws {
    // Regression test for the seed/index mixing collision: a naive
    // `seed + index` combination makes driver seed 10's frame 1 equal
    // driver seed 11's frame 0, and so on diagonally across indices.
    // Capture several frames from each of two adjacent-seed drivers and
    // confirm no frame from one ever equals any frame from the other —
    // index-by-index comparison alone would miss the diagonal collision.
    let a = SyntheticDriver(capabilities: testCapabilities(), seed: 10)
    let b = SyntheticDriver(capabilities: testCapabilities(), seed: 11)
    try await a.apply(settings())
    try await b.apply(settings())

    var framesA: [Data] = []
    var framesB: [Data] = []
    for index in 1...5 {
        framesA.append(try await a.captureFrame(index: index).rawData)
        framesB.append(try await b.captureFrame(index: index).rawData)
    }

    for frameA in framesA {
        for frameB in framesB {
            #expect(frameA != frameB)
        }
    }
}
