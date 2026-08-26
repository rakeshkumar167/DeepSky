# DeepSky MVP — Capture, Stack, Export

**Date:** 2026-08-27
**Status:** Design approved. Ready for implementation planning.
**Builds on:** `2026-08-26-deepsky-slice1-capture-design.md` (Slice 1, merged)
**Prerequisites carried in:** `docs/superpowers/plans/PLAN-2-PREREQUISITES.md`

---

## 1. What the MVP is

Capture a burst of ProRAW frames of the night sky, stack them on device, recover
the tone, and export — producing a visibly and **measurably** better image than a
single RAW frame from the same phone.

### The fact that rewrites the original MVP

`requirements.txt` §44 lists thirteen MVP items, written before we knew what the
hardware does. The capability probe settled it on two real devices:

```
maxExposureSeconds = 1.000000
```

Exactly one second. All 379 format entries across an iPhone 15 Pro and an
iPhone 17 Pro, zero variation. **There is therefore no "long exposure" MVP.**
Every astro shot is a stack; an app without stacking produces a one-second
photo. Stacking is not an advanced feature to reach for later — it is the
minimum viable product.

### Success bar (decided)

**Beat a single RAW frame**, not stock Night mode.

This is deliberate. Night mode already performs aligned multi-frame stacking up
to 30s, so out-gathering it requires star alignment — roughly half the remaining
work and the hardest algorithm in the project. The MVP instead competes where it
can win honestly: **ProRAW output, user-controlled integration, and no
destructive smoothing**. Positioning is "RAW and natural", never "brighter than
Night mode".

### Scope decided

| In | Out |
|---|---|
| Real ProRAW burst capture | Star alignment |
| Astro preset (lens, shutter, ISO, frame ceiling) | Full manual controls (§41 Expert) |
| Manual focus + loupe + live HFD | Star trails, sky/ground separation |
| Unaligned mean stack | Dark frames, light-pollution removal |
| Tone recovery | Milky Way / star enhancement |
| Before/after comparison | Celestial compass, planner |
| Export processed image + keep DNGs | 48 MP, session resume UI |

### Why no alignment, and what bounds it

Stars trail across the **stack**, not within a frame — an unaligned stack behaves
like one long exposure for trailing purposes. The 500-rule gives roughly
`500 / focalLengthEquivalent` seconds before trailing shows. Since each frame is
1.0s, that is also the frame ceiling:

| Lens | Focal (derived) | Max frames |
|---|---|---|
| Ultra Wide | 15mm | ~33 |
| Wide | 26mm | ~19 |
| Telephoto | 84mm (15 Pro) / 113mm (17 Pro) | ~6 / ~4 |

The app **structurally cannot** stack into visible trailing, and the limit
explains itself rather than being a magic constant.

Note the ceiling is deliberately conservative: `focalLengthEquivalent` is derived
from `videoFieldOfView`, which reads ~8% long against Apple's published focal
lengths (26mm vs 24mm on the wide). A longer assumed focal yields *fewer* frames,
so the inaccuracy errs toward round stars rather than trailed ones. If the
derivation is corrected later, the ceiling rises slightly — it should not be
corrected without re-checking trailing on a real sky.

At 19 frames the expected noise improvement is √19 ≈ **4.4×**.

---

## 2. Architecture

Most of this is substitution, not new construction. Slice 1's seam is why.

```
DeepSkyCore          + AstroPreset          pure: capabilities + light -> CaptureSettings
DeepSkyAVCapture     + AVCaptureDriver      iOS only; conforms to existing CameraDevice
DeepSkyProcessing    NEW                    RAWDecoder | FrameStacker | ToneMapper
App                  capture flow, result view, before/after
```

**`CaptureCoordinator` does not change.** It already drives sessions, applies
capture policy, senses the environment, flags frames and persists everything,
with 99 tests behind it. The MVP swaps `SyntheticDriver` for `AVCaptureDriver`
behind the same actor protocol.

**`DeepSkyProcessing` stays platform-agnostic.** Core Image and Metal run on
macOS and `CIRAWFilter` decodes DNGs there, so the stacker is testable on the Mac
against real DNGs pulled off the phone. Only `AVCaptureDriver` is iOS-only. This
is the same discipline that made Slice 1 work.

**`AstroPreset` is pure logic in Core**, so it is unit-testable against the two
committed real-hardware profiles rather than against assumptions.

### Data flow

```
capabilities -> AstroPreset -> CaptureSettings
                                    |
             AVCaptureDriver -> CaptureCoordinator -> session/ on disk
                                                           |
                         RAWDecoder -> FrameStacker -> ToneMapper
                                                           |
                                             stacked result + export
```

The pipeline reads **from the session directory**, not from memory. Capture and
processing stay decoupled, so a session can be reprocessed later with different
settings — which is what makes §35's non-destructive editing achievable without
designing for it now.

---

## 3. Capture

### AVCaptureDriver

Conforms to the existing `CameraDevice` actor protocol. Configures an
`AVCaptureSession` with the chosen device and an `AVCapturePhotoOutput` with
`isAppleProRAWEnabled`; locks exposure via `setExposureModeCustom(duration:iso:)`,
focus via `setFocusModeLocked(lensPosition:)`, and white balance; then
`capturePhoto` per frame.

**Concurrency rule, now load-bearing.** `AVCapturePhoto` is not `Sendable`. The
delegate callback extracts `photo.fileDataRepresentation()` on the capture queue
and **only `Data` crosses the actor boundary**. Buffers never escape the queue
that owns them. This was a design note in Slice 1; here it is the difference
between compiling and fighting the compiler.

### AstroPreset

Every rule derives from probed capability data:

- **Lens: wide.** Not a preference — the real profiles show 12320 / 12096 max ISO
  on the wide against 3072 and 2304 on the others. It is decisively the light
  bucket.
- **Shutter: the active format's reported `maxExposureSeconds`.** 1.0s on both
  test devices, but read at runtime, never hardcoded.
- **ISO: metered, then capped.** Let auto-exposure settle, read the chosen `iso`
  and `exposureDuration`, scale to the fixed 1.0s shutter
  (`ISO_target = iso × duration / 1.0`), clamp to the format's range. On a dark
  sky AE is already pinned at its limits, which correctly yields "max ISO at one
  second".
- **Frame ceiling:** `500 / focalLengthEquivalent`, per the table above.
- **White balance:** fixed 3900K (spec §21's astro-neutral range).

**One value is a guess, not a derivation.** `AstroPreset` caps ISO at **6400**
even where the sensor offers 12320, on the conventional reasoning that past some
point noise grows faster than signal. This is not measured on these sensors. It
ships as a named constant with the reasoning attached and is **the first thing to
validate on a real sky** — 12320 may stack better than expected.

---

## 4. Processing

### Decode

`CIRAWFilter` per DNG with `boostAmount = 0`, gamut mapping disabled, into a
linear working space. Apple handles black level, demosaic and white balance —
precisely the parts that are tedious to get right and easy to get subtly wrong.

**Named risk:** `CIRAWFilter` output is not guaranteed sensor-linear; it may
apply a tone curve. Averaging remains valid either way, but the noise statistics
differ. The √N verification in §6 is what detects this.

### Stack

A Metal kernel accumulates into a single float texture: decode, add, discard. **Memory
stays flat at one accumulator regardless of frame count**, satisfying §38.

**Deliberate deviation from spec §11.** The spec's default is weighted
sigma-clipped stacking; the MVP ships a **plain mean**. Sigma clipping requires
either two passes over the frames or running variance, and its principal benefit
is rejecting satellite and aircraft trails. Across 19 frames an unrejected trail
lands at 1/19 intensity — faint, and arguably an honest record of what crossed
the sky. Sigma clipping is the first fast-follow after the MVP.

### Tone

A fixed, ordered chain — no adaptive behaviour in the MVP:

1. **Black point:** subtract the 0.1st-percentile level so the sky background
   sits just above zero rather than crushed to it. Crushing loses the faintest
   real signal, which is the opposite of the point.
2. **Exposure recovery:** linear gain chosen so the sky background lands at
   roughly 10–15% of full scale, which is where astrophotographers conventionally
   place it — dark, but with the faint end lifted off the floor.
3. **Curve:** a single fixed sRGB-style transfer. Not adaptive, not per-image,
   so two sessions of the same target are comparable.

**No noise reduction whatsoever.**
Stacking *is* the noise reduction, and §43's "believable at 100%" is easier to
honour by not smoothing than by smoothing carefully.

### No alignment means the tripod matters

Slice 1's stability sensing already flags frames. Those flags now earn their
keep: a session where most frames carry the `motion` flag must **warn** rather
than silently produce a smeared stack.

---

## 5. UI

Mostly wiring the shell already built and previewed on device.

- **Capture screen:** mock state replaced by `AstroPreset` and the real driver.
  Manual focus with the loupe bound to live HFD. Frame-count slider bounded by
  the derived ceiling. Everything else preset.
- **Progress:** binds to the real `CaptureCoordinator`.
- **Result screen (new):** the stacked image with a **before/after toggle** —
  one frame against the stack, **both tone-mapped identically** so the comparison
  is honest rather than flattering.
- **Export:** processed image plus the original DNGs, via the Files-app path
  already configured.

Night mode, true-black surfaces, tabular figures and the 84pt capture button all
carry over unchanged.

---

## 6. How we prove it worked

> Measure noise σ over the **same fixed region** on a single frame and on the
> N-frame stack. If stacking works on genuinely linear data:
>
> **σ_stack ≈ σ_single / √N**

**The region is defined, not eyeballed.** Take a 256×256 patch whose median is
closest to the frame's overall median — that lands on background sky rather than
on a star or the horizon — and exclude the brightest 1% of its pixels so a stray
star cannot dominate σ. The same pixel coordinates are used for both
measurements, since comparing different regions would measure scene variation
rather than noise. Tolerance: measured improvement within **±15%** of √N counts
as confirmation.

A number, not an impression. At 19 frames it predicts **4.4×**. Measuring 4.4×
means the pipeline is correct and the data is linear enough. Measuring ~2× means
something upstream is applying a curve, and points directly at the decode stage.

This runs on the **Mac against real DNGs**, so iteration is fast.

### Definition of done

A real night-sky session captured on the iPhone 15 Pro and stacked on device,
where:

1. the √N noise reduction is **verified numerically**,
2. the before/after is **visibly** better, and
3. both the DNGs and the processed image export off the device.

### Testing split

- **Mac:** `AstroPreset` against both real device fixtures; the stacker against
  synthetic frames of known noise asserting √N; the stacker against real DNGs
  once shot; tone mapping determinism.
- **Device:** `AVCaptureDriver` behaviour, and the end-to-end run.

---

## 7. Error handling

Thermal, storage and interruption are already handled by `CapturePolicy` and
`CaptureCoordinator` and need no new work. New surfaces:

| Condition | Behaviour |
|---|---|
| Camera access denied | Explain and link to Settings; no silent failure. |
| `AVCaptureSession` interrupted mid-burst | Flag the frame boundary, keep every frame written, finalise the session. |
| Most frames flagged `motion` | Warn before stacking — the result will be smeared and the user should know why. |
| Decode failure on a frame | Skip that frame, record it, continue. One bad DNG must not lose the session. |
| Stack produces no usable result | Session and DNGs are retained; processing is retryable. Capture output is never discarded on a processing failure. |

---

## 8. Prerequisites from Slice 1 that this must clear

From `PLAN-2-PREREQUISITES.md`:

1. **`LuminancePatch.init` traps via `precondition` on a size mismatch.** Correct
   while nothing feeds it live data; a crash vector the moment capture-buffer
   slices reach the loupe. Convert to a failable or throwing initialiser at that
   integration point — a hard prerequisite of this work, not a cleanup item.
2. The HFD hot-pixel guard was already fixed (noise-aware, MAD-derived).

---

## 9. Governing principle (§43)

**Enhance information that exists in the captured data; do not invent
astronomical detail.**

The MVP honours this mostly by omission: no noise reduction, no enhancement, no
sharpening. Stacking adds real signal; tone recovery reveals what was already
captured. Nothing in this scope manufactures detail.
