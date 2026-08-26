# DeepSky MVP — Plan A: Real Capture

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the synthetic driver with real AVFoundation ProRAW capture, driven by a hardware-derived astro preset, so a real night-sky session can be shot on an iPhone and exported as DNGs.

**Architecture:** `CaptureCoordinator` is unchanged — it already drives sessions, applies capture policy, senses the environment, flags frames and persists everything behind the `CameraDevice` actor protocol. This plan adds a second conformer (`AVCaptureDriver`), a pure preset that derives settings from probed capabilities, and a real `EnvironmentSensor`. The pure logic is Mac-testable against two committed real-device profiles; only the driver itself needs hardware.

**Tech Stack:** Swift 6.2.4 (strict concurrency), AVFoundation, CoreMotion, SwiftUI, Swift Testing. Xcode 26.3 / iOS SDK 26.2.

**Spec:** `docs/superpowers/specs/2026-08-27-deepsky-mvp-design.md`

## Global Constraints

- **Swift 6 language mode, strict concurrency.** Every public type crossing a boundary is `Sendable`.
- **`AVCapturePhoto` is not `Sendable`.** The delegate extracts `photo.fileDataRepresentation()` on the capture queue; **only `Data` crosses the actor boundary**. Buffers never escape the queue that owns them.
- **No `@unchecked Sendable`, no `nonisolated(unsafe)` in `Sources/`.** If strict concurrency blocks you, report it rather than silencing it.
- **AVFoundation may only be imported inside `DeepSkyAVCapture`.** No other target, and never the App target.
- **`DeepSkyCore` depends on nothing.** `AstroPreset` is pure and imports only `Foundation`.
- **Never hardcode exposure or ISO limits.** Every value derives from probed `FormatCapability` at runtime. The measured ceiling is 1.000s on both test devices, but it is always read, never assumed.
- **Test framework is Swift Testing** (`@Test`, `#expect`), not XCTest.
- Run Mac tests: `swift test --package-path Packages/DeepSkyKit`
- Build for device: `xcodebuild -project DeepSky.xcodeproj -scheme DeepSky -destination 'id=00008130-001611540208001C' -derivedDataPath /tmp/ds -allowProvisioningUpdates build`
- **Do NOT pass `DEVELOPMENT_TEAM` on the command line.** The correct team (`88B7ABS69Q`) is already in `project.pbxproj`; the ID inside the certificate name (`NYCF4Y95QJ`) is a different personal team and forcing it fails signing.
- Device testing uses the **iPhone 15 Pro only** (UDID `00008130-001611540208001C`). Developer Mode is off on the 17 Pro.

---

### Task 1: Make `LuminancePatch` failable (blocking prerequisite)

**Files:**
- Modify: `Packages/DeepSkyKit/Sources/DeepSkyMetrics/HalfFluxDiameter.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyMetricsTests/HalfFluxDiameterTests.swift`

**Interfaces:**
- Produces: `LuminancePatch.init?(width: Int, height: Int, pixels: [Float])` — failable, returns `nil` on size mismatch.

`LuminancePatch.init` currently calls `precondition(pixels.count == width * height)`, which **traps**. That is correct fail-fast behaviour today because nothing feeds it live data. The moment Task 8 feeds it slices of a live capture buffer, an off-by-one in stride or crop becomes a hard crash of the capture pipeline mid-session instead of one dropped frame. This is listed as a hard prerequisite in `PLAN-2-PREREQUISITES.md`.

- [ ] **Step 1: Write the failing test**

Add to `HalfFluxDiameterTests.swift`:

```swift
@Test func mismatchedPixelCountReturnsNilRatherThanTrapping() {
    #expect(LuminancePatch(width: 8, height: 8, pixels: [Float](repeating: 0, count: 63)) == nil)
    #expect(LuminancePatch(width: 8, height: 8, pixels: [Float](repeating: 0, count: 65)) == nil)
    #expect(LuminancePatch(width: 0, height: 0, pixels: []) == nil)
    #expect(LuminancePatch(width: 8, height: 8, pixels: [Float](repeating: 0, count: 64)) != nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter mismatchedPixelCount`
Expected: FAIL to compile — the initialiser is not optional, so `== nil` is invalid.

- [ ] **Step 3: Write minimal implementation**

Replace the initialiser in `HalfFluxDiameter.swift`:

```swift
    /// Returns nil rather than trapping on a size mismatch. Live capture
    /// buffers are sliced by stride and crop arithmetic that this type does
    /// not control; a malformed slice must cost one frame, not the session.
    public init?(width: Int, height: Int, pixels: [Float]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
```

- [ ] **Step 4: Fix existing call sites**

Every existing test constructs `LuminancePatch` directly and now needs unwrapping. In the test files, use `#require`:

```swift
let patch = try #require(LuminancePatch(width: size, height: size, pixels: pixels))
```

Mark those test functions `throws`. Do NOT use `!` — a nil there should fail the test with a message, not crash the runner.

- [ ] **Step 5: Run the full suite**

Run: `swift test --package-path Packages/DeepSkyKit`
Expected: PASS, 100 tests (99 existing + 1 new).

- [ ] **Step 6: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "fix: make LuminancePatch failable before live buffers reach it"
```

---

### Task 2: `AstroPreset` — derive settings from probed hardware

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/AstroPreset.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/AstroPresetTests.swift`

**Interfaces:**
- Consumes: `DeviceCapabilities`, `LensCapability`, `FormatCapability`, `ShutterSpeed`, `CaptureSettings`
- Produces:
  - `public struct LightReading: Sendable, Hashable` — `iso: Float`, `exposureSeconds: Double`
  - `public enum AstroPreset` with `isoCeiling: Float`, `trailingRuleConstant: Double`, `defaultWhiteBalanceKelvin: Int`, and:
    - `static func recommendedLensIndex(_ capabilities: DeviceCapabilities) -> Int?`
    - `static func astroFormat(for lens: LensCapability) -> FormatCapability?`
    - `static func maxFrames(for lens: LensCapability) -> Int`
    - `static func settings(capabilities:lensIndex:light:) -> CaptureSettings?`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import DeepSkyCore

struct AstroPresetTests {
    static func load(_ name: String) throws -> DeviceCapabilities {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(DeviceCapabilities.self, from: Data(contentsOf: url))
    }
    static func pro15() throws -> DeviceCapabilities { try load("capabilities-iPhone16,1") }
    static func pro17() throws -> DeviceCapabilities { try load("capabilities-iPhone18,1") }

    /// The wide is the light bucket on both devices — 12320/12096 max ISO
    /// against 3072 and 2304. The preset must derive that, not assume it.
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

    /// A dark sky pins auto-exposure at its limits, which should scale to the
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
        let settings = try #require(AstroPreset.settings(
            capabilities: caps, lensIndex: index,
            light: LightReading(iso: 100, exposureSeconds: 0.002)))
        #expect(settings.iso < 100)
        #expect(settings.iso >= caps.lenses[index].formats[0].minISO)
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

    @Test func alwaysAllowsAtLeastOneFrame() throws {
        let absurd = LensCapability(deviceType: "t", localizedName: "n",
                                    focalLengthEquivalent: 100_000, formats: [])
        #expect(AstroPreset.maxFrames(for: absurd) >= 1)
    }

    @Test func returnsNilForAnInvalidLensIndex() throws {
        let caps = try Self.pro15()
        #expect(AstroPreset.settings(capabilities: caps, lensIndex: -1,
                                     light: LightReading(iso: 800, exposureSeconds: 1)) == nil)
        #expect(AstroPreset.settings(capabilities: caps, lensIndex: 99,
                                     light: LightReading(iso: 800, exposureSeconds: 1)) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter AstroPresetTests`
Expected: FAIL — "cannot find 'AstroPreset' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// What auto-exposure settled on before we took manual control.
public struct LightReading: Sendable, Hashable {
    public let iso: Float
    public let exposureSeconds: Double
    public init(iso: Float, exposureSeconds: Double) {
        self.iso = iso
        self.exposureSeconds = exposureSeconds
    }
}

/// Derives capture settings from what the hardware actually reported.
///
/// Nothing here is hardcoded to a device. Every value comes from a probed
/// `FormatCapability`, so the same logic adapts across lenses and models —
/// which matters, because the two devices tested differ sharply (48MP on one
/// lens versus three; 2304 versus 7680 telephoto ISO).
public enum AstroPreset {

    /// Past roughly this point, noise grows faster than signal on phone
    /// sensors. NOTE: this is conventional wisdom, NOT measured on these
    /// sensors — the first thing to validate on a real sky. The wide reports
    /// a 12320 ceiling and may well stack better than this allows.
    public static let isoCeiling: Float = 6400

    /// The "500 rule": a star trails visibly after about 500/focal seconds.
    /// Frames are 1 second each, so this is also the frame ceiling.
    public static let trailingRuleConstant = 500.0

    /// Used when a lens reports no focal length. 24mm is the conventional
    /// phone wide, and assuming a *shorter* lens would allow more frames and
    /// risk trailing, so this errs toward caution.
    static let fallbackFocalLength = 24

    /// Spec §21's astro-neutral range is 3000-5000K.
    public static let defaultWhiteBalanceKelvin = 3900

    /// The lens with the most ISO headroom is the light bucket. Derived rather
    /// than assumed: it happens to be the wide on both tested devices, but the
    /// rule is what generalises.
    public static func recommendedLensIndex(_ capabilities: DeviceCapabilities) -> Int? {
        let scored = capabilities.lenses.enumerated().compactMap { index, lens -> (Int, Float)? in
            guard let maxISO = lens.formats.map(\.maxISO).max() else { return nil }
            return (index, maxISO)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// The format an astro capture uses: longest possible sensor exposure
    /// first, largest sensor area to break ties. The exposure ceiling
    /// dominates because it sets how few frames a given integration needs,
    /// and every extra frame is more accumulated drift.
    public static func astroFormat(for lens: LensCapability) -> FormatCapability? {
        lens.formats.max { a, b in
            a.maxExposureSeconds != b.maxExposureSeconds
                ? a.maxExposureSeconds < b.maxExposureSeconds
                : (a.width * a.height) < (b.width * b.height)
        }
    }

    public static func maxFrames(for lens: LensCapability) -> Int {
        let focal = lens.focalLengthEquivalent ?? fallbackFocalLength
        guard focal > 0 else { return 1 }
        return max(1, Int(trailingRuleConstant / Double(focal)))
    }

    /// Scales the metered exposure onto our fixed 1-second shutter, then
    /// clamps. On a dark sky auto-exposure is already pinned at its limits, so
    /// this correctly yields "ceiling ISO at one second".
    public static func settings(
        capabilities: DeviceCapabilities,
        lensIndex: Int,
        light: LightReading
    ) -> CaptureSettings? {
        guard lensIndex >= 0, lensIndex < capabilities.lenses.count else { return nil }
        let lens = capabilities.lenses[lensIndex]
        guard let format = astroFormat(for: lens) else { return nil }

        let shutter = format.maxExposureSeconds
        guard shutter > 0, shutter.isFinite else { return nil }

        let scaled = Double(light.iso) * (light.exposureSeconds / shutter)
        let upperBound = min(format.maxISO, isoCeiling)
        let iso = min(max(Float(scaled.isFinite ? scaled : 0), format.minISO), upperBound)

        return CaptureSettings(
            lensIndex: lensIndex,
            iso: iso,
            exposure: ShutterSpeed(seconds: shutter),
            lensPosition: 1.0,                       // infinity
            whiteBalanceKelvin: defaultWhiteBalanceKelvin,
            exposureBias: 0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter AstroPresetTests`
Expected: PASS, 8 tests.

If `frameCeilingDerivesFromFocalLength` fails, read the actual `focalLengthEquivalent` out of the fixture before changing the implementation — the expected values (26/15/84mm) come from the committed profiles, and the derivation reads ~8% long against Apple's published figures by design.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: derive astro capture settings from probed hardware"
```

---

### Task 3: `AVCaptureDriver` — capabilities and session configuration

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyAVCapture/AVCaptureDriver.swift`

**Interfaces:**
- Consumes: `CameraDevice`, `CaptureSettings`, `CapturedFrame`, `CaptureError`, `DeviceCapabilities`
- Produces: `public actor AVCaptureDriver: CameraDevice` with `init(lensIndex:) async throws`, `var capabilities: DeviceCapabilities`, `func apply(_:) async throws`, `func captureFrame(index:) async throws -> CapturedFrame`, `func meterLight() async throws -> LightReading`

This task builds only construction and capability reporting. Exposure control is Task 4, capture is Task 5. Splitting keeps each device-verified step small enough to diagnose when it misbehaves.

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import DeepSkyCore
import DeepSkyCapture

#if os(iOS)
import AVFoundation

/// Real AVFoundation ProRAW capture behind the `CameraDevice` seam.
///
/// This is the only type in the project permitted to touch AVFoundation.
/// Everything above it — the coordinator, the policy, the session store —
/// is written against the protocol and stays testable without hardware.
public actor AVCaptureDriver: CameraDevice {
    public nonisolated let capabilities: DeviceCapabilities

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let device: AVCaptureDevice
    private var applied: CaptureSettings?

    /// Serial queue owning every non-Sendable AVFoundation object. Nothing
    /// that is not a value type crosses off it.
    private let captureQueue = DispatchQueue(label: "com.deepsky.capture", qos: .userInitiated)
    private var delegates: [Int: FrameDelegate] = [:]

    public init(lensIndex: Int) async throws {
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

        try configureSession()
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.settingsNotApplied
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            throw CaptureError.settingsNotApplied
        }
        session.addOutput(output)

        // Must be enabled before ProRAW pixel formats become available.
        if output.isAppleProRAWSupported {
            output.isAppleProRAWEnabled = true
        }
    }

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
}
#endif
```

- [ ] **Step 2: Verify it compiles for iOS**

Run:
```bash
cd Packages/DeepSkyKit && xcodebuild -scheme DeepSkyAVCapture -destination 'generic/platform=iOS' -derivedDataPath /tmp/dsk-ios build 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED. `AVCaptureDriver` does not yet satisfy `CameraDevice`, so if the compiler complains about missing `apply` / `captureFrame`, add temporary stubs that `throw CaptureError.settingsNotApplied` and remove them in Tasks 4 and 5.

- [ ] **Step 3: Verify the macOS build still compiles away cleanly**

Run: `swift build --package-path Packages/DeepSkyKit`
Expected: Build complete. The `#if os(iOS)` guard must keep this file out of the macOS build entirely.

- [ ] **Step 4: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add AVCaptureDriver session configuration"
```

---

### Task 4: Manual exposure, focus and white balance

**Files:**
- Modify: `Packages/DeepSkyKit/Sources/DeepSkyAVCapture/AVCaptureDriver.swift`

**Interfaces:**
- Produces: `func apply(_ settings: CaptureSettings) async throws`, `func meterLight() async throws -> LightReading`

- [ ] **Step 1: Write the implementation**

Add to `AVCaptureDriver`:

```swift
    /// Lets auto-exposure settle, then reports what it chose. `AstroPreset`
    /// scales this onto the fixed 1-second shutter.
    public func meterLight() async throws -> LightReading {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [device] in
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.unlockForConfiguration()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Give AE time to converge on a dark scene.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    continuation.resume(returning: LightReading(
                        iso: device.iso,
                        exposureSeconds: CMTimeGetSeconds(device.exposureDuration)))
                }
            }
        }
    }

    public func apply(_ settings: CaptureSettings) async throws {
        guard settings.lensIndex >= 0, settings.lensIndex < capabilities.lenses.count else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        guard let format = capabilities.lenses[settings.lensIndex].formats.first else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        guard settings.exposure.seconds <= format.maxExposureSeconds else {
            throw CaptureError.exposureOutOfRange(
                requested: settings.exposure.seconds, max: format.maxExposureSeconds)
        }
        guard settings.iso <= format.maxISO else {
            throw CaptureError.isoOutOfRange(requested: settings.iso, max: format.maxISO)
        }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            captureQueue.async { [device] in
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }

                    // Clamp to what the ACTIVE format allows — it can differ
                    // from the probed format we validated against.
                    let duration = CMTime(seconds: settings.exposure.seconds, preferredTimescale: 1_000_000)
                    let iso = min(max(settings.iso, device.activeFormat.minISO),
                                  device.activeFormat.maxISO)
                    device.setExposureModeCustom(duration: duration, iso: iso) { _ in }

                    if device.isFocusModeSupported(.locked) {
                        device.setFocusModeLocked(lensPosition: settings.lensPosition) { _ in }
                    }

                    if device.isWhiteBalanceModeSupported(.locked) {
                        let temp = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                            temperature: Float(settings.whiteBalanceKelvin), tint: 0)
                        var gains = device.deviceWhiteBalanceGains(for: temp)
                        let maxGain = device.maxWhiteBalanceGain
                        gains.redGain = min(max(1, gains.redGain), maxGain)
                        gains.greenGain = min(max(1, gains.greenGain), maxGain)
                        gains.blueGain = min(max(1, gains.blueGain), maxGain)
                        device.setWhiteBalanceModeLocked(with: gains) { _ in }
                    }
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
        applied = settings
    }
```

- [ ] **Step 2: Verify it compiles for iOS**

Run the iOS build command from Task 3 Step 2.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: lock exposure, focus and white balance for capture"
```

---

### Task 5: ProRAW frame capture across the Sendable boundary

**Files:**
- Modify: `Packages/DeepSkyKit/Sources/DeepSkyAVCapture/AVCaptureDriver.swift`

**Interfaces:**
- Produces: `func captureFrame(index: Int) async throws -> CapturedFrame`

This is where the Slice 1 concurrency rule becomes load-bearing. `AVCapturePhoto` is **not** `Sendable`. The delegate must extract `Data` on the capture queue and hand only that across.

- [ ] **Step 1: Write the implementation**

Add to `AVCaptureDriver.swift`, outside the actor:

```swift
/// Bridges the delegate callback to async/await.
///
/// `AVCapturePhoto` is not Sendable, so it never leaves this object. The
/// delegate extracts `fileDataRepresentation()` on the capture queue and
/// resumes the continuation with `Data`, which is.
private final class FrameDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CaptureError.settingsNotApplied)
            return
        }
        continuation.resume(returning: data)
    }
}
```

Note: `@unchecked Sendable` here is confined to a delegate whose only mutable state is a `finished` flag touched solely on the capture queue, and it never crosses an actor boundary itself. This is the one permitted exception; do not extend it.

Add to the actor:

```swift
    public func captureFrame(index: Int) async throws -> CapturedFrame {
        guard let settings = applied else { throw CaptureError.settingsNotApplied }

        let rawFormat = try rawPixelFormat()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let delegate = FrameDelegate(continuation: continuation)
            self.delegates[index] = delegate
            captureQueue.async { [output] in
                let photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
                photoSettings.flashMode = .off
                output.capturePhoto(with: photoSettings, delegate: delegate)
            }
        }
        delegates[index] = nil

        return CapturedFrame(index: index, rawData: data,
                             capturedAt: Date(), appliedSettings: settings)
    }

    /// Prefers Apple ProRAW ('l64r') over Bayer when both are offered.
    private func rawPixelFormat() throws -> OSType {
        let available = output.availableRawPhotoPixelFormatTypes
        guard !available.isEmpty else { throw CaptureError.settingsNotApplied }
        if let proRAW = available.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAW
        }
        return available[0]
    }
```

- [ ] **Step 2: Verify it compiles for iOS**

Run the iOS build command from Task 3 Step 2.
Expected: BUILD SUCCEEDED, and `AVCaptureDriver` now fully satisfies `CameraDevice` — remove any temporary stubs.

- [ ] **Step 3: Verify no forbidden escape hatches leaked into Sources**

Run:
```bash
grep -rn "unchecked Sendable\|nonisolated(unsafe)" Packages/DeepSkyKit/Sources/
```
Expected: exactly one hit — `FrameDelegate`. Any other hit is a defect.

- [ ] **Step 4: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: capture ProRAW frames across the Sendable boundary"
```

---

### Task 6: Real `EnvironmentSensor`

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyAVCapture/DeviceEnvironmentSensor.swift`

**Interfaces:**
- Consumes: `EnvironmentSensor` (from `DeepSkySession`), `ThermalState`
- Produces: `public final class DeviceEnvironmentSensor: EnvironmentSensor, @unchecked Sendable`

`CaptureCoordinator` already consumes `EnvironmentSensor` and is fully tested against a stub. This supplies the real one — `ProcessInfo` for thermal, `FileManager` for storage, `CMMotionManager` for angular rate.

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import DeepSkyCore
import DeepSkySession

#if os(iOS)
import CoreMotion

/// Real environment readings for the capture loop.
///
/// `EnvironmentSensor`'s methods are synchronous by design so the coordinator
/// can read them inline per frame. Gyro samples therefore accumulate in the
/// background and are read under a lock rather than awaited.
public final class DeviceEnvironmentSensor: EnvironmentSensor, @unchecked Sendable {
    private let motion = CMMotionManager()
    private let lock = NSLock()
    private var samples: [Double] = []

    public init() {
        motion.gyroUpdateInterval = 1.0 / 50.0
        if motion.isGyroAvailable {
            motion.startGyroUpdates(to: .main) { [weak self] data, _ in
                guard let self, let r = data?.rotationRate else { return }
                let magnitude = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
                self.lock.lock()
                self.samples.append(magnitude)
                if self.samples.count > 500 { self.samples.removeFirst(self.samples.count - 500) }
                self.lock.unlock()
            }
        }
    }

    deinit { motion.stopGyroUpdates() }

    public func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .serious   // unknown means unsafe, not fine
        }
    }

    public func freeBytes() -> Int64 {
        let url = URL.documentsDirectory
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return 0    // unknown free space must read as "none", never "plenty"
        }
        return capacity
    }

    /// RMS of the gyro magnitudes collected since the last read, then clears.
    public func rmsAngularRate() -> Double {
        lock.lock()
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !taken.isEmpty else { return 0 }
        let meanSquare = taken.reduce(0) { $0 + $1 * $1 } / Double(taken.count)
        return meanSquare.squareRoot()
    }
}
#endif
```

- [ ] **Step 2: Add the package dependency**

`DeepSkyAVCapture` now needs `DeepSkySession` for the `EnvironmentSensor` protocol. In `Package.swift`:

```swift
        .target(name: "DeepSkyAVCapture", dependencies: ["DeepSkyCore", "DeepSkyCapture", "DeepSkySession"]),
```

Confirm the graph stays acyclic: `DeepSkySession` does not depend on `DeepSkyAVCapture`.

- [ ] **Step 3: Verify both builds**

Run: `swift build --package-path Packages/DeepSkyKit`
Then the iOS build from Task 3 Step 2.
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add real environment sensor over ProcessInfo, FileManager and CoreMotion"
```

---

### Task 7: Wire the capture screen to real hardware

**Files:**
- Create: `App/CaptureModel.swift`
- Modify: `App/CameraScreen.swift`

**Interfaces:**
- Consumes: `AVCaptureDriver`, `AstroPreset`, `DeviceEnvironmentSensor`, `CaptureCoordinator`, `SessionStore`, `SessionManifest`, `CapturePlan`
- Produces: `@MainActor @Observable final class CaptureModel`

- [ ] **Step 1: Write the model**

```swift
import Foundation
import SwiftUI
import DeepSkyCore
import DeepSkyCapture
import DeepSkySession
import DeepSkyAVCapture

@MainActor
@Observable
final class CaptureModel {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case capturing(done: Int, total: Int)
        case finished(framesWritten: Int, flagged: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var settings: CaptureSettings?
    private(set) var maxFrames = 19
    var requestedFrames = 19
    var lensPosition = 1.0

    private var driver: AVCaptureDriver?
    private var capabilities: DeviceCapabilities?

    /// Probe, meter, derive settings. Everything shown on screen comes from
    /// this device's reported limits, never from a constant.
    func prepare() async {
        state = .preparing
        do {
            guard await CapabilityProbe.requestAccess() else {
                state = .failed("Camera access denied. Enable it in Settings → DeepSky.")
                return
            }
            let caps = try CapabilityProbe.run()
            guard let lensIndex = AstroPreset.recommendedLensIndex(caps) else {
                state = .failed("No usable camera found.")
                return
            }
            let driver = try await AVCaptureDriver(lensIndex: lensIndex)
            await driver.start()

            let light = try await driver.meterLight()
            guard let derived = AstroPreset.settings(
                capabilities: caps, lensIndex: lensIndex, light: light) else {
                state = .failed("Could not derive capture settings.")
                return
            }

            self.capabilities = caps
            self.driver = driver
            self.settings = derived
            self.maxFrames = AstroPreset.maxFrames(for: caps.lenses[lensIndex])
            self.requestedFrames = min(requestedFrames, maxFrames)
            state = .ready
        } catch {
            state = .failed("Setup failed: \(error)")
        }
    }

    func startCapture(named name: String) async {
        guard let driver, let capabilities, var settings else { return }
        settings.lensPosition = Float(lensPosition)

        state = .capturing(done: 0, total: requestedFrames)
        do {
            try await driver.apply(settings)

            let root = URL.documentsDirectory.appendingPathComponent("Sessions")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let manifest = SessionManifest(
                id: UUID().uuidString, name: name, startedAt: Date(),
                plan: CapturePlan(sensorExposure: settings.exposure,
                                  intervalSeconds: 0.05, frameCount: requestedFrames),
                capabilities: capabilities,
                settings: settings)

            let coordinator = CaptureCoordinator(
                camera: driver,
                store: SessionStore(root: root),
                sensor: DeviceEnvironmentSensor())

            let completion = try await coordinator.run(
                manifest: manifest, settings: settings, isDark: false)

            state = .finished(framesWritten: completion.framesWritten,
                              flagged: completion.framesFlagged)
        } catch {
            state = .failed("Capture failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Wire the screen**

In `CameraScreen.swift`, replace the mock `@State` values with the model:

```swift
    @State private var model = CaptureModel()
```

- Replace `iso` with `model.settings?.iso`, showing `"—"` until `.ready`.
- Replace the shutter ladder mock with `model.settings?.exposure.displayLabel`.
- Bind the frames slider to `model.requestedFrames` with range `1...Double(model.maxFrames)`.
- Bind the focus slider to `model.lensPosition`.
- In `.task { await model.prepare() }`, prepare on appear.
- `toggleCapture()` calls `Task { await model.startCapture(named: "Session") }`.
- Drive `captureProgress` from `model.state`.

Keep every visual decision unchanged — night mode, true black, tabular figures, the 84pt button, and the plan strip's `N × 1.0s → Ns` phrasing.

- [ ] **Step 3: Build for the device**

Run:
```bash
xcodebuild -project DeepSky.xcodeproj -scheme DeepSky -destination 'id=00008130-001611540208001C' -derivedDataPath /tmp/ds -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add App Packages
git commit -m "feat: wire capture screen to real hardware and preset"
```

---

### Task 8: Device verification and session export

**Files:**
- Modify: `App/SessionsScreen.swift`

**Interfaces:**
- Consumes: `SessionStore.readFrames(at:)`, `SessionManifest`

- [ ] **Step 1: Replace mock sessions with real ones**

Read the real session directories from `URL.documentsDirectory/Sessions`, decoding `session.json` with an ISO-8601 decoder and counting frames via `SessionStore.readFrames(at:)`. Keep the existing row and detail layout — only the data source changes. Show the empty state when no sessions exist yet.

- [ ] **Step 2: Install and run on device**

```bash
xcrun devicectl device install app --device 00008130-001611540208001C /tmp/ds/Build/Products/Debug-iphoneos/DeepSky.app
xcrun devicectl device process launch --device 00008130-001611540208001C --terminate-existing com.rakeshkumar167.DeepSky
```

- [ ] **Step 3: Manual verification checklist**

Indoors first, pointed at a dim scene:

1. App reaches `.ready` and shows a real ISO and `1.0s` shutter.
2. Frames slider caps at the derived ceiling (19 on the wide).
3. Capture 5 frames. Progress advances; the app does not hang.
4. Sessions tab lists the new session with 5 frames.
5. Files app → On My iPhone → DeepSky → Sessions → the session folder contains `session.json`, `frames.jsonl`, and 5 `.dng` files.
6. AirDrop one `.dng` to the Mac and confirm it opens as a RAW image.
7. `frames.jsonl` has 5 lines, each with `exposureSeconds: 1`, a real ISO, and a stability reading.

**Record the actual per-frame byte size** — the plan assumed ~25 MB for 12 MP ProRAW, and the storage policy depends on it.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat: list real capture sessions"
```

---

## Definition of Done

- `swift test --package-path Packages/DeepSkyKit` passes.
- The app captures a real ProRAW burst on the iPhone 15 Pro with settings derived from probed hardware, not constants.
- A session directory contains `session.json`, an append-only `frames.jsonl`, and one `.dng` per frame.
- DNGs open as RAW images on the Mac.
- `Sources/` contains exactly one `@unchecked Sendable` (`FrameDelegate`) and no `nonisolated(unsafe)`.
- No target outside `DeepSkyAVCapture` imports AVFoundation.

## Deferred to Plan B, with reasons

Two things the spec places in the MVP are **not** in this plan. Neither is an
oversight; both are recorded so they are not lost.

**The focus loupe bound to live HFD.** Spec §5 says manual focus ships with the
loupe reading live star sharpness. Plan A ships the manual focus *slider* and the
preset's infinity default, but not the live readout — that requires a second
capture output (`AVCaptureVideoDataOutput`), a preview frame stream, and the
`previewFrames()` protocol method that Slice 1 deliberately left off
`CameraDevice` as untested surface area. It is a whole capture path, not a
wiring job.

The consequence is real and worth stating: **without it, focus is set open-loop
at lensPosition 1.0 and you cannot confirm it on the phone.** iPhone lenses at
position 1.0 are approximately infinity, so first sessions should be usable, but
"approximately" is doing work there — verify against the exported DNGs on the Mac
before shooting anything you care about. If frames come back soft, this moves to
the front of Plan B.

**Warning when most frames are flagged `motion`.** Spec §7 requires warning
rather than silently producing a smeared stack. That warning belongs at the point
of stacking, which is Plan B. Plan A still *records* the flags correctly, so
nothing is lost.

## What Plan B inherits

Real ProRAW DNGs in a documented session format, `AstroPreset`, and a measured
per-frame byte size. Plan B adds `RAWDecoder`, `FrameStacker`, `ToneMapper` and
the result screen, and validates against these frames on the Mac.
