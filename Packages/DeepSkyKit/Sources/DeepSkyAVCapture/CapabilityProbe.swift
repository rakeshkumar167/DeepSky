import Foundation
import DeepSkyCore

#if os(iOS)
import AVFoundation

/// Errors the probe can report rather than guessing.
public enum ProbeError: Error, Sendable, Equatable {
    case cameraAccessNotAuthorized
    case noBackCamerasFound
    case couldNotConfigureSession(String)
}

/// Reads what this specific iPhone's cameras can actually do.
///
/// This is task zero of the whole project: every exposure decision downstream
/// is derived from these numbers rather than assumed. In particular it settles
/// `maxExposureDuration`, which determines how long a single sensor exposure
/// can really be — the value the shutter ladder is built from.
///
/// Run it on every device you intend to support and commit the JSON as a
/// fixture; `ShutterLadder` and `StabilityEstimator` are both tested against
/// real profiles rather than hypothetical ones.
public enum CapabilityProbe {

    /// Lens types worth probing for astrophotography. Virtual devices
    /// (`.builtInDualCamera` etc.) are deliberately excluded: they switch
    /// between physical lenses automatically, which is exactly what a fixed
    /// manual exposure must not do.
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
    ]

    /// Asks for camera permission. The probe cannot enumerate formats without
    /// it, so the app must await this before calling `run()`.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    public static func run() throws -> DeviceCapabilities {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw ProbeError.cameraAccessNotAuthorized
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: .back)
        let devices = discovery.devices
        guard !devices.isEmpty else { throw ProbeError.noBackCamerasFound }

        var lenses: [LensCapability] = []
        var anyProRAW = false

        for device in devices {
            let rawFormats = try rawPixelFormats(for: device)
            if rawFormats.supportsProRAW { anyProRAW = true }

            let formats = device.formats.map { format -> FormatCapability in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let fov = format.videoFieldOfView
                return FormatCapability(
                    width: Int(dims.width),
                    height: Int(dims.height),
                    minExposureSeconds: CMTimeGetSeconds(format.minExposureDuration),
                    maxExposureSeconds: CMTimeGetSeconds(format.maxExposureDuration),
                    minISO: format.minISO,
                    maxISO: format.maxISO,
                    horizontalFieldOfViewDegrees: fov,
                    maxPhotoDimensions: format.supportedMaxPhotoDimensions.map {
                        [Int($0.width), Int($0.height)]
                    },
                    rawPixelFormats: rawFormats.fourCCs)
            }

            lenses.append(LensCapability(
                deviceType: device.deviceType.rawValue,
                localizedName: device.localizedName,
                focalLengthEquivalent: focalLengthEquivalent(for: device),
                formats: formats))
        }

        return DeviceCapabilities(
            deviceModel: modelIdentifier(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            supportsAppleProRAW: anyProRAW,
            lenses: lenses,
            probedAt: Date())
    }

    // MARK: - RAW support

    /// RAW availability is a property of a configured photo output, not of the
    /// device in isolation, so a throwaway session is the only honest way to
    /// ask. The session is never started — configuring it is enough.
    private static func rawPixelFormats(
        for device: AVCaptureDevice
    ) throws -> (fourCCs: [String], supportsProRAW: Bool) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw ProbeError.couldNotConfigureSession(
                "input for \(device.localizedName): \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else {
            throw ProbeError.couldNotConfigureSession("cannot add input for \(device.localizedName)")
        }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            throw ProbeError.couldNotConfigureSession("cannot add photo output for \(device.localizedName)")
        }
        session.addOutput(output)

        // Must be enabled before the ProRAW pixel formats appear in the list.
        let proRAW = output.isAppleProRAWSupported
        if proRAW { output.isAppleProRAWEnabled = true }

        let fourCCs = output.availableRawPhotoPixelFormatTypes.map(fourCC)
        return (fourCCs, proRAW)
    }

    // MARK: - Derivations

    /// AVFoundation reports field of view, not focal length. Converting gives a
    /// number photographers recognise (13/24/48/120mm), derived from what the
    /// hardware actually reported rather than hardcoded per model.
    /// 36mm is the full-frame sensor width the 35mm-equivalent convention uses.
    static func focalLengthEquivalent(for device: AVCaptureDevice) -> Int? {
        guard let fov = device.formats.first?.videoFieldOfView, fov > 0, fov < 180 else { return nil }
        let radians = Double(fov) * .pi / 180.0
        let focal = 36.0 / (2.0 * tan(radians / 2.0))
        guard focal.isFinite, focal > 0 else { return nil }
        return Int(focal.rounded())
    }

    static func fourCC(_ type: OSType) -> String {
        let bytes = [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF),
        ]
        guard let s = String(bytes: bytes, encoding: .ascii),
              s.allSatisfy({ $0.isASCII && !$0.isNewline }) else {
            return String(format: "0x%08x", type)
        }
        return s
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
#endif
