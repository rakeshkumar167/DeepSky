# Plan 2 Prerequisites — carried out of Slice 1 execution

These are obligations and known gaps recorded during Plan 1 (Capture Core) execution.
They are written here rather than left in the scratch ledger because the ledger is deleted
when the plan finishes, and every item below would otherwise have to be re-derived.

Plan 1 shipped at **86/86 tests passing**. Nothing here blocks Plan 1; everything here
blocks or shapes Plan 2.

---

## 1. ~~BLOCKING~~ RESOLVED 2026-08-26 — the HFD hot-pixel guard was a no-op on real sensor data

`Sources/DeepSkyMetrics/HalfFluxDiameter.swift` rejects hot/stuck pixels with:

```swift
guard litPixelCount >= 4 else { return nil }   // litPixelCount counts max(0, pixel - background) > 0
```

`background` is the patch **median**. By definition roughly half of any noisy patch lies
strictly above its own median — on a 64x64 patch that is ~2048 pixels, not 4. So the guard is
satisfied by noise alone, for a bare hot pixel exactly as readily as for a real star.

It only rejects the `rejectsSharpSinglePixelSpike` fixture because that fixture's background is
*exactly* flat (`repeating: 0.02`), making every non-spike residual exactly `0.0`. **That is a
property of the test fixture, not of the discriminator.**

Consequence if shipped into the focus loupe: a stuck pixel under the reticle computes a
tiny-radius HFD and reads as **perfect focus**, while the user's actual stars are out of focus.
Every frame of a 30-minute session is then unrecoverable. The failure is invisible until
someone is in a field at 3 a.m.

### The replacement rule, with numbers (do not re-derive)

1. Estimate background noise robustly from the patch itself (`measure` gets no calibration input):
   `sigma = 1.4826 * median(|patch[i] - background|)` — the standard MAD-to-sigma estimator.
   Floor it: `sigma' = max(sigma, 1e-6)` so perfectly flat synthetic fixtures do not divide by zero.
2. Guard: require **>= 4 pixels within Chebyshev distance 2 of the peak pixel** whose residual
   exceeds **5 * sigma'**.

Why those numbers:
- 5-sigma one-tailed is p ~ 2.9e-7. Scoping the count to the peak's neighbourhood (<= 24
  candidates rather than the full 4096-pixel patch) puts noise-driven false positives at
  ~24 * 2.9e-7 ~= 7e-6 per patch, so a stuck pixel in noise will not manufacture 4 qualifying
  neighbours by chance.
- Restricting to neighbours-of-peak also blocks scattered unrelated bright noise elsewhere in a
  large patch from satisfying a global count.

Behaviour against the cases that matter:
- **sigma=0.4 pixel-centred star:** nearest-neighbour amplitude ~= 0.044 * (peak - background), so it
  passes only when `(peak - background) / sigma' >~ 114`. That is a legitimate physical requirement,
  not an artificial one — a single-pixel signal claiming sigma=0.4 resolution against a noisy
  background genuinely is indistinguishable from a defect below that SNR.
- **Noise-free synthetic fixtures:** sigma' floors to epsilon, the threshold collapses toward 0, and
  every existing sigma/offset test case (0.4-3.0, offsets 0.0 and 0.5) still passes unmodified.
- **Single hot pixel, flat background:** neighbours are exactly 0; rejected, as today.
- **Single hot pixel, noisy background:** neighbours are ordinary noise measured against the same
  sigma; rejected — which today's implementation does NOT do.

**Add a noisy-background regression test at the same time**, or this gap silently returns.

### RESOLVED

Implemented as described. `HalfFluxDiameter` now estimates noise from the patch
(`sigma = 1.4826 * MAD`, floored at 1e-6) and requires >= 4 pixels within Chebyshev distance 2 of
the peak whose residual exceeds `5 * sigma`.

Verified by mutation test rather than assertion: with the old guard restored,
`rejectsHotPixelOnNoisyBackground` returns **47.12** instead of `nil` — so the new test genuinely
catches the defect. Worth noting the failure mode is not what the noise-free analysis predicted: on
a *flat* background the old code returned 0.0 ("perfect focus"), but on a *noisy* one the noise
dominates total flux across the patch and it returns a large meaningless number instead. Both are
wrong in the same way that matters — a focus reading for a patch containing no star.

Four regression tests added (`rejectsHotPixelOnNoisyBackground`, `acceptsRealStarOnNoisyBackground`,
`noiseEstimateTracksActualNoiseLevel`, `noiseEstimateFloorsOnAPerfectlyFlatPatch`). Suite: 90 tests.

## 2. BLOCKING — `LuminancePatch.init` traps at the live-buffer boundary

`LuminancePatch.init` uses `precondition(pixels.count == width * height)`. That is correct
fail-fast behaviour for a programmer error, and was deliberately kept for Plan 1 where nothing
feeds it live data.

The moment Plan 2 feeds it slices of a real capture buffer, an off-by-one in stride or crop
becomes a **hard crash of the capture pipeline mid-session** rather than a dropped frame.
Convert to a failable or throwing initialiser at that integration point, or validate at the call
site. Treat this as a hard prerequisite of the AVFoundation work, not a cleanup item.

## 3. Contract changes Plan 2's capability probe MUST match

- `SessionStore` now encodes and decodes dates as **ISO-8601** (`.iso8601` on the encoder and on
  both decoders, including the local one inside `readFrames`). The probe that writes
  `DeviceCapabilities` JSON on real hardware must use the same strategy, or `session.json` and the
  committed device fixtures will disagree.
- `CaptureSettings` **moved from `DeepSkyCapture` into `DeepSkyCore`** so `SessionManifest` can
  persist it. `SessionManifest` now carries `settings: CaptureSettings`.
- `SessionStore.create` sanitises the session name to `[a-z0-9-]`. Directory names are no longer a
  verbatim echo of user input.

## 4. Deferred from Plan 1 by design (not defects)

- **`previewFrames()`** is absent from `CameraDevice`. Plan 2 widens the protocol; `SyntheticDriver`
  gains a conforming implementation at the same time.
- **Histogram** (RGB / luminance / astro) is not built. It consumes live preview buffers via
  `vImageHistogramCalculation`; building it against synthetic float arrays would test a shape the
  device never produces.
- **No format selector.** `CaptureSettings` has no 12 MP / 48 MP choice, and the coordinator always
  takes `formats.first`. Spec §6's default-to-12MP decision has no representation in the model yet.
  Adding it changes the `session.json` contract again — do it before shooting sessions worth keeping.

## 5. Known Minor gaps worth knowing

- **`.pause` marks a session complete.** A thermally-paused session gets `completion.json` written and
  can never be resumed; `run()` has no resume entry point (`create()` always mints a new directory).
  Spec §11 requires "pause with a countdown; auto-resume at `.fair` or better" — Plan 2 needs both
  the countdown and a resume path.
- **Four of five `FrameFlag` cases are never produced.** Only `.motion` is set. `.thermalPause` is
  producible today (the `.pause` arm exits without flagging the preceding frame). `.sessionInterrupted`,
  `.writeRetry`, `.settingsDrift` need Plan 2 machinery. Slice 2 fixtures generated from this branch
  therefore exercise exactly one flag.
- **`thermalState()` is read twice per capture iteration** — once for the policy decision, once when
  building `FrameRecord` — so a frame's recorded thermal state can differ from the one its decision
  was made on. Read once, use twice.
- **Two sources of truth for capabilities.** The coordinator validates `lensIndex` and derives the
  format from `manifest.capabilities`, while the camera validates against its own `capabilities`. If
  they diverge, `predictedDriftPixels` is computed against a field of view the camera is not using —
  silently. Consider deriving the format from `await camera.capabilities`.
- **A degenerate FOV yields `predictedDriftPixels == 0.0` paired with `band == .poor`** — internally
  contradictory in the manifest. Slice 2 reading `drift: 0.0, band: "poor"` cannot tell the format
  was malformed.
- **`SyntheticDriver.apply` validates only upper bounds** of exposure and ISO; a below-hardware-minimum
  request is silently accepted, which is asymmetric with the honesty principle the shutter ladder
  enforces.
- **Byte-level truncation of `frames.jsonl` is only safe while records stay ASCII.** Recovery reads the
  file as a UTF-8 `String`; a truncation splitting a multi-byte sequence would make that read fail and
  lose *everything*. Records are currently pure ASCII, so this is unreachable — it becomes reachable
  the moment any non-ASCII string (e.g. a user-supplied session name) enters a `FrameRecord`.
- Cosmetic: a dead `private let decoder: JSONDecoder` remains in `SessionStore`; three vestigial
  comment-only placeholder test files remain; `excellentPixels`/`goodPixels` are internal rather than
  private.

## 6. Architectural deviation, recorded

`Package.swift` gives `DeepSkySession` dependencies on `DeepSkyCapture` **and** `DeepSkyMetrics`,
which contradicts spec §4 ("Capture, Metrics, Session depend only on Core") and the plan's own
Global Constraints — the plan then overrides itself at Task 12. The graph stays acyclic, so this is
a deviation rather than a defect, but note that Task 1's "verify the dependency rule holds" check
only tests for *external* dependencies and would not catch future drift either.

## 7. Real device profiles — what the hardware actually reports

Two profiles are committed under
`Packages/DeepSkyKit/Tests/DeepSkyCoreTests/Fixtures/` and asserted against in
`RealDeviceProfileTests`. Captured 2026-08-26 with the in-app probe.

| | iPhone 15 Pro (iPhone16,1) | iPhone 17 Pro (iPhone18,1) |
|---|---|---|
| iOS | 26.6 | 26.6.1 |
| Formats | 183 | 196 |
| **Max sensor exposure** | **1.000000 s** | **1.000000 s** |
| Ultra-wide ISO | 32–3072 | 15–3600 |
| Wide ISO | 55–12320 | 54–12096 |
| Telephoto ISO | 18–2304 | **15–7680** |
| Telephoto FOV | 22.2–26.4° | **16.6–19.9°** |
| 48MP | wide only | **all three lenses** |
| ProRAW (`l64r`) | all lenses | all lenses |
| Bayer | `bgg4` wide, `rgg4` others | `bgg4` wide, `rgg4` others |

**The exposure ceiling is 1.000000 s on both devices, across all 379 format
entries between them, with zero variation.** Two generations of sensor and
silicon reporting an identical value is strong evidence of a platform-wide
AVFoundation limit rather than a device characteristic. The requirements
document's 30-second shutter is not achievable as a single sensor read, so the
runtime-derived ladder and the stacking-first architecture are confirmed by
hardware rather than argued from inference.

### Consequences for Plan 2

- **48MP cannot be a global mode.** Wide-only on the 15 Pro, every lens on the
  17 Pro. A UI built against either device alone would be wrong on the other.
- **Field of view varies per format within a lens** (wide: 64.9–74.6° on both).
  `StabilityEstimator` reading FOV per-format rather than per-lens is required,
  not fastidious — a per-lens constant mis-bands drift by up to ~15%.
- **The 17 Pro telephoto is a viable astro lens; the 15 Pro's is not.** 7680 vs
  2304 max ISO is a 3.3× difference in headroom at a narrower field of view.
- **Bayer pattern differs by sensor within a single device**, so the demosaic
  path cannot assume one pattern.

### Known inaccuracy in the probe

`focalLengthEquivalent` is derived from `videoFieldOfView`, which describes the
*video* crop — narrower than the full still frame. It therefore reads ~8% long
against Apple's marketing figures (15/26/84mm vs 13/24/77mm on the 15 Pro;
15/26/113mm on the 17 Pro). The numbers are honestly derived from what the
hardware reports, but they are not the published focal lengths. If the UI shows
focal length to users, either correct for the still-frame crop or drop the
derivation and map `deviceType` to nominal values.
