import Testing
import DeepSkyCore
import DeepSkyMetrics

private func wideFormat() -> FormatCapability {
    // 4032 px across a 68° horizontal field ≈ 3396 px per radian.
    FormatCapability(width: 4032, height: 3024,
                     minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                     minISO: 55, maxISO: 12288,
                     horizontalFieldOfViewDegrees: 68,
                     maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
}

@Test func perfectlyStillIsExcellent() {
    let r = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0,
                                       exposureSeconds: 1.0, format: wideFormat())
    #expect(r.predictedDriftPixels == 0.0)
    #expect(r.band == .excellent)
}

@Test func driftScalesWithExposureTime() {
    let short = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0001,
                                           exposureSeconds: 1.0, format: wideFormat())
    let long = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0001,
                                          exposureSeconds: 4.0, format: wideFormat())
    #expect(abs(long.predictedDriftPixels - short.predictedDriftPixels * 4.0) < 0.0001)
}

@Test func bandsAtHalfAndOnePointFivePixels() {
    let f = wideFormat()
    // pixelsPerRadian ≈ 4032 / (68° in radians) ≈ 3396.4
    let ppr = Double(f.width) / (Double(f.horizontalFieldOfViewDegrees) * .pi / 180.0)

    let justUnderHalf = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 0.4 / ppr, exposureSeconds: 1.0, format: f)
    #expect(justUnderHalf.band == .excellent)

    let onePixel = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 1.0 / ppr, exposureSeconds: 1.0, format: f)
    #expect(onePixel.band == .good)

    let twoPixels = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 2.0 / ppr, exposureSeconds: 1.0, format: f)
    #expect(twoPixels.band == .poor)
}

@Test func narrowerFieldOfViewIsLessForgiving() {
    // Same shake, longer lens: a telephoto magnifies angular error.
    let wide = wideFormat()
    let tele = FormatCapability(width: 4032, height: 3024,
                                minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                                minISO: 55, maxISO: 12288,
                                horizontalFieldOfViewDegrees: 20,
                                maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
    let w = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0002,
                                       exposureSeconds: 1.0, format: wide)
    let t = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0002,
                                       exposureSeconds: 1.0, format: tele)
    #expect(t.predictedDriftPixels > w.predictedDriftPixels)
}

@Test func guardsAgainstZeroFieldOfView() {
    let broken = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.1, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: 0,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: [])
    let r = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.01,
                                       exposureSeconds: 1.0, format: broken)
    #expect(r.predictedDriftPixels.isFinite)
    #expect(r.band == .poor)
}

@Test func negativeFOVIsPoor() {
    let broken = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.1, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: -20,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: [])
    let r = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.01,
                                       exposureSeconds: 1.0, format: broken)
    #expect(r.predictedDriftPixels.isFinite)
    #expect(r.band == .poor)
}

@Test func exactBoundaryAtHalfPixelIsGood() {
    let f = wideFormat()
    let ppr = Double(f.width) / (Double(f.horizontalFieldOfViewDegrees) * .pi / 180.0)

    let exactHalf = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 0.5 / ppr, exposureSeconds: 1.0, format: f)
    #expect(exactHalf.band == .good)
}

@Test func exactBoundaryAtOnePointFivePixelsIsPoor() {
    let f = wideFormat()
    let ppr = Double(f.width) / (Double(f.horizontalFieldOfViewDegrees) * .pi / 180.0)

    let exactOnePointFive = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 1.5 / ppr, exposureSeconds: 1.0, format: f)
    #expect(exactOnePointFive.band == .poor)
}
