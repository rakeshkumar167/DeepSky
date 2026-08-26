import Testing
import Foundation
@testable import DeepSkyCore

/// Regression tests for a bug found by capturing real frames, not by any
/// synthetic fixture.
///
/// `CaptureCoordinator` and `AVCaptureDriver` both read `formats.first` to
/// learn the sensor's pixel scale and its ISO limits. On a real iPhone the
/// first entry is a 192×144 preview format, which caused two silent failures:
///
///  1. Stability drift understated ~20×, so a smeared frame grades `.excellent`.
///  2. A legitimate high-ISO request rejected as out of range, which kills a
///     session under exactly the dark skies this app exists for.
///
/// Neither was reachable from the earlier tests because they all constructed a
/// lens holding a single format.
struct CaptureFormatSelectionTests {
    static func load(_ name: String) throws -> DeviceCapabilities {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(DeviceCapabilities.self, from: Data(contentsOf: url))
    }

    /// The heart of it: on real hardware the first format is NOT the one a
    /// photo is captured with. If this ever stops being true the bug becomes
    /// unreachable and these tests become vacuous — so assert it explicitly.
    @Test(arguments: ["capabilities-iPhone16,1", "capabilities-iPhone18,1"])
    func firstFormatIsNotTheCaptureFormat(_ name: String) throws {
        let caps = try Self.load(name)
        for lens in caps.lenses {
            let first = try #require(lens.formats.first)
            let capture = try #require(lens.captureFormat)
            #expect(capture.width > first.width,
                    "\(name) \(lens.localizedName): formats.first is \(first.width)px, capture is \(capture.width)px")
        }
    }

    /// The capture format must be the full-resolution one.
    @Test func captureFormatIsFullResolution() throws {
        let caps = try Self.load("capabilities-iPhone16,1")
        let wide = try #require(caps.lenses.first { $0.deviceType.contains("WideAngle") })
        let format = try #require(wide.captureFormat)
        #expect(format.width == 4032)
        #expect(format.height == 3024)
    }

    /// Bug 1: pixel scale. Reading the preview format understates drift by
    /// roughly 20×, which turns a badly smeared frame into an "excellent" one.
    @Test func previewFormatWouldUnderstateDriftByAnOrderOfMagnitude() throws {
        let caps = try Self.load("capabilities-iPhone16,1")
        let wide = try #require(caps.lenses.first { $0.deviceType.contains("WideAngle") })
        let first = try #require(wide.formats.first)
        let capture = try #require(wide.captureFormat)

        func pixelsPerRadian(_ f: FormatCapability) -> Double {
            Double(f.width) / (Double(f.horizontalFieldOfViewDegrees) * .pi / 180)
        }
        let ratio = pixelsPerRadian(capture) / pixelsPerRadian(first)
        #expect(ratio > 10, "expected a large discrepancy, got \(ratio)x")
    }

    /// Bug 2: ISO ceiling. The preview format caps lower than the sensor can
    /// actually do, so a legitimate dark-sky ISO request would be rejected.
    @Test func previewFormatWouldRejectALegitimateDarkSkyISO() throws {
        let caps = try Self.load("capabilities-iPhone16,1")
        let wide = try #require(caps.lenses.first { $0.deviceType.contains("WideAngle") })
        let first = try #require(wide.formats.first)
        let capture = try #require(wide.captureFormat)

        // What the preset derives under a dark sky.
        let requested = AstroPreset.isoCeiling

        #expect(requested > first.maxISO,
                "the preview format's ceiling (\(first.maxISO)) must be below the preset's \(requested) for this bug to be real")
        #expect(requested <= capture.maxISO,
                "the capture format must actually allow the preset's ceiling")
    }

    /// Both call sites must agree, or the settings applied and the stability
    /// recorded describe different sensors.
    @Test func presetAndCoordinatorSelectTheSameFormat() throws {
        for name in ["capabilities-iPhone16,1", "capabilities-iPhone18,1"] {
            let caps = try Self.load(name)
            for lens in caps.lenses {
                #expect(AstroPreset.astroFormat(for: lens) == lens.captureFormat)
            }
        }
    }

    @Test func lensWithNoFormatsHasNoCaptureFormat() {
        let empty = LensCapability(deviceType: "t", localizedName: "n",
                                   focalLengthEquivalent: 24, formats: [])
        #expect(empty.captureFormat == nil)
    }
}
