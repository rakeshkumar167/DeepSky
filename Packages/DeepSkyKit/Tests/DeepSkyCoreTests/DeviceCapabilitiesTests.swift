import Testing
import Foundation
import DeepSkyCore

@Test func decodesCapabilityJSONFromProbe() throws {
    let json = """
    {
      "deviceModel": "iPhone17,1",
      "osVersion": "26.3",
      "supportsAppleProRAW": true,
      "probedAt": 776000000,
      "lenses": [{
        "deviceType": "AVCaptureDeviceTypeBuiltInWideAngleCamera",
        "localizedName": "Back Camera",
        "focalLengthEquivalent": 24,
        "formats": [{
          "width": 4032, "height": 3024,
          "minExposureSeconds": 0.000015,
          "maxExposureSeconds": 1.0,
          "minISO": 55.0, "maxISO": 12288.0,
          "horizontalFieldOfViewDegrees": 68.0,
          "maxPhotoDimensions": [[4032, 3024], [8064, 6048]],
          "rawPixelFormats": ["bgg4"]
        }]
      }]
    }
    """.data(using: .utf8)!

    let caps = try JSONDecoder().decode(DeviceCapabilities.self, from: json)
    #expect(caps.deviceModel == "iPhone17,1")
    #expect(caps.supportsAppleProRAW)
    #expect(caps.lenses.count == 1)
    #expect(caps.lenses[0].formats[0].maxExposureSeconds == 1.0)
    #expect(caps.lenses[0].focalLengthEquivalent == 24)
}

@Test func toleratesMissingOptionalFields() throws {
    let json = """
    {"deviceModel":"iPhone16,1","osVersion":"26.3","supportsAppleProRAW":false,
     "probedAt":776000000,
     "lenses":[{"deviceType":"t","localizedName":"n","formats":[]}]}
    """.data(using: .utf8)!
    let caps = try JSONDecoder().decode(DeviceCapabilities.self, from: json)
    #expect(caps.lenses[0].focalLengthEquivalent == nil)
    #expect(caps.lenses[0].formats.isEmpty)
}
