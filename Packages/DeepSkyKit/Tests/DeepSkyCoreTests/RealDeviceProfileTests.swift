import Testing
import Foundation
@testable import DeepSkyCore

/// Tests against a capability profile captured from real hardware, not a
/// hand-written fixture.
///
/// Recorded 2026-08-26 from an iPhone 15 Pro (iPhone16,1) on iOS 26.6 by the
/// in-app capability probe. The whole point of committing it is that the
/// exposure model stops resting on inference: these assertions fail if a
/// future OS changes what the hardware reports, which is exactly the signal
/// we would want.
struct RealDeviceProfileTests {

    static func loadProfile(_ name: String) throws -> DeviceCapabilities {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "fixture \(name).json missing from test resources")
        let decoder = JSONDecoder()
        // Must match SessionStore and the probe's encoder.
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceCapabilities.self, from: Data(contentsOf: url))
    }

    static func iPhone15Pro() throws -> DeviceCapabilities {
        try loadProfile("capabilities-iPhone16,1")
    }

    @Test func realProfileDecodesWithTheProductionDateStrategy() throws {
        let caps = try Self.iPhone15Pro()
        #expect(caps.deviceModel == "iPhone16,1")
        #expect(caps.supportsAppleProRAW)
        #expect(caps.lenses.count == 3)
        // A bare-number date would have decoded to a nonsense instant; ISO-8601
        // puts it in 2026. This is the wire contract between probe and parser.
        #expect(caps.probedAt > Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The finding the entire exposure architecture rests on.
    ///
    /// AVFoundation caps a single sensor exposure at exactly 1 second on this
    /// device — every one of the 183 format entries agrees. The requirements
    /// document's 30-second shutter is therefore not achievable as a single
    /// sensor read, and any UI offering it would be lying about physics.
    @Test func everyFormatCapsSensorExposureAtOneSecond() throws {
        let caps = try Self.iPhone15Pro()
        let allFormats = caps.lenses.flatMap(\.formats)
        #expect(allFormats.count == 183)
        #expect(allFormats.allSatisfy { $0.maxExposureSeconds == 1.0 })
    }

    /// The honesty mechanism, checked against real limits rather than invented ones.
    @Test func ladderFromRealHardwareStopsAtOneSecond() throws {
        let caps = try Self.iPhone15Pro()
        let wide = try #require(
            caps.lenses.first { $0.deviceType.contains("WideAngle") },
            "wide-angle lens missing from profile")
        let astroFormat = try #require(
            wide.formats.max { a, b in
                a.maxExposureSeconds != b.maxExposureSeconds
                    ? a.maxExposureSeconds < b.maxExposureSeconds
                    : (a.width * a.height) < (b.width * b.height)
            })

        let ladder = ShutterLadder.ladder(for: astroFormat)

        #expect(ladder.contains { $0.seconds == 1.0 })
        // §4 of the requirements shows a ladder running to 30s. The hardware
        // cannot do it, so it must never appear.
        #expect(!ladder.contains { $0.seconds > 1.0 })
        #expect(ladder.allSatisfy { $0.seconds >= astroFormat.minExposureSeconds })
        #expect(ladder == ladder.sorted())
    }

    /// A 30-second "exposure" is 30 stacked frames on this hardware, and the
    /// four quantities must stay distinct (spec §27).
    @Test func thirtySecondExposureIsThirtyStackedFramesOnRealHardware() throws {
        let caps = try Self.iPhone15Pro()
        let wide = try #require(caps.lenses.first { $0.deviceType.contains("WideAngle") })
        let longest = try #require(wide.formats.map(\.maxExposureSeconds).max())

        let plan = CapturePlan.solve(
            totalCaptureSeconds: 30,
            sensorExposure: ShutterSpeed(seconds: longest),
            intervalSeconds: 0)

        #expect(plan.frameCount == 30)
        #expect(plan.effectiveExposureSeconds == 30.0)
        #expect(plan.sensorExposure.seconds == 1.0)
    }

    /// Field of view varies per format within a single lens, which is why
    /// stability banding reads it per-format rather than per-lens.
    @Test func fieldOfViewVariesWithinALens() throws {
        let caps = try Self.iPhone15Pro()
        for lens in caps.lenses {
            let fovs = Set(lens.formats.map(\.horizontalFieldOfViewDegrees))
            #expect(fovs.count > 1, "\(lens.localizedName) reported a single FOV across all formats")
        }
    }

    /// 48MP is wide-angle only on this device — the ultra-wide and telephoto
    /// top out at 12MP, so a 48MP capture mode cannot be offered globally.
    @Test func fortyEightMegapixelIsWideAngleOnly() throws {
        let caps = try Self.iPhone15Pro()
        for lens in caps.lenses {
            let has48MP = lens.formats.contains { format in
                format.maxPhotoDimensions.contains { $0.count == 2 && $0[0] * $0[1] > 40_000_000 }
            }
            if lens.deviceType.contains("WideAngle") {
                #expect(has48MP, "wide angle should offer a 48MP photo dimension")
            } else {
                #expect(!has48MP, "\(lens.localizedName) unexpectedly offers 48MP")
            }
        }
    }

    /// Apple ProRAW ('l64r') is available on all three lenses; Bayer RAW
    /// differs per sensor. Recorded so a change in either is visible.
    @Test func proRAWIsAvailableOnEveryLens() throws {
        let caps = try Self.iPhone15Pro()
        for lens in caps.lenses {
            let formats = Set(lens.formats.flatMap(\.rawPixelFormats))
            #expect(formats.contains("l64r"), "\(lens.localizedName) missing ProRAW")
        }
    }
}
