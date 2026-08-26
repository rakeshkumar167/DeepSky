# DeepSky MVP — Plan B: Processing Pipeline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a captured session of ProRAW frames into a single stacked, tone-recovered image that measurably beats one frame — and prove it with a number rather than an impression.

**Architecture:** A new platform-agnostic `DeepSkyProcessing` target: `RAWDecoder` (Core Image), `FrameStacker` (running mean over decoded frames), `ToneMapper` (fixed chain), and `StackPipeline` orchestrating session-on-disk to result. Everything except the final UI runs on macOS, so the pipeline is developed and verified against real DNGs on the Mac with no device time.

**Tech Stack:** Swift 6.2.4 (strict concurrency), Core Image, Accelerate, Swift Testing. Xcode 26.3 / iOS SDK 26.2.

**Spec:** `docs/superpowers/specs/2026-08-27-deepsky-mvp-design.md`

## Global Constraints

- **Swift 6 language mode, strict concurrency.** Every public type crossing a boundary is `Sendable`.
- **`DeepSkyProcessing` must build for macOS AND iOS.** No `#if os(iOS)` guards around the pipeline — that platform-agnosticism is what makes it testable without a phone.
- **No AVFoundation in `DeepSkyProcessing`.** It reads DNG bytes from disk; it never touches a camera.
- **No noise reduction, no sharpening, no enhancement.** Stacking is the noise reduction. Spec §43: enhance what exists, invent nothing.
- **Memory stays flat.** Decode a frame, add it, discard it. Never hold N frames at once (spec §38).
- **Never read sensor limits from `formats.first`** — use `LensCapability.captureFormat`. Reading the preview format understated drift 20× and would have rejected legitimate dark-sky ISO.
- **Test framework is Swift Testing** (`@Test`, `#expect`), not XCTest.
- Run Mac tests: `swift test --package-path Packages/DeepSkyKit`
- Real DNGs for manual verification live at `~/Downloads/2026-08-26T190656Z-astro-*/frames/`. They are ~19 MB each and are **never committed**.

---

### Task 1: `NoiseMeasurement` — the yardstick

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyProcessing/NoiseMeasurement.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkyProcessing/FloatImage.swift`
- Modify: `Packages/DeepSkyKit/Package.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyProcessingTests/NoiseMeasurementTests.swift`

**Interfaces:**
- Produces:
  - `public struct FloatImage: Sendable` — `init?(width: Int, height: Int, pixels: [Float])`, `width`, `height`, `pixels`, `subscript(x:y:)`
  - `public enum NoiseMeasurement` — `static func standardDeviation(_ image: FloatImage, in region: PatchRegion) -> Double`, `static func backgroundRegion(_ image: FloatImage, size: Int) -> PatchRegion?`
  - `public struct PatchRegion: Sendable, Hashable` — `x`, `y`, `width`, `height`

This comes first because it is how every later task is judged. Spec §6 defines success as σ_stack ≈ σ_single / √N over **the same fixed region**, with the brightest 1% excluded so a stray star cannot dominate.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import DeepSkyProcessing

private func noisyImage(size: Int, level: Float, sigma: Double, seed: UInt64) -> FloatImage {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407 | 1
    func nextUnit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    func gaussian() -> Double {
        let u1 = max(nextUnit(), 1e-12), u2 = nextUnit()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    let pixels = (0..<(size * size)).map { _ in level + Float(gaussian()) }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

@Test func measuresKnownNoiseAccurately() {
    let image = noisyImage(size: 128, level: 0.2, sigma: 0.01, seed: 42)
    let region = PatchRegion(x: 0, y: 0, width: 128, height: 128)
    let measured = NoiseMeasurement.standardDeviation(image, in: region)
    #expect(abs(measured - 0.01) / 0.01 < 0.10)   // within 10% of truth
}

@Test func excludesTheBrightestPixelsSoAStarCannotDominate() {
    var pixels = [Float](repeating: 0.2, count: 64 * 64)
    // A handful of very bright pixels: a star, not noise.
    for i in 0..<40 { pixels[i] = 5.0 }
    let image = FloatImage(width: 64, height: 64, pixels: pixels)!
    let region = PatchRegion(x: 0, y: 0, width: 64, height: 64)
    // With outliers excluded the field is constant, so sigma is ~0.
    #expect(NoiseMeasurement.standardDeviation(image, in: region) < 0.01)
}

@Test func backgroundRegionAvoidsTheBrightestArea() {
    var pixels = [Float](repeating: 0.1, count: 256 * 256)
    // A bright blob in the top-left quadrant.
    for y in 0..<64 { for x in 0..<64 { pixels[y * 256 + x] = 3.0 } }
    let image = FloatImage(width: 256, height: 256, pixels: pixels)!
    let region = try! #require(NoiseMeasurement.backgroundRegion(image, size: 64))
    // The chosen region must not sit inside the blob.
    #expect(!(region.x < 64 && region.y < 64))
}

@Test func rejectsAnOutOfBoundsRegion() {
    let image = FloatImage(width: 32, height: 32, pixels: [Float](repeating: 0.5, count: 1024))!
    let outside = PatchRegion(x: 20, y: 20, width: 40, height: 40)
    #expect(NoiseMeasurement.standardDeviation(image, in: outside) == 0)
}

@Test func floatImageRejectsMismatchedPixelCount() {
    #expect(FloatImage(width: 4, height: 4, pixels: [Float](repeating: 0, count: 15)) == nil)
    #expect(FloatImage(width: 0, height: 0, pixels: []) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter NoiseMeasurementTests`
Expected: FAIL — the `DeepSkyProcessing` target does not exist.

- [ ] **Step 3: Add the target to Package.swift**

```swift
        .library(name: "DeepSkyProcessing", targets: ["DeepSkyProcessing"]),
```
and
```swift
        .target(name: "DeepSkyProcessing", dependencies: ["DeepSkyCore"]),
        .testTarget(name: "DeepSkyProcessingTests",
                    dependencies: ["DeepSkyProcessing", "DeepSkyCore"]),
```

- [ ] **Step 4: Write minimal implementation**

`FloatImage.swift`:
```swift
import Foundation

/// A single-channel float image. Deliberately not tied to Core Image so the
/// measurement and stacking maths stay testable without any imaging framework.
public struct FloatImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init?(width: Int, height: Int, pixels: [Float]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Float { pixels[y * width + x] }
}
```

`NoiseMeasurement.swift`:
```swift
import Foundation

public struct PatchRegion: Sendable, Hashable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Measures background noise, which is how the whole pipeline is judged:
/// stacking N frames must reduce sigma by about sqrt(N) (spec §6).
public enum NoiseMeasurement {
    /// Fraction of the brightest pixels discarded before measuring, so a star
    /// inside the region cannot masquerade as noise.
    static let outlierFraction = 0.01

    public static func standardDeviation(_ image: FloatImage, in region: PatchRegion) -> Double {
        guard region.x >= 0, region.y >= 0,
              region.width > 0, region.height > 0,
              region.x + region.width <= image.width,
              region.y + region.height <= image.height else { return 0 }

        var values = [Double]()
        values.reserveCapacity(region.width * region.height)
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) {
                values.append(Double(image[x, y]))
            }
        }
        guard values.count > 1 else { return 0 }

        values.sort()
        let drop = Int(Double(values.count) * outlierFraction)
        let kept = drop > 0 ? Array(values[0..<(values.count - drop)]) : values
        guard kept.count > 1 else { return 0 }

        let mean = kept.reduce(0, +) / Double(kept.count)
        let variance = kept.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(kept.count - 1)
        return variance.squareRoot()
    }

    /// Picks the `size`x`size` region whose median is closest to the image's
    /// own median — background sky rather than a star or the horizon. Sampled
    /// on a coarse grid because scanning every offset of a 12MP frame is
    /// needlessly slow for a measurement that only needs to land on sky.
    public static func backgroundRegion(_ image: FloatImage, size: Int) -> PatchRegion? {
        guard size > 0, image.width >= size, image.height >= size else { return nil }

        var all = image.pixels.map(Double.init)
        all.sort()
        let imageMedian = all[all.count / 2]

        let step = max(size / 2, 1)
        var best: (region: PatchRegion, distance: Double)?

        for y in stride(from: 0, through: image.height - size, by: step) {
            for x in stride(from: 0, through: image.width - size, by: step) {
                var sample = [Double]()
                sample.reserveCapacity(size * size)
                for yy in y..<(y + size) {
                    for xx in x..<(x + size) { sample.append(Double(image[xx, yy])) }
                }
                sample.sort()
                let distance = abs(sample[sample.count / 2] - imageMedian)
                let region = PatchRegion(x: x, y: y, width: size, height: size)
                if best == nil || distance < best!.distance { best = (region, distance) }
            }
        }
        return best?.region
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter NoiseMeasurementTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add noise measurement, the pipeline's yardstick"
```

---

### Task 2: `FrameStacker` — and the √N proof

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyProcessing/FrameStacker.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyProcessingTests/FrameStackerTests.swift`

**Interfaces:**
- Consumes: `FloatImage`, `NoiseMeasurement`, `PatchRegion`
- Produces: `public struct FrameStacker: Sendable` — `init(width: Int, height: Int)`, `mutating func add(_ image: FloatImage) -> Bool`, `var frameCount: Int`, `func result() -> FloatImage?`

Memory stays flat: one accumulator, frames added and discarded. This is the component the entire MVP thesis rests on.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import DeepSkyProcessing

private struct Noise {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 | 1 }
    mutating func unit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

private func frame(size: Int, level: Float, sigma: Double, noise: inout Noise) -> FloatImage {
    let pixels = (0..<(size * size)).map { _ in level + Float(noise.gaussian(sigma)) }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

@Test func meanOfIdenticalFramesIsUnchanged() {
    let flat = FloatImage(width: 8, height: 8, pixels: [Float](repeating: 0.5, count: 64))!
    var stacker = FrameStacker(width: 8, height: 8)
    for _ in 0..<10 { #expect(stacker.add(flat)) }
    let result = try! #require(stacker.result())
    #expect(result.pixels.allSatisfy { abs($0 - 0.5) < 1e-5 })
    #expect(stacker.frameCount == 10)
}

@Test func emptyStackHasNoResult() {
    let stacker = FrameStacker(width: 8, height: 8)
    #expect(stacker.result() == nil)
    #expect(stacker.frameCount == 0)
}

@Test func rejectsAFrameOfTheWrongSize() {
    var stacker = FrameStacker(width: 8, height: 8)
    let wrong = FloatImage(width: 4, height: 4, pixels: [Float](repeating: 0.5, count: 16))!
    #expect(stacker.add(wrong) == false)
    #expect(stacker.frameCount == 0)
}

/// THE test. If stacking works on linear data, noise falls as sqrt(N).
/// Spec §6 sets the tolerance at ±15%.
@Test func noiseFallsAsSquareRootOfFrameCount() {
    let size = 128
    let level: Float = 0.2
    let sigma = 0.02
    var noise = Noise(seed: 7)

    let single = frame(size: size, level: level, sigma: sigma, noise: &noise)
    let region = PatchRegion(x: 0, y: 0, width: size, height: size)
    let sigmaSingle = NoiseMeasurement.standardDeviation(single, in: region)

    for n in [4, 16, 64] {
        var stacker = FrameStacker(width: size, height: size)
        var localNoise = Noise(seed: UInt64(1000 + n))
        for _ in 0..<n {
            _ = stacker.add(frame(size: size, level: level, sigma: sigma, noise: &localNoise))
        }
        let stacked = try! #require(stacker.result())
        let sigmaStacked = NoiseMeasurement.standardDeviation(stacked, in: region)

        let expected = sigmaSingle / Double(n).squareRoot()
        let error = abs(sigmaStacked - expected) / expected
        #expect(error < 0.15, "N=\(n): measured \(sigmaStacked), expected \(expected), off by \(error * 100)%")
    }
}

/// Memory must not scale with frame count — the accumulator is fixed size.
@Test func accumulatorSizeIsIndependentOfFrameCount() {
    var stacker = FrameStacker(width: 16, height: 16)
    var noise = Noise(seed: 3)
    for _ in 0..<200 {
        _ = stacker.add(frame(size: 16, level: 0.3, sigma: 0.01, noise: &noise))
    }
    let result = try! #require(stacker.result())
    #expect(result.pixels.count == 256)
    #expect(stacker.frameCount == 200)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter FrameStackerTests`
Expected: FAIL — "cannot find 'FrameStacker' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Accumulates frames into a running mean.
///
/// Deliberately a plain mean rather than the spec's sigma-clipped default
/// (spec §4). Sigma clipping needs either two passes or running variance, and
/// its main benefit is rejecting satellite and aircraft trails — across ~19
/// frames an unrejected trail lands at 1/19 intensity, faint and arguably an
/// honest record of what crossed the sky. It is the first fast-follow.
///
/// Memory is one accumulator regardless of frame count (spec §38): a frame is
/// added and discarded, never retained.
public struct FrameStacker: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0

    private var accumulator: [Double]

    public init(width: Int, height: Int) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        self.accumulator = [Double](repeating: 0, count: max(width, 0) * max(height, 0))
    }

    /// Returns false for a frame whose dimensions do not match, rather than
    /// trapping — one malformed frame must not lose the session.
    @discardableResult
    public mutating func add(_ image: FloatImage) -> Bool {
        guard image.width == width, image.height == height else { return false }
        for i in 0..<accumulator.count {
            accumulator[i] += Double(image.pixels[i])
        }
        frameCount += 1
        return true
    }

    public func result() -> FloatImage? {
        guard frameCount > 0 else { return nil }
        let divisor = Double(frameCount)
        return FloatImage(width: width, height: height,
                          pixels: accumulator.map { Float($0 / divisor) })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter FrameStackerTests`
Expected: PASS, 5 tests — including `noiseFallsAsSquareRootOfFrameCount` at N = 4, 16, 64.

If the √N test fails, do NOT loosen the tolerance. Either the accumulator is wrong or the noise generator is correlated between frames; both are real bugs and the tolerance is the thing detecting them.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add frame stacker with sqrt(N) noise reduction proven"
```

---

### Task 3: `RAWDecoder` — real DNGs to linear float

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyProcessing/RAWDecoder.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyProcessingTests/RAWDecoderTests.swift`

**Interfaces:**
- Consumes: `FloatImage`
- Produces: `public enum RAWDecoder` — `static func decodeLuminance(contentsOf url: URL, maxDimension: Int) throws -> FloatImage`, `public enum DecodeError: Error, Sendable`

Core Image handles black level, demosaic and white balance — the parts that are tedious to get right and easy to get subtly wrong. `boostAmount = 0` and gamut mapping disabled get us as close to linear as `CIRAWFilter` allows. **Whether it is linear enough is not assumed: Task 5 measures it.**

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import DeepSkyProcessing

/// Real DNGs are ~19MB each and are never committed, so these tests skip when
/// no session is present. The property that decides whether stacking works —
/// sqrt(N) noise reduction — is proven hermetically in FrameStackerTests and
/// does not depend on these.
private func sampleDNGs() -> [URL] {
    let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: downloads, includingPropertiesForKeys: nil) else { return [] }
    for dir in entries where dir.lastPathComponent.contains("-astro-") {
        let frames = dir.appendingPathComponent("frames")
        if let dngs = try? FileManager.default.contentsOfDirectory(
            at: frames, includingPropertiesForKeys: nil) {
            return dngs.filter { $0.pathExtension.lowercased() == "dng" }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        }
    }
    return []
}

@Test func decodesARealProRAWFrame() throws {
    let dngs = sampleDNGs()
    try #require(!dngs.isEmpty, "no exported session found — skipping")

    let image = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 512)
    #expect(image.width > 0 && image.height > 0)
    #expect(image.width <= 512 && image.height <= 512)
    #expect(image.pixels.allSatisfy { $0.isFinite })
    // A real frame is not uniform.
    #expect(Set(image.pixels.map { ($0 * 1000).rounded() }).count > 10)
}

@Test func decodingIsDeterministic() throws {
    let dngs = sampleDNGs()
    try #require(!dngs.isEmpty, "no exported session found — skipping")

    let a = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 256)
    let b = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 256)
    #expect(a.pixels == b.pixels)
}

@Test func framesFromOneSessionShareDimensions() throws {
    let dngs = sampleDNGs()
    try #require(dngs.count >= 2, "need at least two frames — skipping")

    let first = try RAWDecoder.decodeLuminance(contentsOf: dngs[0], maxDimension: 256)
    for url in dngs.dropFirst() {
        let next = try RAWDecoder.decodeLuminance(contentsOf: url, maxDimension: 256)
        #expect(next.width == first.width && next.height == first.height)
    }
}

@Test func throwsOnAFileThatIsNotRAW() {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-a-raw-\(UUID().uuidString).dng")
    try? Data("hello".utf8).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    #expect(throws: (any Error).self) {
        try RAWDecoder.decodeLuminance(contentsOf: bogus, maxDimension: 128)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter RAWDecoderTests`
Expected: FAIL — "cannot find 'RAWDecoder' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CoreImage

public enum RAWDecoder {
    public enum DecodeError: Error, Sendable, Equatable {
        case notRAW(String)
        case renderFailed(String)
    }

    /// Shared context. Creating one per frame is expensive and there is no
    /// per-frame state worth isolating.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Decodes a RAW file to single-channel luminance, downscaled so the long
    /// edge is at most `maxDimension`.
    ///
    /// Downscaling is deliberate for the MVP: a 12MP frame is 36MB as floats,
    /// and the measurements that matter (noise, sqrt(N)) are scale-invariant.
    /// Full resolution is a later concern once the pipeline is proven.
    ///
    /// `boostAmount = 0` and gamut mapping off get as close to linear as
    /// CIRAWFilter allows. Whether that is linear ENOUGH is measured, not
    /// assumed — see the sqrt(N) check in the pipeline tests.
    public static func decodeLuminance(contentsOf url: URL, maxDimension: Int) throws -> FloatImage {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw DecodeError.notRAW(url.lastPathComponent)
        }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.shadowBias = 0

        guard let output = filter.outputImage else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }

        let extent = output.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }

        let scale = min(1.0, Double(maxDimension) / Double(max(extent.width, extent.height)))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let target = scaled.extent.integral
        let width = Int(target.width), height = Int(target.height)
        guard width > 0, height > 0 else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }

        // Render RGBA float, then take luminance. A linear-light luminance
        // weighting is correct here because the data is (near) linear.
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(scaled,
                           toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: target,
                           format: .RGBAf,
                           colorSpace: nil)
        }

        var luminance = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2]
            luminance[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        guard let image = FloatImage(width: width, height: height, pixels: luminance) else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }
        return image
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter RAWDecoderTests`
Expected: PASS, 4 tests (or skipped with a clear reason if no session is present).

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: decode ProRAW to near-linear luminance"
```

---

### Task 4: `ToneMapper` — the fixed chain

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyProcessing/ToneMapper.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyProcessingTests/ToneMapperTests.swift`

**Interfaces:**
- Consumes: `FloatImage`
- Produces: `public enum ToneMapper` — `static func map(_ image: FloatImage) -> FloatImage`, `static let targetBackground: Float`

Spec §4: black point at the 0.1st percentile, linear gain putting sky background at 10–15% of full scale, then one fixed transfer. Not adaptive, not per-image, so two sessions of the same target are comparable.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import DeepSkyProcessing

private func rampImage(size: Int, low: Float, high: Float) -> FloatImage {
    let pixels = (0..<(size * size)).map { i in
        low + (high - low) * Float(i) / Float(size * size - 1)
    }
    return FloatImage(width: size, height: size, pixels: pixels)!
}

@Test func liftsSkyBackgroundToTheTargetLevel() {
    // A dark frame: background near 0.02, a few brighter pixels.
    var pixels = [Float](repeating: 0.02, count: 64 * 64)
    for i in 0..<50 { pixels[i] = 0.4 }
    let mapped = ToneMapper.map(FloatImage(width: 64, height: 64, pixels: pixels)!)

    var sorted = mapped.pixels.sorted()
    let median = sorted[sorted.count / 2]
    #expect(abs(median - ToneMapper.targetBackground) < 0.06,
            "background landed at \(median), target \(ToneMapper.targetBackground)")
}

/// Crushing the black point loses the faintest real signal, which is the
/// opposite of the point of stacking.
@Test func doesNotCrushTheBackgroundToZero() {
    var pixels = [Float](repeating: 0.02, count: 64 * 64)
    for i in 0..<50 { pixels[i] = 0.4 }
    let mapped = ToneMapper.map(FloatImage(width: 64, height: 64, pixels: pixels)!)
    let sorted = mapped.pixels.sorted()
    #expect(sorted[sorted.count / 2] > 0.01)
}

@Test func isMonotonic() {
    let mapped = ToneMapper.map(rampImage(size: 32, low: 0.0, high: 1.0))
    for i in 1..<mapped.pixels.count {
        #expect(mapped.pixels[i] >= mapped.pixels[i - 1] - 1e-6)
    }
}

@Test func outputStaysInRange() {
    let mapped = ToneMapper.map(rampImage(size: 32, low: -0.5, high: 4.0))
    #expect(mapped.pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(mapped.pixels.allSatisfy { $0.isFinite })
}

/// Fixed, not adaptive: the same input must always give the same output, so
/// two sessions of one target are comparable.
@Test func isDeterministic() {
    let image = rampImage(size: 16, low: 0.01, high: 0.9)
    #expect(ToneMapper.map(image).pixels == ToneMapper.map(image).pixels)
}

@Test func handlesAUniformImageWithoutProducingNaN() {
    let flat = FloatImage(width: 16, height: 16, pixels: [Float](repeating: 0.3, count: 256))!
    #expect(ToneMapper.map(flat).pixels.allSatisfy { $0.isFinite })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter ToneMapperTests`
Expected: FAIL — "cannot find 'ToneMapper' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A fixed tone chain — no adaptation, no per-image decisions.
///
/// Determinism matters more than cleverness here: two sessions of the same
/// target must be comparable, and an adaptive curve would make every result a
/// different rendering of a different scene.
public enum ToneMapper {
    /// Where sky background lands, as a fraction of full scale. Astro
    /// convention puts it dark but clearly off the floor — crushing it to
    /// zero discards the faintest real signal, which is what stacking exists
    /// to recover.
    public static let targetBackground: Float = 0.12

    /// Percentile used for the black point. Not the minimum: a single dead
    /// pixel would drag it and undo the lift.
    static let blackPointPercentile = 0.001

    public static func map(_ image: FloatImage) -> FloatImage {
        var sorted = image.pixels.sorted()
        guard let last = sorted.last, sorted.count > 1 else { return image }

        let blackIndex = min(Int(Double(sorted.count) * blackPointPercentile), sorted.count - 1)
        let black = sorted[blackIndex]
        let median = sorted[sorted.count / 2]

        // Gain that puts the background at the target. A uniform image has no
        // headroom above black, so it passes through with gain 1.
        let headroom = median - black
        let gain: Float = headroom > 1e-6 ? targetBackground / headroom : 1
        _ = last

        let mapped = image.pixels.map { value -> Float in
            let lifted = (value - black) * gain
            let clamped = min(max(lifted, 0), 1)
            return transfer(clamped)
        }
        return FloatImage(width: image.width, height: image.height, pixels: mapped) ?? image
    }

    /// One fixed sRGB-style transfer. Applied after the linear lift so the
    /// faint end is already off the floor before the curve compresses it.
    static func transfer(_ v: Float) -> Float {
        guard v.isFinite, v > 0 else { return 0 }
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter ToneMapperTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add fixed tone recovery chain"
```

---

### Task 5: `StackPipeline` — session on disk to result, and the real-data proof

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyProcessing/StackPipeline.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyProcessingTests/StackPipelineTests.swift`

**Interfaces:**
- Consumes: `RAWDecoder`, `FrameStacker`, `ToneMapper`, `NoiseMeasurement`, `FloatImage`, `PatchRegion`
- Produces:
  - `public struct StackResult: Sendable` — `stacked: FloatImage`, `singleFrame: FloatImage`, `framesUsed: Int`, `framesFailed: Int`, `noiseSingle: Double`, `noiseStacked: Double`, `improvementFactor: Double`, `expectedImprovement: Double`
  - `public enum StackPipeline` — `static func run(frameURLs: [URL], maxDimension: Int, progress: (@Sendable (Int, Int) -> Void)?) throws -> StackResult`

The result carries the measurement, not just the image. That is what makes "it worked" checkable rather than asserted.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import DeepSkyProcessing

private func sessionFrames() -> [URL] {
    let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: downloads, includingPropertiesForKeys: nil) else { return [] }
    for dir in entries where dir.lastPathComponent.contains("-astro-") {
        let frames = dir.appendingPathComponent("frames")
        if let dngs = try? FileManager.default.contentsOfDirectory(
            at: frames, includingPropertiesForKeys: nil) {
            return dngs.filter { $0.pathExtension.lowercased() == "dng" }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        }
    }
    return []
}

@Test func skipsFramesItCannotDecodeRatherThanFailing() throws {
    let frames = sessionFrames()
    try #require(frames.count >= 2, "no exported session found — skipping")

    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("broken-\(UUID().uuidString).dng")
    try Data("nonsense".utf8).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    let result = try StackPipeline.run(frameURLs: [frames[0], bogus, frames[1]],
                                       maxDimension: 256, progress: nil)
    #expect(result.framesUsed == 2)
    #expect(result.framesFailed == 1)
}

@Test func failsWhenNoFrameDecodes() {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("broken-\(UUID().uuidString).dng")
    try? Data("nonsense".utf8).write(to: bogus)
    defer { try? FileManager.default.removeItem(at: bogus) }

    #expect(throws: (any Error).self) {
        try StackPipeline.run(frameURLs: [bogus], maxDimension: 128, progress: nil)
    }
}

@Test func reportsProgressForEveryFrame() throws {
    let frames = sessionFrames()
    try #require(frames.count >= 2, "no exported session found — skipping")

    final class Counter: @unchecked Sendable { var seen: [Int] = [] }
    let counter = Counter()
    _ = try StackPipeline.run(frameURLs: Array(frames.prefix(3)), maxDimension: 128) { done, _ in
        counter.seen.append(done)
    }
    #expect(counter.seen.count == min(frames.count, 3))
}

/// THE real-data check. Stacking N real ProRAW frames must reduce measured
/// background noise by about sqrt(N). If it does not, the decode is not
/// linear enough and the result says so numerically rather than by vibe.
///
/// Reported, not asserted: the sample session was shot handheld indoors, so
/// frame-to-frame scene change is real and the ratio will fall short of the
/// ideal. The number is what we want to see; the assertion is only that
/// stacking helps at all.
@Test func stackingRealFramesReducesNoise() throws {
    let frames = sessionFrames()
    try #require(frames.count >= 3, "no exported session found — skipping")

    let result = try StackPipeline.run(frameURLs: frames, maxDimension: 512, progress: nil)

    print("""

    === REAL DATA: sqrt(N) CHECK ===
    frames used        \(result.framesUsed)
    sigma single       \(result.noiseSingle)
    sigma stacked      \(result.noiseStacked)
    improvement        \(result.improvementFactor)x
    ideal sqrt(N)      \(result.expectedImprovement)x
    ================================

    """)

    #expect(result.noiseStacked < result.noiseSingle,
            "stacking must reduce noise; got \(result.noiseStacked) vs \(result.noiseSingle)")
    #expect(result.improvementFactor > 1.2,
            "expected a clear improvement, got \(result.improvementFactor)x")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter StackPipelineTests`
Expected: FAIL — "cannot find 'StackPipeline' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct StackResult: Sendable {
    public let stacked: FloatImage
    public let singleFrame: FloatImage
    public let framesUsed: Int
    public let framesFailed: Int
    public let noiseSingle: Double
    public let noiseStacked: Double

    /// How much noise actually fell.
    public var improvementFactor: Double {
        noiseStacked > 0 ? noiseSingle / noiseStacked : 0
    }

    /// What perfect stacking of linear data would give.
    public var expectedImprovement: Double { Double(framesUsed).squareRoot() }
}

public enum StackPipeline {
    public enum PipelineError: Error, Sendable, Equatable {
        case noFramesDecoded
        case noBackgroundRegion
    }

    /// Region size for the noise measurement, per spec §6.
    static let measurementPatch = 256

    /// Decodes each frame, accumulates it, and discards it — memory stays flat
    /// regardless of frame count. A frame that fails to decode is skipped and
    /// counted, never fatal: one bad DNG must not lose a session.
    public static func run(
        frameURLs: [URL],
        maxDimension: Int,
        progress: (@Sendable (Int, Int) -> Void)?
    ) throws -> StackResult {
        var stacker: FrameStacker?
        var reference: FloatImage?
        var failed = 0

        for (i, url) in frameURLs.enumerated() {
            defer { progress?(i + 1, frameURLs.count) }
            guard let decoded = try? RAWDecoder.decodeLuminance(
                    contentsOf: url, maxDimension: maxDimension) else {
                failed += 1
                continue
            }
            if stacker == nil {
                stacker = FrameStacker(width: decoded.width, height: decoded.height)
                reference = decoded
            }
            if stacker?.add(decoded) == false { failed += 1 }
        }

        guard let stacker, let reference, let stacked = stacker.result() else {
            throw PipelineError.noFramesDecoded
        }

        // Measure both images over the SAME region — comparing different
        // regions would measure scene variation rather than noise.
        let patch = min(measurementPatch, min(stacked.width, stacked.height))
        guard let region = NoiseMeasurement.backgroundRegion(stacked, size: patch) else {
            throw PipelineError.noBackgroundRegion
        }

        return StackResult(
            stacked: stacked,
            singleFrame: reference,
            framesUsed: stacker.frameCount,
            framesFailed: failed,
            noiseSingle: NoiseMeasurement.standardDeviation(reference, in: region),
            noiseStacked: NoiseMeasurement.standardDeviation(stacked, in: region))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter StackPipelineTests`
Expected: PASS, 4 tests, with the √N figures printed.

**Record the printed improvement factor.** It is the MVP's headline result and decides whether the decode is linear enough. Ideal for 5 frames is 2.24×.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add stacking pipeline with measured noise improvement"
```

---

### Task 6: Result screen with before/after

**Files:**
- Create: `App/StackResultScreen.swift`
- Modify: `App/SessionsScreen.swift`
- Modify: `DeepSky.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `StackPipeline`, `StackResult`, `ToneMapper`, `FloatImage`, `SessionSummary`

- [ ] **Step 1: Link the processing product into the app target**

Add `DeepSkyProcessing` as an `XCSwiftPackageProductDependency` and to the app's Frameworks build phase, following the pattern already used for `DeepSkyCapture` and `DeepSkySession`.

- [ ] **Step 2: Write the result screen**

`StackResultScreen.swift` renders `FloatImage` to a `CGImage` for display, shows a before/after toggle with **both images tone-mapped identically** so the comparison is honest, and reports the measured improvement:

```swift
import SwiftUI
import DeepSkyProcessing

struct StackResultScreen: View {
    let frameURLs: [URL]
    let nightMode: Bool

    @State private var result: StackResult?
    @State private var showingStacked = true
    @State private var progress = 0.0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: DS.md) {
            if let result {
                comparison(result)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.secondaryText(nightMode))
            } else {
                ProgressView(value: progress).tint(DS.accent(nightMode))
                Text("Stacking \(frameURLs.count) frames…")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.secondaryText(nightMode))
            }
        }
        .padding(DS.md)
        .background(DS.background)
        .navigationTitle("Result")
        .task { await stack() }
    }

    @ViewBuilder
    private func comparison(_ result: StackResult) -> some View {
        let image = showingStacked ? result.stacked : result.singleFrame
        if let cg = ImageRenderer.cgImage(ToneMapper.map(image)) {
            Image(decorative: cg, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.radius))
        }

        Picker("", selection: $showingStacked) {
            Text("Single frame").tag(false)
            Text("\(result.framesUsed) stacked").tag(true)
        }
        .pickerStyle(.segmented)

        VStack(spacing: DS.xs) {
            Text(String(format: "%.2f× less noise", result.improvementFactor))
                .readout(24, weight: .bold)
                .foregroundStyle(DS.accent(nightMode))
            Text(String(format: "ideal for %d frames is %.2f×",
                        result.framesUsed, result.expectedImprovement))
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
            if result.framesFailed > 0 {
                Text("\(result.framesFailed) frames could not be decoded")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.status(1, night: nightMode))
            }
        }
    }

    private func stack() async {
        let urls = frameURLs
        do {
            let computed = try await Task.detached(priority: .userInitiated) {
                try StackPipeline.run(frameURLs: urls, maxDimension: 1024, progress: nil)
            }.value
            result = computed
        } catch {
            errorMessage = "Could not stack this session: \(error)"
        }
    }
}

/// Renders a single-channel float image to a displayable CGImage.
enum ImageRenderer {
    static func cgImage(_ image: FloatImage) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(min(max(image.pixels[i], 0), 1) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: image.width, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
```

- [ ] **Step 3: Add a Stack action to the session detail**

In `SessionsScreen.swift`'s `SessionDetail`, add a `NavigationLink` to `StackResultScreen` passing the session's frame URLs, read from `frames/` in the session directory.

- [ ] **Step 4: Build for device**

Run:
```bash
xcodebuild -project DeepSky.xcodeproj -scheme DeepSky -destination 'id=00008130-001611540208001C' -derivedDataPath /tmp/ds -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App DeepSky.xcodeproj
git commit -m "feat: add stack result screen with before/after comparison"
```

---

## Definition of Done

- `swift test --package-path Packages/DeepSkyKit` passes.
- `noiseFallsAsSquareRootOfFrameCount` passes hermetically at N = 4, 16, 64 within ±15%.
- Stacking the real exported session reduces measured noise, with the improvement factor printed.
- The app stacks a session on device and shows before/after, both tone-mapped identically.
- `DeepSkyProcessing` builds for macOS and iOS, imports no AVFoundation, and contains no noise reduction or sharpening.

## Deferred, with reasons

- **Sigma-clipped stacking** (spec §11's default). Plain mean ships first; clipping is the first fast-follow.
- **Star alignment.** Out of MVP scope by decision — the frame ceiling keeps integration under the trailing threshold instead.
- **Full-resolution output.** The pipeline downscales to prove the property first; 12MP output follows once the numbers are right.
- **Warning when most frames are flagged `motion`.** Belongs at stacking time; add once the pipeline is wired to real sessions in-app.
