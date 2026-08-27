import Foundation
import SwiftUI
import UIKit
import AVFoundation
import DeepSkyCore
import DeepSkyCapture
import DeepSkySession
import DeepSkyAVCapture

/// Owns the real capture flow: probe the hardware, meter the scene, derive
/// settings, then drive `CaptureCoordinator` against `AVCaptureDriver`.
///
/// Everything the UI displays comes from this device's reported limits. There
/// are no fallback constants for ISO or shutter — if the probe fails, the
/// screen says so rather than showing a plausible-looking number.
@MainActor
@Observable
final class CaptureModel {

    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case capturing(done: Int, total: Int)
        case finished(framesWritten: Int, flagged: Int, interrupted: Bool)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var settings: CaptureSettings?
    private(set) var lensName = "—"
    private(set) var maxFrames = 1
    private(set) var lastSessionURL: URL?

    /// The live session, once the hardware has been probed. Nil until then —
    /// the screen shows a placeholder rather than an empty black rectangle.
    private(set) var previewSession: AVCaptureSession?

    var requestedFrames = 1
    var lensPosition = 1.0

    private var driver: AVCaptureDriver?
    private var capabilities: DeviceCapabilities?
    private var lensIndex = 0

    var isBusy: Bool {
        switch phase {
        case .preparing, .capturing: return true
        default: return false
        }
    }

    /// Human-readable shutter, or an em dash before the hardware has answered.
    var shutterLabel: String { settings?.exposure.displayLabel ?? "—" }
    var isoLabel: String { settings.map { "\(Int($0.iso))" } ?? "—" }

    var effectiveExposureSeconds: Double {
        (settings?.exposure.seconds ?? 0) * Double(requestedFrames)
    }

    // MARK: - Preparation

    /// Probe, meter, derive. Runs once when the screen appears.
    func prepare() async {
        guard case .idle = phase else { return }
        phase = .preparing

        guard await CapabilityProbe.requestAccess() else {
            phase = .failed("Camera access denied. Enable it in Settings → DeepSky.")
            return
        }

        do {
            let caps = try CapabilityProbe.run()
            guard let index = AstroPreset.recommendedLensIndex(caps) else {
                phase = .failed("No usable back camera found on this device.")
                return
            }

            let driver = try AVCaptureDriver(lensIndex: index)
            // Publish the session before metering: the preview can start
            // rendering during the 1.5s auto-exposure settle rather than
            // making the user stare at a placeholder through it.
            self.previewSession = driver.previewSession
            await driver.start()

            // Metering needs the session running, so this must follow start().
            let light = try await driver.meterLight()
            guard let derived = AstroPreset.settings(
                capabilities: caps, lensIndex: index, light: light) else {
                phase = .failed("Could not derive capture settings from this camera.")
                return
            }

            self.capabilities = caps
            self.driver = driver
            self.lensIndex = index
            self.settings = derived
            self.lensName = caps.lenses[index].localizedName
            self.maxFrames = AstroPreset.maxFrames(for: caps.lenses[index])
            self.requestedFrames = maxFrames      // default to the full budget
            self.lensPosition = Double(derived.lensPosition)
            phase = .ready
        } catch {
            phase = .failed("Setup failed: \(error)")
        }
    }

    // MARK: - Capture

    func startCapture(named name: String) async {
        guard case .ready = phase else { return }
        guard let driver, let capabilities, var settings else { return }

        // Focus is the one setting the user controls directly.
        settings.lensPosition = Float(lensPosition)

        phase = .capturing(done: 0, total: requestedFrames)

        // iOS revokes camera access the moment the app leaves the foreground,
        // and a locked screen does exactly that — no app can keep shooting
        // through it. So the fix is to stop the screen locking in the first
        // place, for as long as the session runs and no longer.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            let root = URL.documentsDirectory.appendingPathComponent("Sessions")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let manifest = SessionManifest(
                id: UUID().uuidString,
                name: name,
                startedAt: Date(),
                plan: CapturePlan(sensorExposure: settings.exposure,
                                  intervalSeconds: 0.05,
                                  frameCount: requestedFrames),
                capabilities: capabilities,
                settings: settings)

            let coordinator = CaptureCoordinator(
                camera: driver,
                store: SessionStore(root: root),
                sensor: DeviceEnvironmentSensor())

            let completion = try await coordinator.run(
                manifest: manifest, settings: settings, isDark: false)

            lastSessionURL = root
            phase = .finished(framesWritten: completion.framesWritten,
                              flagged: completion.framesFlagged,
                              interrupted: completion.interrupted)
        } catch {
            phase = .failed("Capture failed: \(error)")
        }
    }

    /// Returns to `.ready` after a finished or failed run so another session
    /// can start without re-probing the hardware.
    func reset() {
        guard settings != nil else {
            phase = .idle
            return
        }
        phase = .ready
    }
}
