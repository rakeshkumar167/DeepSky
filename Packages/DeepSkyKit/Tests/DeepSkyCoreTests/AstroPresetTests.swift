import Testing
import Foundation
@testable import DeepSkyCore

/// Every assertion here runs against capability profiles captured from real
/// hardware, so the preset is validated against what the devices actually
/// report rather than against what seemed reasonable when writing it.
struct AstroPresetTests {
    static func load(_ name: String) throws -> DeviceCapabilities {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(DeviceCapabilities.self, from: Data(contentsOf: url))
    }
    static func pro15() throws -> DeviceCapabilities { try load("capabilities-iPhone16,1") }
    static func pro17() throws -> DeviceCapabilities { try load("capabilities-iPhone18,1") }

    /// The wide is the light bucket on both devices — 12320/12096 max ISO
    /// against 3072 and 2304. The preset must DERIVE that, not assume it.
    @Test func picksTheLensWithTheMostISOHeadroom() throws {
        for caps in [try Self.pro15(), try Self.pro17()] {
            let index = try #require(AstroPreset.recommendedLensIndex(caps))
            #expect(caps.lenses[index].deviceType.contains("WideAngle"))
        }
    }

    @Test func shutterIsAlwaysTheReportedCeiling() throws {
        for caps in [try Self.pro15(), try Self.pro17()] {
            let index = try #require(AstroPreset.recommendedLensIndex(caps))
            let format = try #require(AstroPreset.astroFormat(for: caps.lenses[index]))
            let settings = try #require(AstroPreset.settings(
                capabilities: caps, lensIndex: index,
                light: LightReading(iso: 800, exposureSeconds: 0.5)))
            #expect(settings.exposure.seconds == format.maxExposureSeconds)
            #expect(settings.exposure.seconds == 1.0)   // what both devices report
        }
    }

    /// A dark sky pins auto-exposure at its limits, which must scale to the
    /// ISO ceiling rather than something timid.
    @Test func darkSkyMeteringReachesTheISOCeiling() throws {
        let caps = try Self.pro15()
        let index = try #require(AstroPreset.recommendedLensIndex(caps))
        let settings = try #require(AstroPreset.settings(
            capabilities: caps, lensIndex: index,
            light: LightReading(iso: 12000, exposureSeconds: 1.0)))
        #expect(settings.iso == AstroPreset.isoCeiling)
    }

    /// A bright scene must not be pushed to the ceiling.
    @Test func brightSceneMeteringStaysLow() throws {
        let caps = try Self.pro15()
        let index = try #require(AstroPreset.recommendedLensIndex(caps))
        let format = try #require(AstroPreset.astroFormat(for: caps.lenses[index]))
        let settings = try #require(AstroPreset.settings(
            capabilities: caps, lensIndex: index,
            light: LightReading(iso: 100, exposureSeconds: 0.002)))
        #expect(settings.iso < 100)
        #expect(settings.iso >= format.minISO)
    }

    @Test func isoNeverExceedsTheFormatOrTheCeiling() throws {
        for caps in [try Self.pro15(), try Self.pro17()] {
            let index = try #require(AstroPreset.recommendedLensIndex(caps))
            let format = try #require(AstroPreset.astroFormat(for: caps.lenses[index]))
            let settings = try #require(AstroPreset.settings(
                capabilities: caps, lensIndex: index,
                light: LightReading(iso: 999_999, exposureSeconds: 10)))
            #expect(settings.iso <= format.maxISO)
            #expect(settings.iso <= AstroPreset.isoCeiling)
        }
    }

    /// Frame ceiling comes from each lens's own focal length via the 500-rule,
    /// so the app structurally cannot stack into visible trailing.
    @Test func frameCeilingDerivesFromFocalLength() throws {
        let caps = try Self.pro15()
        let wide = try #require(caps.lenses.first { $0.deviceType.contains("WideAngle") })
        let ultra = try #require(caps.lenses.first { $0.deviceType.contains("UltraWide") })
        let tele = try #require(caps.lenses.first { $0.deviceType.contains("Telephoto") })

        #expect(AstroPreset.maxFrames(for: wide) == 19)     // 500 / 26
        #expect(AstroPreset.maxFrames(for: ultra) == 33)    // 500 / 15
        #expect(AstroPreset.maxFrames(for: tele) == 5)      // 500 / 84
    }

    /// The 17 Pro's longer telephoto must allow fewer frames than the 15 Pro's.
    @Test func longerLensAllowsFewerFrames() throws {
        let older = try #require(try Self.pro15().lenses.first { $0.deviceType.contains("Telephoto") })
        let newer = try #require(try Self.pro17().lenses.first { $0.deviceType.contains("Telephoto") })
        #expect(AstroPreset.maxFrames(for: newer) < AstroPreset.maxFrames(for: older))
    }

    @Test func alwaysAllowsAtLeastOneFrame() {
        let absurd = LensCapability(deviceType: "t", localizedName: "n",
                                    focalLengthEquivalent: 100_000, formats: [])
        #expect(AstroPreset.maxFrames(for: absurd) >= 1)
    }

    /// A lens reporting no focal length must fall back conservatively, never
    /// to something that would allow trailing.
    @Test func missingFocalLengthFallsBackConservatively() {
        let unknown = LensCapability(deviceType: "t", localizedName: "n",
                                     focalLengthEquivalent: nil, formats: [])
        #expect(AstroPreset.maxFrames(for: unknown) == 20)   // 500 / 24 fallback
    }

    @Test func returnsNilForAnInvalidLensIndex() throws {
        let caps = try Self.pro15()
        #expect(AstroPreset.settings(capabilities: caps, lensIndex: -1,
                                     light: LightReading(iso: 800, exposureSeconds: 1)) == nil)
        #expect(AstroPreset.settings(capabilities: caps, lensIndex: 99,
                                     light: LightReading(iso: 800, exposureSeconds: 1)) == nil)
    }

    /// Degenerate metering must not produce NaN ISO or crash.
    @Test func degenerateMeteringIsClamped() throws {
        let caps = try Self.pro15()
        let index = try #require(AstroPreset.recommendedLensIndex(caps))
        for reading in [LightReading(iso: .nan, exposureSeconds: 1),
                        LightReading(iso: 800, exposureSeconds: .infinity),
                        LightReading(iso: -100, exposureSeconds: -1)] {
            let settings = try #require(AstroPreset.settings(
                capabilities: caps, lensIndex: index, light: reading))
            #expect(settings.iso.isFinite)
            #expect(settings.iso >= 0)
        }
    }
}
