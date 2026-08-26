import Foundation
import DeepSkyCore
import DeepSkyCapture

#if os(iOS)
import AVFoundation

/// Bridges `AVCapturePhotoCaptureDelegate` to async/await.
///
/// `AVCapturePhoto` is NOT Sendable, so it never leaves this object. The
/// delegate extracts `fileDataRepresentation()` where the photo arrives and
/// resumes the continuation with `Data`, which is Sendable. This is the one
/// permitted `@unchecked Sendable` in the project: its only mutable state is a
/// completion flag, and the object itself never crosses an actor boundary.
private final class FrameDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    /// AVFoundation can call back more than once on some error paths, and
    /// resuming a continuation twice traps. The flag is the guard.
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        continuation.resume(with: result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            finish(.failure(CaptureError.settingsNotApplied))
            return
        }
        finish(.success(data))
    }
}

/// Real AVFoundation ProRAW capture behind the `CameraDevice` seam.
///
/// This is the only type in the project permitted to touch AVFoundation.
/// Everything above it — the coordinator, the capture policy, the session
/// store — is written against the protocol and stays testable without
/// hardware. That separation is why the coordinator needed no changes at all
/// to move from synthetic frames to a real sensor.
public actor AVCaptureDriver: CameraDevice {

    /// Non-isolated because callers read it synchronously while configuring
    /// the UI, and it never changes after construction.
    public nonisolated let capabilities: DeviceCapabilities

    /// How long to let auto-exposure converge before reading what it chose.
    /// Dark scenes settle slowly; too short a wait reports a half-converged
    /// value and the derived ISO comes out too low. Chosen by feel, not by
    /// measurement — worth revisiting once real sessions exist.
    static let autoExposureSettleSeconds = 1.5

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let device: AVCaptureDevice
    private var applied: CaptureSettings?
    private var delegates: [Int: FrameDelegate] = [:]

    private let captureQueue = DispatchQueue(label: "com.deepsky.capture", qos: .userInitiated)

    public init(lensIndex: Int) throws {
        let probed = try CapabilityProbe.run()
        guard lensIndex >= 0, lensIndex < probed.lenses.count else {
            throw CaptureError.invalidLensIndex(lensIndex)
        }
        self.capabilities = probed

        let wanted = probed.lenses[lensIndex].deviceType
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: CapabilityProbe.deviceTypes, mediaType: .video, position: .back)
        guard let match = discovery.devices.first(where: { $0.deviceType.rawValue == wanted }) else {
            throw CaptureError.invalidLensIndex(lensIndex)
        }
        self.device = match

        session.beginConfiguration()
        session.sessionPreset = .photo

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: match)
        } catch {
            session.commitConfiguration()
            throw error
        }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.settingsNotApplied
        }
        session.addInput(input)
        session.addOutput(output)

        // Must be enabled before ProRAW pixel formats become available.
        if output.isAppleProRAWSupported {
            output.isAppleProRAWEnabled = true
        }
        session.commitConfiguration()
    }

    // MARK: - Session lifecycle

    public func start() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    // MARK: - Metering

    /// Lets auto-exposure settle, then reports what it chose. `AstroPreset`
    /// scales that reading onto the fixed one-second shutter.
    public func meterLight() async throws -> LightReading {
        try device.lockForConfiguration()
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()

        try await Task.sleep(for: .seconds(Self.autoExposureSettleSeconds))

        return LightReading(iso: device.iso,
                            exposureSeconds: CMTimeGetSeconds(device.exposureDuration))
    }

    // MARK: - Manual control

    public func apply(_ settings: CaptureSettings) async throws {
        guard settings.lensIndex >= 0, settings.lensIndex < capabilities.lenses.count else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        guard let format = capabilities.lenses[settings.lensIndex].captureFormat else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        guard settings.exposure.seconds <= format.maxExposureSeconds else {
            throw CaptureError.exposureOutOfRange(
                requested: settings.exposure.seconds, max: format.maxExposureSeconds)
        }
        guard settings.iso <= format.maxISO else {
            throw CaptureError.isoOutOfRange(requested: settings.iso, max: format.maxISO)
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Clamp against the ACTIVE format, which can differ from the probed one
        // we validated against — the session preset may have selected another.
        let active = device.activeFormat
        let duration = CMTime(seconds: min(settings.exposure.seconds,
                                           CMTimeGetSeconds(active.maxExposureDuration)),
                              preferredTimescale: 1_000_000)
        let iso = min(max(settings.iso, active.minISO), active.maxISO)
        device.setExposureModeCustom(duration: duration, iso: iso) { _ in }

        if device.isFocusModeSupported(.locked) {
            device.setFocusModeLocked(lensPosition: settings.lensPosition) { _ in }
        }

        if device.isWhiteBalanceModeSupported(.locked) {
            let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(settings.whiteBalanceKelvin), tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: temperature)
            // Gains below 1 or above the device maximum throw an exception
            // rather than returning an error, so clamp before applying.
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(1, gains.redGain), maxGain)
            gains.greenGain = min(max(1, gains.greenGain), maxGain)
            gains.blueGain = min(max(1, gains.blueGain), maxGain)
            device.setWhiteBalanceModeLocked(with: gains) { _ in }
        }

        applied = settings
    }

    // MARK: - Capture

    public func captureFrame(index: Int) async throws -> CapturedFrame {
        guard let settings = applied else { throw CaptureError.settingsNotApplied }
        let rawFormat = try rawPixelFormat()

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let delegate = FrameDelegate(continuation: continuation)
            delegates[index] = delegate
            let photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            photoSettings.flashMode = .off
            output.capturePhoto(with: photoSettings, delegate: delegate)
        }
        delegates[index] = nil

        return CapturedFrame(index: index, rawData: data,
                             capturedAt: Date(), appliedSettings: settings)
    }

    /// Prefers Apple ProRAW over Bayer when both are offered. ProRAW carries
    /// Apple's demosaic and lens correction while remaining high bit depth,
    /// which is the right trade for stacking without owning a demosaic.
    private func rawPixelFormat() throws -> OSType {
        let available = output.availableRawPhotoPixelFormatTypes
        guard !available.isEmpty else { throw CaptureError.settingsNotApplied }
        if let proRAW = available.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAW
        }
        return available[0]
    }
}
#endif
