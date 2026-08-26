import Testing
import Foundation
@testable import DeepSkyCore

/// Tests against capability profiles captured from real hardware.
///
/// Recorded 2026-08-26 by the in-app capability probe:
///   - iPhone 15 Pro (iPhone16,1) on iOS 26.6      — 183 formats
///   - iPhone 17 Pro (iPhone18,1) on iOS 26.6.1    — 196 formats
///
/// Two devices is the point. An assumption that holds for one and not the
/// other fails loudly here rather than in a field at 3am, and the split
/// between cross-device invariants and per-device facts below is exactly
/// the line the app must not blur.
struct RealDeviceProfileTests {

    static let profileNames = ["capabilities-iPhone16,1", "capabilities-iPhone18,1"]

    static func loadProfile(_ name: String) throws -> DeviceCapabilities {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "fixture \(name).json missing from test resources")
        let decoder = JSONDecoder()
        // Must match SessionStore and the probe's encoder.
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceCapabilities.self, from: Data(contentsOf: url))
    }

    static func iPhone15Pro() throws -> DeviceCapabilities { try loadProfile(profileNames[0]) }
    static func iPhone17Pro() throws -> DeviceCapabilities { try loadProfile(profileNames[1]) }

    // MARK: - Invariants that must hold on every device

    @Test(arguments: profileNames)
    func realProfileDecodesWithTheProductionDateStrategy(_ name: String) throws {
        let caps = try Self.loadProfile(name)
        #expect(caps.supportsAppleProRAW)
        #expect(caps.lenses.count == 3)
        // A bare-number date would decode to a nonsense instant; ISO-8601 puts
        // it in 2026. This is the wire contract between probe and parser.
        #expect(caps.probedAt > Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The finding the entire exposure architecture rests on.
    ///
    /// AVFoundation caps a single sensor exposure at exactly 1 second — on
    /// both devices, across 379 format entries between them, with no
    /// variation whatsoever. Two generations of sensor and silicon reporting
    /// the identical value is strong evidence this is a platform limit rather
    /// than a device characteristic. The requirements document's 30-second
    /// shutter is therefore not achievable as a single sensor read on any of
    /// this hardware, and a UI offering it would be lying about physics.
    @Test(arguments: profileNames)
    func everyFormatCapsSensorExposureAtOneSecond(_ name: String) throws {
        let caps = try Self.loadProfile(name)
        let allFormats = caps.lenses.flatMap(\.formats)
        #expect(!allFormats.isEmpty)
        #expect(allFormats.allSatisfy { $0.maxExposureSeconds == 1.0 })
    }

    /// The honesty mechanism, checked against real limits rather than invented ones.
    @Test(arguments: profileNames)
    func ladderFromRealHardwareStopsAtOneSecond(_ name: String) throws {
        let caps = try Self.loadProfile(name)
        for lens in caps.lenses {
            let astroFormat = try #require(
                lens.formats.max { a, b in
                    a.maxExposureSeconds != b.maxExposureSeconds
                        ? a.maxExposureSeconds < b.maxExposureSeconds
                        : (a.width * a.height) < (b.width * b.height)
                })
            let ladder = ShutterLadder.ladder(for: astroFormat)

            #expect(ladder.contains { $0.seconds == 1.0 })
            // §4 shows a ladder running to 30s. The hardware cannot do it, so
            // it must never appear.
            #expect(!ladder.contains { $0.seconds > 1.0 }, "\(name) \(lens.localizedName)")
            #expect(ladder.allSatisfy { $0.seconds >= astroFormat.minExposureSeconds })
            #expect(ladder == ladder.sorted())
        }
    }

    /// A 30-second "exposure" is 30 stacked frames on this hardware, and the
    /// four quantities must stay distinct (spec §27).
    @Test(arguments: profileNames)
    func thirtySecondExposureIsThirtyStackedFrames(_ name: String) throws {
        let caps = try Self.loadProfile(name)
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

    /// Field of view varies per format WITHIN a single lens on both devices,
    /// which is why stability banding reads FOV per-format rather than
    /// per-lens. A per-lens constant would mis-band drift by up to ~15%.
    @Test(arguments: profileNames)
    func fieldOfViewVariesWithinALens(_ name: String) throws {
        let caps = try Self.loadProfile(name)
        for lens in caps.lenses {
            let fovs = Set(lens.formats.map(\.horizontalFieldOfViewDegrees))
            #expect(fovs.count > 1, "\(name) \(lens.localizedName) reported a single FOV")
        }
    }

    /// Apple ProRAW ('l64r') is available on every lens of both devices.
    /// Bayer RAW differs per sensor, so a demosaic path cannot assume one
    /// pattern: 'bgg4' on the wide, 'rgg4' on ultra-wide and telephoto.
    @Test(arguments: profileNames)
    func proRAWIsAvailableOnEveryLens(_ name: String) throws {
        let caps = try Self.loadProfile(name)
        for lens in caps.lenses {
            let formats = Set(lens.formats.flatMap(\.rawPixelFormats))
            #expect(formats.contains("l64r"), "\(name) \(lens.localizedName) missing ProRAW")
        }
    }

    // MARK: - Facts that differ BETWEEN devices
    //
    // These are why device adaptation is not optional. Each assertion below is
    // true of one device and false of the other.

    /// On the 15 Pro only the wide angle offers a 48MP photo dimension; the
    /// ultra-wide and telephoto top out at 12MP.
    @Test func fortyEightMegapixelIsWideAngleOnlyOn15Pro() throws {
        let caps = try Self.iPhone15Pro()
        for lens in caps.lenses {
            let has48MP = Self.offers48MP(lens)
            if lens.deviceType.contains("WideAngle") {
                #expect(has48MP, "15 Pro wide angle should offer 48MP")
            } else {
                #expect(!has48MP, "15 Pro \(lens.localizedName) unexpectedly offers 48MP")
            }
        }
    }

    /// On the 17 Pro all three lenses offer 48MP. A capture UI that assumed
    /// the 15 Pro's wide-only rule would silently withhold two thirds of this
    /// device's resolution.
    @Test func fortyEightMegapixelIsAvailableOnEveryLensOn17Pro() throws {
        let caps = try Self.iPhone17Pro()
        for lens in caps.lenses {
            #expect(Self.offers48MP(lens), "17 Pro \(lens.localizedName) should offer 48MP")
        }
    }

    /// The 17 Pro's telephoto is both longer and dramatically more sensitive:
    /// a narrower field of view and far more ISO headroom, which changes both
    /// framing and which lens is viable for faint targets.
    @Test func telephotoDiffersSharplyBetweenDevices() throws {
        let older = try #require(try Self.iPhone15Pro().lenses.first { $0.deviceType.contains("Telephoto") })
        let newer = try #require(try Self.iPhone17Pro().lenses.first { $0.deviceType.contains("Telephoto") })

        let olderFOV = try #require(older.formats.map(\.horizontalFieldOfViewDegrees).min())
        let newerFOV = try #require(newer.formats.map(\.horizontalFieldOfViewDegrees).min())
        #expect(newerFOV < olderFOV, "17 Pro telephoto should be narrower")

        let olderISO = try #require(older.formats.map(\.maxISO).max())
        let newerISO = try #require(newer.formats.map(\.maxISO).max())
        #expect(newerISO > olderISO * 3, "17 Pro telephoto should have far more ISO headroom")
    }

    static func offers48MP(_ lens: LensCapability) -> Bool {
        lens.formats.contains { format in
            format.maxPhotoDimensions.contains { $0.count == 2 && $0[0] * $0[1] > 40_000_000 }
        }
    }
}
