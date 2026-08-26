import Testing
import Foundation
import DeepSkyCore

@Test func frameFlagIsAClosedSetWithStableRawValues() {
    #expect(FrameFlag.motion.rawValue == "motion")
    #expect(FrameFlag.thermalPause.rawValue == "thermalPause")
    #expect(FrameFlag.sessionInterrupted.rawValue == "sessionInterrupted")
    #expect(FrameFlag.writeRetry.rawValue == "writeRetry")
    #expect(FrameFlag.settingsDrift.rawValue == "settingsDrift")
    #expect(FrameFlag.allCases.count == 5)
}

@Test func frameRecordRoundTripsAsSingleJSONLine() throws {
    let record = FrameRecord(
        index: 1, file: "frames/frame_0001.dng",
        capturedAt: Date(timeIntervalSince1970: 776000000),
        iso: 1600, exposureSeconds: 1.0, lensPosition: 1.0,
        whiteBalanceKelvin: 3900, bytes: 26_214_400,
        thermalState: .nominal,
        stability: StabilityReading(rmsAngularRateRadPerSec: 0.0021,
                                    predictedDriftPixels: 0.41, band: .excellent),
        flags: [], isDark: false)

    let data = try JSONEncoder().encode(record)
    let line = String(data: data, encoding: .utf8)!
    #expect(!line.contains("\n"))

    let decoded = try JSONDecoder().decode(FrameRecord.self, from: data)
    #expect(decoded.index == 1)
    #expect(decoded.stability.band == .excellent)
    #expect(decoded.flags.isEmpty)
}

@Test func decodesUnknownFlagWithoutThrowing() throws {
    // Forward compatibility: a newer writer must not break an older reader.
    let json = """
    {"index":1,"file":"f.dng","capturedAt":776000000,"iso":1600,
     "exposureSeconds":1.0,"lensPosition":1.0,"whiteBalanceKelvin":3900,
     "bytes":100,"thermalState":"nominal",
     "stability":{"rmsAngularRateRadPerSec":0.1,"predictedDriftPixels":2.0,"band":"poor"},
     "flags":["motion","somethingNew"],"isDark":false}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(FrameRecord.self, from: json)
    #expect(decoded.flags == [.motion])
}
