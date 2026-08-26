# DeepSky — Slice 1: Capture Foundation

**Date:** 2026-08-26
**Status:** Design approved. Ready for implementation planning.
**Source requirements:** `requirements.txt` (48 sections)

---

## 1. Scope

`requirements.txt` is a product vision, not a buildable spec. Even its own §44 MVP is too large for
one implementation cycle. The work is split into three slices, each with its own
spec -> plan -> implementation cycle:

| Slice | Contents | Verifiable how |
|---|---|---|
| **1 — Capture foundation** *(this spec)* | Capability probe, manual controls, ProRAW capture, live preview + histogram, focus loupe, stability sensing, session recording | On-device |
| **2 — Processing engine** | Calibration, hot-pixel, star detection, alignment, sigma-clipped stacking, noise reduction. Headless package | Mac unit tests + synthetic fixtures |
| **3 — Develop & export** | Exposure recovery, light-pollution removal, Milky Way / star enhancement, tone mapping, non-destructive edit UI, export | Mac + device |

**Slice 1 produces no processed images.** It produces *sessions*: directories of calibrated-in-name-only
RAW frames plus a rigorous manifest. Its success is measured by whether Slice 2 can consume that
output without re-shooting.

### Explicitly out of scope for Slice 1
Stacking, frame alignment, hot-pixel correction, noise reduction, tone mapping, any pixel processing
of captured frames, the Gallery tab, star-trail mode, celestial compass / astronomy overlays,
capture planning with weather data, auto infinity-focus search, and *processing* of dark frames
(Slice 1 captures darks; Slice 2 consumes them).

---

## 2. Decisions

| # | Decision | Value |
|---|---|---|
| D1 | Device access | iPhone + paid Apple Developer account |
| D2 | Primary device | **iPhone 17 Pro** |
| D3 | Secondary device | **iPhone 15 Pro** |
| D4 | Distribution | **TestFlight**, not direct cable load |
| D5 | Build order | Slice 1 first |
| D6 | Product intent | Personal tool first, ship later. App-Store-clean code; skip onboarding/branding polish |
| D7 | Slice 1 extras IN | Focus magnification + star sharpness; dark-frame capture |
| D8 | Slice 1 extras OUT | Auto infinity-focus search; celestial compass / astronomy overlay |
| D9 | Architecture | Modular SPM packages, protocol-fronted capture, synthetic camera driver |
| D10 | Mode structure | One capture screen with Simple<->Expert disclosure; PHOTO/NIGHT dropped; 3 tabs |
| D11 | Frame rejection | Flag in manifest, never discard during capture |

### Deliberate deviations from `requirements.txt`

1. **§4's shutter ladder** (up to 30 s) is not implemented as written. The ladder is derived at
   runtime from hardware-reported limits. §27's "never pretend" principle governs.
2. **§40's five modes and four tabs** collapse to one capture screen with a Simple<->Expert toggle
   and three tabs. PHOTO and NIGHT are dropped — the stock camera does them better. STAR TRAILS is
   V2 per §45. Gallery arrives with Slice 3, when there are processed images to show.
3. **§30's "Discard current frame?" prompt** is overridden. Frames are flagged, never discarded.
   Prompting mid-session defeats unattended capture, and stacking can often rescue a marginally
   trailed frame. Slice 2 decides rejection with full context.

---

## 3. Environment

- Intel Mac (x86_64), **macOS 15.7.9** (Sequoia, build 24G830)
- **Xcode 26.3** (build 17C529), Universal build, `/Applications/Xcode-26.3.app`
- **iOS SDK 26.2** — satisfies the App Store Connect mandate (since 2026-04-28, uploads must use
  Xcode 26+ and an iOS 26 SDK)
- **Swift 6.2.4**, strict concurrency — verified compiling AVFoundation code under `-swift-version 6`
  for both `arm64-apple-ios26.2` (device) and `x86_64-apple-ios26.2-simulator`
- **iOS 26.3.1 simulator runtime** (23D8133, 9.7 GB) installed; iPhone 17 Pro / 17 Pro Max
  simulators available, matching the primary test device
- Xcode 16.3 retained as fallback at `/Applications/Xcode.app`
- Homebrew is broken and 5 years stale (checkout pinned at 2021-01-06). Not needed here.

### Toolchain gotchas worth keeping
- Xcode 26 ships as **two** builds. On Intel you need the **Universal** one
  (`Xcode_26.3_Universal.xip`), not the Apple-silicon build.
- Xcode 26.0–26.3 require macOS 15.6+. **26.4 requires macOS Tahoe 26.2**, so 26.3 is the ceiling
  while staying on Sequoia.
- Xcode 26 no longer bundles simulator runtimes; the `.xip` is only ~2.87 GB. Runtimes come from
  `xcodebuild -downloadPlatform iOS`.
- `pkgutil --check-signature` on a `.xip` validates only the TOC (stored at the start of the file)
  and **passes on a truncated download**. Verify completeness by parsing the xar TOC's `<offset>`/
  `<length>` data blocks and comparing `heap_start + max(offset+length)` to the file size, then
  check the payload SHA-1 against the TOC `archived-checksum`.
- `sudo` cannot be driven from an agent session (no TTY). Admin steps go through Terminal.app or
  Xcode's GUI first-run.

---

## 4. Architecture

```
DeepSky.xcodeproj                    hand-authored, folder-synchronized
├── App/                             iOS target, SwiftUI, thin
└── Packages/
    ├── DeepSkyCore/         value types, units, errors — zero dependencies
    ├── DeepSkyCapture/      CameraDevice protocol + AVCaptureDriver
    ├── DeepSkyMetrics/      histogram, HFD sharpness, stability — Accelerate
    ├── DeepSkySession/      session model + on-disk persistence
    └── DeepSkySynthetic/    SyntheticDriver — procedural star fields
```

**Dependency rule (one-way).** `Core` depends on nothing. `Capture`, `Metrics`, `Session` depend
only on `Core`. `Synthetic` depends on `Core` + `Capture`. `App` depends on all and owns no logic
worth unit-testing.

**Project generation.** No XcodeGen, Tuist, or Homebrew. Xcode 16+ supports
`PBXFileSystemSynchronizedRootGroup`, so a compact hand-authored `.xcodeproj` synchronises whole
folders and never needs regenerating as files are added. Verified by `xcodebuild -list` and a real
build.

### The seam

```swift
public protocol CameraDevice: Actor {
    var capabilities: DeviceCapabilities { get }
    func apply(_ settings: CaptureSettings) async throws
    func previewFrames() -> AsyncStream<PreviewFrame>
    func captureFrame(index: Int) async throws -> CapturedFrame
}
```

`AVCaptureDriver` (device) and `SyntheticDriver` (Simulator, plus Slice 2 fixture generation) both
conform. **The app target never imports AVFoundation.**

### Concurrency

`CVPixelBuffer`, `CMSampleBuffer` and `AVCapturePhoto` are not `Sendable`, and AVFoundation
delegate callbacks arrive on a private queue. Under Swift 6 strict concurrency, naive actor
wrapping produces either compiler fights or data races.

**Rule: buffers never escape the queue that owns them.** All pixel work happens on the capture
queue; only extracted value types cross the actor boundary — histogram bins, an HFD score, a
`Data` blob for the DNG, a `CGImage` thumbnail.

### Performance boundary

Histogram and HFD run per preview frame at up to 30 fps. They live on the **preview** path
(`AVCaptureVideoDataOutput`, frame-dropping enabled), structurally separate from the **photo** path
(`AVCapturePhotoOutput`). A slow metric can drop preview frames; it can never delay or corrupt a
session frame.

### Known risk: synthetic-driver fidelity drift
A fake that is too clean lets bugs hide until they meet real ProRAW. Mitigation: derive the
synthetic driver's noise, black level and hot-pixel parameters from the capability probe's real
measurements on the 17 Pro; and treat "works in the Simulator" as never sufficient evidence of
done.

---

## 5. Capability probe

**This is task zero.** It enumerates every `AVCaptureDevice` and, for each `AVCaptureDevice.Format`:
`minExposureDuration`, `maxExposureDuration`, ISO range, `supportedMaxPhotoDimensions`,
`videoFieldOfView`, plus `AVCapturePhotoOutput.isAppleProRAWSupported` and
`availableRawPhotoPixelFormatTypes`.

```swift
public struct DeviceCapabilities: Sendable, Codable {
    public let deviceModel: String        // "iPhone17,1"
    public let osVersion: String
    public let supportsAppleProRAW: Bool
    public let lenses: [LensCapability]
    public let probedAt: Date
}

public struct LensCapability: Sendable, Codable {
    public let deviceType: String         // AVCaptureDevice.DeviceType raw value
    public let localizedName: String
    public let focalLengthEquivalent: Int?
    public let formats: [FormatCapability]
}

public struct FormatCapability: Sendable, Codable {
    public let width, height: Int
    public let minExposureSeconds: Double
    public let maxExposureSeconds: Double
    public let minISO, maxISO: Float
    public let horizontalFieldOfViewDegrees: Float
    public let maxPhotoDimensions: [[Int]]
    public let rawPixelFormats: [String]  // OSType as FourCC
}
```

Output is written as JSON and exportable via the Files app. **Run on both the 17 Pro and the 15 Pro
and commit both profiles to the repo as test fixtures**, so §29 device adaptation is tested against
real data rather than hypotheticals.

---

## 6. Exposure model

AVFoundation's public API caps a single sensor exposure far below §4's 30 s ladder. Apple's Night
Mode obtains its "10 s" from a private computational stack, not a 10 s sensor read. §27 governs:
the app must never imply the sensor exposed longer than it did.

**The shutter ladder is built at runtime** from `min/maxExposureDuration` for the active format,
quantised to a conventional ladder (1/8000 … 1/2, 1 s, 2 s …) truncated at the hardware maximum.
§4's 30 s entry appears only if hardware genuinely offers it. *The design does not depend on what
the probe finds.*

Four separately-labelled quantities, never conflated in the UI:

```
Sensor Exposure      1.0 s     only ever a real hardware duration
Frames               60
Interval             0.05 s    inter-frame gap
Total Capture Time   63 s      wall clock = frames x (exposure + interval)
Effective Exposure   60 s      derived; always rendered as "60 x 1.0 s stacked"
```

```swift
public struct CapturePlan: Sendable, Codable {
    public var sensorExposure: Duration
    public var interval: Duration
    public var frameCount: Int

    public var effectiveExposure: Duration { sensorExposure * frameCount }
    public var totalCaptureTime: Duration { (sensorExposure + interval) * frameCount }
}
```

§6's "Total Capture Time" presets (10 s, 30 s, 1/2/5/10/20/30 min, Custom) are offered as a
*solver*: pick a total, and the app derives frame count from the current sensor exposure.

### Default capture format: 12 MP ProRAW, not 48 MP
On a quad-Bayer sensor, binned 12 MP collects roughly 4x the photons per output pixel and dilutes
read noise. For faint-signal astrophotography that is an SNR gain, not a compromise. It is also
~25 MB/frame against ~90 MB, so a 60-frame session is ~1.5 GB rather than ~5.4 GB. 48 MP remains
available in Expert mode for bright targets such as the Moon.

---

## 7. Capture loop

Per frame, in order:

1. Check `ProcessInfo.processInfo.thermalState`
2. Check storage headroom
3. **Start** a CoreMotion sampling window
4. Capture ProRAW frame
5. **Close** the sampling window and integrate RMS angular rate across exactly the exposure
   interval — stability describes the exposure it was measured over, so it can only be finalised
   after the frame completes
6. Stream the DNG straight to disk — **never accumulate frames in RAM** (§38)
7. Append one record to `frames.jsonl` (includes the measured byte count)
8. Write a small JPEG thumbnail
9. Emit progress; release all buffers

### Dark frames
The same capture path with `isDark: true`, writing to `darks/`. The UI instructs the user to cover
the lens and locks ISO/exposure to the light-frame settings. Slice 1 records them; Slice 2 uses
them.

---

## 8. Session format — the Slice 2 contract

```
Sessions/2026-08-26T00-43-12Z-milkyway/
├── session.json          settings, plan, device capabilities  (written once at start)
├── frames.jsonl          append-only, one JSON object per line
├── frames/frame_0001.dng
├── darks/dark_0001.dng
├── thumbs/frame_0001.jpg
├── capture.log           OSLog file sink for this session
└── completion.json       written ONLY on clean finish — its presence is the completion marker
```

`session.json` is written once at start and never mutated. Completion is signalled by the separate
`completion.json` (final frame count, accepted/flagged tallies, end timestamp). A session directory
without `completion.json` is by definition incomplete, which is exactly the condition the recovery
flow in §11 tests. No file is ever rewritten in place, so a crash can never corrupt existing state.

`frames.jsonl` is append-only **specifically** so an interrupted or crashed session is recoverable —
this is what makes §39's "42 of 60 frames captured -> PROCESS 42" possible. A trailing partial line
is discarded on read.

Per-frame record:

```json
{"index":1,"file":"frames/frame_0001.dng","capturedAt":"2026-08-26T00:43:14.221Z",
 "iso":1600,"exposureSeconds":1.0,"lensPosition":1.0,"whiteBalanceKelvin":3900,
 "bytes":26214400,"thermalState":"nominal",
 "stability":{"rmsAngularRateRadPerSec":0.0021,"predictedDriftPixels":0.41,"band":"excellent"},
 "flags":[],"isDark":false}
```

`flags` is a closed set — Slice 2 must be able to switch exhaustively over it:

| Flag | Meaning |
|---|---|
| `motion` | Stability band was `poor` for this exposure |
| `thermalPause` | A thermal pause began immediately after this frame |
| `sessionInterrupted` | Capture was interrupted at this frame (call, backgrounding) |
| `writeRetry` | The DNG write failed once and succeeded on retry |
| `settingsDrift` | Hardware reported settings differing from those requested |

Because this manifest is the contract Slice 2 consumes, it is deliberately over-specified now.
Getting it wrong means re-shooting sessions under real skies.

---

## 9. Metrics

### Histogram (§7, §23)
RGB + luminance, computed on the preview path with `vImageHistogramCalculation`. The **Astro
Histogram** variant applies a logarithmic or gamma-expanded x-axis to emphasise the lower luminance
range where astronomical information lives. Warnings: sky-background clipping, highlight clipping,
good exposure.

### Star sharpness — Half-Flux Diameter (§8, §9)
**HFD, not a generic contrast metric.** Contrast/Laplacian-variance measures plateau and grow noisy
near focus; HFD degrades smoothly and monotonically either side of focus, which is why real
astronomical autofocusers use it.

Algorithm, computed only over the magnified reticle region:
1. Estimate local background as the region median
2. Find the brightest local maximum above background + k·sigma
3. Compute the flux-weighted centroid
4. Find the radius containing half the total flux above background
5. HFD = 2 x that radius

Displayed as a 0–100% score normalised against the best HFD observed this session, so the user sees
a monotonic "turn until it peaks" signal.

### Stability (§30)
CoreMotion gyroscope, RMS angular rate integrated across each exposure window. Rather than magic
thresholds, bands are defined in **image-plane pixels**, which is what actually matters:

```
predictedDriftPixels = rmsAngularRate x exposureSeconds x (imageWidth / horizontalFOVradians)
```

| Band | Predicted drift |
|---|---|
| Excellent | < 0.5 px |
| Good | < 1.5 px |
| Poor | >= 1.5 px |

`horizontalFieldOfView` comes from the active `AVCaptureDevice.Format`, so this adapts across
lenses and devices without hardcoded constants.

**Frames are flagged, never discarded** (D11).

---

## 10. UI surface

Three tabs: **Camera | Sessions | Settings**.

### Camera
One screen, Simple <-> Expert disclosure.

- Full-bleed live preview
- **Top:** ISO, shutter, focus distance, WB, stability band, thermal state
- **Overlays** (toggleable): histogram, grid, focus peaking
- **Bottom:** control strip — EV, WB, FOCUS, ISO, SHUTTER, LENS; the capture plan readout
  (frames x exposure = effective); capture button
- **Expert adds** (§41): frame count, interval, RAW format (12/48 MP), dark-frame capture, capture-
  plan solver, raw capability inspector

During capture: frames N/M, elapsed, estimated remaining, running count of flagged frames, and a
STOP control that finalises the session cleanly.

### Focus loupe (§8, §9)
Tap to place a reticle; magnification 1x / 2x / 3x / 5x / 10x; live HFD score over the reticle
region only.

### Sessions
List of session directories with thumbnail, timestamp, settings summary, frame count, total size.
Detail view shows the manifest, per-frame flags, and the capture log. Export via share sheet.

### Settings
Capability probe report, storage usage, log level, synthetic-driver toggle (debug builds and
TestFlight, gated behind a switch rather than stripped).

---

## 11. Failure handling (§39)

| Condition | Behaviour |
|---|---|
| **Interrupt / crash / backgrounding** | Session dir and `frames.jsonl` are already on disk. On next launch, any session lacking a completion marker offers **Resume / Keep / Discard**. |
| **Thermal `.serious`** | Pause with a countdown; auto-resume at `.fair` or better. |
| **Thermal `.critical`** | Stop, finalise the session, keep all frames. |
| **Low storage** | Pre-flight estimate refuses to start a session that will not fit. Mid-session exhaustion aborts cleanly, keeping every frame already written. |
| **`AVCaptureSession.wasInterrupted`** | Phone call or app switch — pause, flag the boundary in the manifest, resume when possible. |

Storage pre-flight: `required = frameCount x measuredBytesPerFrame x 1.15 + 500 MB reserve`.
Bytes-per-frame is measured from the first captured frame, not assumed.

### Diagnostics — a TestFlight consequence
Distribution is TestFlight, not cable (D4), so there is **no debugger and no Xcode console during
real sessions**. Slice 1 therefore carries its own diagnostics: `OSLog` plus a file sink written to
`capture.log` inside each session directory, with an in-app log viewer and share-sheet export.
Without this, a failed 3 a.m. capture is unauditable.

### Getting data off the device
Also a TestFlight consequence: with no cable, ~1.5 GB of DNGs must still reach the Mac for Slice 2
development. The app sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` so session
directories appear in the Files app, plus AirDrop / iCloud export from the share sheet. **This is a
Slice 1 requirement, not a nicety** — Slice 2 is blocked without it.

### TestFlight housekeeping pulled forward
Real bundle identifier, App Store Connect app record, complete app icon set, auto-incrementing
build numbers, and an App Store Connect API key so `xcodebuild archive` -> upload can be scripted
without interactive login. Internal-tester TestFlight needs no Beta App Review, only an
export-compliance declaration.

---

## 12. Testing

### Mac unit tests (no device, no simulator)
- Session manifest round-trip encode/decode
- `frames.jsonl` recovery from deliberate mid-line truncation
- Shutter-ladder derivation from **both** real device capability fixtures
- Exposure arithmetic: effective exposure, total capture time, the plan solver
- Storage estimator boundary conditions
- HFD scoring against synthetic star images of known FWHM — monotonicity either side of focus
- Stability banding against recorded CoreMotion traces
- Capability-JSON decoding tolerant of unknown/missing fields

### Simulator tests (synthetic driver)
Full capture session end-to-end: plan -> capture -> manifest -> thumbnails -> completion, plus
injected failures (thermal escalation, storage exhaustion, mid-session interruption).

### Device tests (manual checklist, via TestFlight)
Capability probe on both devices; real ProRAW capture at 12 and 48 MP; focus loupe against real
stars; sustained thermal behaviour over a 30-minute session; Files-app export.

### Definition of done for Slice 1
A 30-frame ProRAW session captured on the iPhone 17 Pro under real sky, which:
1. survives an induced interruption with every written frame recovered,
2. exports off-device through the Files app, and
3. parses cleanly with the manifest validator that Slice 2 will reuse.

Simulator success alone never satisfies this.

---

## 13. Governing principle (§43)

**Enhance information that exists in the captured data; do not invent astronomical detail.**

No artificial stars, no fabricated Milky Way structure, no AI sky replacement. Images must remain
believable at 100% zoom. This constrains Slice 3 most directly, but Slice 1 carries the obligation
that makes it achievable: preserve the linear RAW data faithfully, and record honest metadata about
how it was captured.
