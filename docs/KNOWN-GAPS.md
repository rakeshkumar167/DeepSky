# Known gaps

Live defects and unbuilt work, recorded so they are not rediscovered from
scratch. Slice-1 era items live in `superpowers/plans/PLAN-2-PREREQUISITES.md`;
this file covers what is outstanding after the MVP processing work.

Last reviewed 2026-08-27.

---

## 1. DEFECT — two readouts on the camera screen are fabricated

Spec §43 is explicit: *"Enhance information that exists in the captured data;
do not invent astronomical detail."* Two on-screen numbers currently violate it,
and the live camera preview made them worse — they now sit beside a real feed,
which is precisely what makes them read as measurements.

### 1a. The histogram is a hardcoded constant

`App/CaptureViews.swift` — `HistogramStrip`:

```swift
private let bins: [Double] = [0.95, 0.72, 0.48, 0.30, 0.19, 0.12, 0.08, 0.05,
                              0.04, 0.03, 0.02, 0.02, 0.01, 0.01, 0.01, 0.02]
```

It never reads a pixel. It does not change between scenes, between exposures,
or between devices. Its accessibility label goes further and asserts a
conclusion — "signal concentrated in shadows, no clipping" — about an image it
has never seen.

Spec §23 wants an RGB and luminance histogram plus clipping warnings, and an
astro histogram emphasising the low end. None of that exists.

**Why it is still here:** it needs live preview buffers, which did not exist
when the screen was built. They do now — `AVCaptureDriver` owns a running
session (`previewSession`), so a `AVCaptureVideoDataOutput` can be added to it.

**Fix:** add a video-data output, compute real bins (`vImageHistogramCalculation`
or a plain pass over the buffer), and drive the strip from those. Until then it
should either be removed or labelled as a placeholder the way the live view was.

### 1b. Star sharpness is a function of the focus slider

`App/CameraScreen.swift`:

```swift
private var sharpness: Double { 0.62 + model.lensPosition * 0.36 }
```

This is arithmetic on the slider position presented as a focus measurement.
Move the slider, the "sharpness" moves — always in the same direction,
regardless of what the camera is pointed at. A user focusing by this number is
being misled in the exact situation the feature exists to help with.

**The measurement itself is already built and tested.**
`DeepSkyMetrics/HalfFluxDiameter` computes real HFD, has a working hot-pixel
guard (see PLAN-2-PREREQUISITES §1), and is never fed a real pixel.

**Fix:** same prerequisite as 1a — a preview buffer path. Feed the loupe's patch
to `HalfFluxDiameter.measure` and show the real figure. `LuminancePatch` is
already failable rather than trapping, so live buffer slicing is safe.

---

## 2. Processing runs at 1024px, not the sensor's 12MP

`StackPipeline.run(frameURLs:maxDimension:)` is called with 1024 everywhere.
That is a >15× reduction in pixel area before the step that is supposed to
recover detail, and exported images inherit it — the export screen states the
size rather than hiding it.

**Fix, which is mostly bookkeeping rather than new algorithms:** keep the
downscale for the alignment correlation, where it is genuinely enough, scale
the resulting integer offset back up, and run the decode/shift/accumulate at
native resolution. Memory stays flat because the stacker is a running mean, but
each frame's decode grows to ~36MB of float per plane, so the RGB path needs
checking against a real device budget before this ships.

---

## 3. No calibration stage — fixed-pattern noise is the stretch ceiling

Spec §14 lists a seven-stage noise-reduction chain; only frame stacking exists.
§15 (hot pixel removal) and §16 (dark-frame calibration) are unbuilt.

This matters more now than it did before the midtones stretch landed. Hot
pixels, amp glow and fixed-pattern read noise are *identical in every frame*, so
averaging cannot remove them — and the more the stack's random noise falls, the
closer the black point sits to the background, and the more those fixed defects
stand out. Better stacking makes this worse, not better.

**Fix, cheapest first:** a bad-pixel map derived statistically from the burst
itself (a pixel that is an outlier at the same sensor coordinate in every frame
is a defect, not sky) needs no extra capture. A real master dark needs a
capture flow with the lens covered — that is §16 and is V2 by the spec's own
staging.

---

## 4. Gradient removal is unvalidated, and one hypothesis was already wrong

`ColourRender.GradientMode` defaults to `.perChannel`. Measured chroma spread on
the only real session available (indoor, not sky):

```
off 0.1413    achromatic 0.1974    per-channel 0.1928
```

The first hypothesis — that per-channel fitting invents colour — is **falsified**
by that table: a common achromatic surface produces just as much. The likelier
explanation is that flattening lets the stretch push harder into previously
compressed regions, amplifying colour that was genuinely there.

It cannot be settled indoors, where the "gradient" is a lamp on a wall: real
scene content this step is right to leave alone. **Needs a night-sky session.**

---

## 5. `.pause` writes `completion.json`, so a paused session can never resume

`CaptureCoordinator` treats a thermal `.pause` as end-of-session and finalises
it. Spec §11 requires a countdown and auto-resume at `.fair` or better; §39
requires the recovery flow. `SessionStore.create` always mints a new directory,
so there is no resume entry point at all.

Note the newer `interrupted` flag on `SessionCompletion` covers a *different*
case — the camera being revoked when the app backgrounds — and does not address
this one.

---

## 6. Smaller, recorded

- **`focalLengthEquivalent` reads ~8% long.** Derived from `videoFieldOfView`,
  which describes the video crop. Fine internally; wrong if ever shown to users.
- **No 12MP/48MP selector** (spec §28). 48MP is wide-only on the 15 Pro but
  available on all three lenses on the 17 Pro, so this cannot be a global mode.
- **Manual ISO and shutter have no UI** (spec §44.1–2). `AstroPreset` derives
  them and `CaptureSettings` carries them; nothing lets the user override.
- **Star enhancement** (§19), **digital magnification** (§9), **processing
  presets** (§25), **editing** (§34/§35) and **expert mode** (§41) are unbuilt.
- **`thumbs/` is never written** despite being created in every session folder.
- **Sigma-clipped stacking** is still a plain mean; see `FrameStacker`'s note.
  Winsorised clipping is the recommended form below ~10 frames.
