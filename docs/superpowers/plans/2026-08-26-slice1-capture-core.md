# DeepSky Slice 1 — Capture Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless, Mac-testable foundation of the DeepSky astrophotography camera — device capability modelling, the runtime-derived shutter ladder, crash-safe session persistence, image metrics, a synthetic camera driver, and the capture coordinator that drives a full session end-to-end.

**Architecture:** One Swift package (`DeepSkyKit`) with five library targets and a one-way dependency rule. All camera access sits behind a `CameraDevice` actor protocol with two implementations; this plan builds only the synthetic one, so every line here is verifiable with `swift test` on macOS with no device and no simulator. The real `AVCaptureDriver` and the SwiftUI app arrive in Plan 2 and must satisfy the same protocol.

**Tech Stack:** Swift 6.2.4 (strict concurrency), Swift Package Manager, Swift Testing (`import Testing`), Accelerate/vImage, Core Image. Xcode 26.3 / iOS SDK 26.2.

**Spec:** `docs/superpowers/specs/2026-08-26-deepsky-slice1-capture-design.md`

## Global Constraints

- **Swift 6 language mode, strict concurrency.** Every public type crossing a boundary is `Sendable`.
- **Dependency rule is one-way and enforced by target structure:** `DeepSkyCore` depends on nothing. `DeepSkyCapture`, `DeepSkyMetrics`, `DeepSkySession` depend only on `DeepSkyCore`. `DeepSkySynthetic` depends on `DeepSkyCore` + `DeepSkyCapture`. No target may import `UIKit` or `SwiftUI`.
- **No CoreMotion, no AVFoundation, no UIKit in this plan.** CoreMotion is iOS-only and would break macOS test builds. `DeepSkyMetrics` therefore consumes *numbers* (angular rates in rad/s), never framework types. This is what keeps stability logic unit-testable.
- **Platforms:** `.iOS(.v26)`, `.macOS(.v15)`. macOS support exists solely so tests run on the dev Mac.
- **Zero third-party dependencies.**
- **Frames are flagged, never discarded** (spec D11). No code path may delete a captured frame.
- **No file is ever rewritten in place.** `session.json` is write-once; `frames.jsonl` is append-only; completion is a separate `completion.json`. This is what makes crash recovery sound.
- **`flags` is a closed set:** `motion`, `thermalPause`, `sessionInterrupted`, `writeRetry`, `settingsDrift`.
- **Test framework is Swift Testing** (`@Test`, `#expect`), not XCTest.
- Run all tests with: `swift test --package-path Packages/DeepSkyKit`

---

### Task 1: Package scaffold and dependency rule

**Files:**
- Create: `Packages/DeepSkyKit/Package.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/DeepSkyCore.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCapture/DeepSkyCapture.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkyMetrics/DeepSkyMetrics.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkySession/DeepSkySession.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkySynthetic/DeepSkySynthetic.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/PackageSmokeTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: the five target names above, importable by later tasks.

- [ ] **Step 1: Write the failing test**

`Packages/DeepSkyKit/Tests/DeepSkyCoreTests/PackageSmokeTests.swift`:

```swift
import Testing
@testable import DeepSkyCore

@Test func packageBuildsAndExposesVersion() {
    #expect(DeepSkyCore.version == "0.1.0")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit`
Expected: FAIL — the package manifest does not exist yet, so the build errors before any test runs.

- [ ] **Step 3: Write minimal implementation**

`Packages/DeepSkyKit/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeepSkyKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "DeepSkyCore", targets: ["DeepSkyCore"]),
        .library(name: "DeepSkyCapture", targets: ["DeepSkyCapture"]),
        .library(name: "DeepSkyMetrics", targets: ["DeepSkyMetrics"]),
        .library(name: "DeepSkySession", targets: ["DeepSkySession"]),
        .library(name: "DeepSkySynthetic", targets: ["DeepSkySynthetic"]),
    ],
    targets: [
        .target(name: "DeepSkyCore"),
        .target(name: "DeepSkyCapture", dependencies: ["DeepSkyCore"]),
        .target(name: "DeepSkyMetrics", dependencies: ["DeepSkyCore"]),
        .target(name: "DeepSkySession", dependencies: ["DeepSkyCore"]),
        .target(name: "DeepSkySynthetic", dependencies: ["DeepSkyCore", "DeepSkyCapture"]),
        .testTarget(name: "DeepSkyCoreTests", dependencies: ["DeepSkyCore"]),
        .testTarget(name: "DeepSkyMetricsTests", dependencies: ["DeepSkyMetrics", "DeepSkyCore"]),
        .testTarget(name: "DeepSkySessionTests", dependencies: ["DeepSkySession", "DeepSkyCore"]),
        .testTarget(name: "DeepSkySyntheticTests",
                    dependencies: ["DeepSkySynthetic", "DeepSkyCapture", "DeepSkyCore"]),
    ]
)
```

`Sources/DeepSkyCore/DeepSkyCore.swift`:

```swift
public enum DeepSkyCore {
    public static let version = "0.1.0"
}
```

Create the other three source files as one-line placeholders so each target has at least one file:

```swift
// Sources/DeepSkyCapture/DeepSkyCapture.swift
import DeepSkyCore
enum DeepSkyCaptureModule { static let core = DeepSkyCore.version }
```

```swift
// Sources/DeepSkyMetrics/DeepSkyMetrics.swift
import DeepSkyCore
enum DeepSkyMetricsModule { static let core = DeepSkyCore.version }
```

```swift
// Sources/DeepSkySession/DeepSkySession.swift
import DeepSkyCore
enum DeepSkySessionModule { static let core = DeepSkyCore.version }
```

```swift
// Sources/DeepSkySynthetic/DeepSkySynthetic.swift
import DeepSkyCore
enum DeepSkySyntheticModule { static let core = DeepSkyCore.version }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit`
Expected: PASS, 1 test.

If `.iOS(.v26)` is rejected by the toolchain, that is a real finding — report it and substitute `.iOS("26.0")`. Do not silently lower the platform floor.

- [ ] **Step 5: Verify the dependency rule holds**

Run: `swift package --package-path Packages/DeepSkyKit show-dependencies 2>&1 | head -20`
Expected: no external dependencies listed.

- [ ] **Step 6: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: scaffold DeepSkyKit package with five targets"
```

---

### Task 2: ShutterSpeed value type with display formatting

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/ShutterSpeed.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/ShutterSpeedTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `public struct ShutterSpeed: Sendable, Hashable, Codable, Comparable` with `init(seconds: Double)`, `var seconds: Double`, `var displayLabel: String`.

The spec sketched `Duration`. We use `Double` seconds instead: AVFoundation speaks `CMTime`, JSON round-trips cleanly, and `Duration`'s attosecond integer representation buys nothing here. Display formatting is a real requirement (§4) and needs its own tests, which is why this is a type and not a bare `Double`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import DeepSkyCore

@Test func formatsSubSecondAsReciprocal() {
    #expect(ShutterSpeed(seconds: 1.0 / 250.0).displayLabel == "1/250")
    #expect(ShutterSpeed(seconds: 0.5).displayLabel == "1/2")
    #expect(ShutterSpeed(seconds: 1.0 / 8000.0).displayLabel == "1/8000")
}

@Test func formatsWholeSecondsWithDecimal() {
    #expect(ShutterSpeed(seconds: 1.0).displayLabel == "1.0s")
    #expect(ShutterSpeed(seconds: 2.0).displayLabel == "2.0s")
    #expect(ShutterSpeed(seconds: 30.0).displayLabel == "30.0s")
}

@Test func ordersByDuration() {
    #expect(ShutterSpeed(seconds: 0.5) < ShutterSpeed(seconds: 1.0))
}

@Test func roundTripsThroughJSON() throws {
    let original = ShutterSpeed(seconds: 1.0 / 250.0)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ShutterSpeed.self, from: data)
    #expect(decoded == original)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter ShutterSpeedTests`
Expected: FAIL — "cannot find 'ShutterSpeed' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct ShutterSpeed: Sendable, Hashable, Codable, Comparable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    /// Sub-second exposures read as reciprocals ("1/250"); one second and
    /// longer read as decimals ("2.0s"). Astrophotographers work in the
    /// second-and-longer range, where reciprocals are unreadable.
    public var displayLabel: String {
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        }
        let reciprocal = (1.0 / seconds).rounded()
        return "1/\(Int(reciprocal))"
    }

    public static func < (lhs: ShutterSpeed, rhs: ShutterSpeed) -> Bool {
        lhs.seconds < rhs.seconds
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter ShutterSpeedTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCore/ShutterSpeed.swift \
        Packages/DeepSkyKit/Tests/DeepSkyCoreTests/ShutterSpeedTests.swift
git commit -m "feat: add ShutterSpeed value type with astro-oriented formatting"
```

---

### Task 3: Device capability model

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/DeviceCapabilities.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/DeviceCapabilitiesTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `DeviceCapabilities`, `LensCapability`, `FormatCapability` — all `Sendable, Codable, Hashable`. Field names must match the spec §5 exactly, because Plan 2's probe writes this JSON on real hardware and these fixtures are the contract.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter DeviceCapabilitiesTests`
Expected: FAIL — "cannot find 'DeviceCapabilities' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct FormatCapability: Sendable, Codable, Hashable {
    public let width: Int
    public let height: Int
    public let minExposureSeconds: Double
    public let maxExposureSeconds: Double
    public let minISO: Float
    public let maxISO: Float
    public let horizontalFieldOfViewDegrees: Float
    public let maxPhotoDimensions: [[Int]]
    public let rawPixelFormats: [String]

    public init(width: Int, height: Int,
                minExposureSeconds: Double, maxExposureSeconds: Double,
                minISO: Float, maxISO: Float,
                horizontalFieldOfViewDegrees: Float,
                maxPhotoDimensions: [[Int]], rawPixelFormats: [String]) {
        self.width = width
        self.height = height
        self.minExposureSeconds = minExposureSeconds
        self.maxExposureSeconds = maxExposureSeconds
        self.minISO = minISO
        self.maxISO = maxISO
        self.horizontalFieldOfViewDegrees = horizontalFieldOfViewDegrees
        self.maxPhotoDimensions = maxPhotoDimensions
        self.rawPixelFormats = rawPixelFormats
    }
}

public struct LensCapability: Sendable, Codable, Hashable {
    public let deviceType: String
    public let localizedName: String
    public let focalLengthEquivalent: Int?
    public let formats: [FormatCapability]

    public init(deviceType: String, localizedName: String,
                focalLengthEquivalent: Int?, formats: [FormatCapability]) {
        self.deviceType = deviceType
        self.localizedName = localizedName
        self.focalLengthEquivalent = focalLengthEquivalent
        self.formats = formats
    }
}

public struct DeviceCapabilities: Sendable, Codable, Hashable {
    public let deviceModel: String
    public let osVersion: String
    public let supportsAppleProRAW: Bool
    public let lenses: [LensCapability]
    public let probedAt: Date

    public init(deviceModel: String, osVersion: String, supportsAppleProRAW: Bool,
                lenses: [LensCapability], probedAt: Date) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.supportsAppleProRAW = supportsAppleProRAW
        self.lenses = lenses
        self.probedAt = probedAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter DeviceCapabilitiesTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCore/DeviceCapabilities.swift \
        Packages/DeepSkyKit/Tests/DeepSkyCoreTests/DeviceCapabilitiesTests.swift
git commit -m "feat: add device capability model matching probe JSON contract"
```

---

### Task 4: Runtime-derived shutter ladder

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/ShutterLadder.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/ShutterLadderTests.swift`

**Interfaces:**
- Consumes: `ShutterSpeed` (Task 2), `FormatCapability` (Task 3)
- Produces: `public enum ShutterLadder { public static func ladder(for: FormatCapability) -> [ShutterSpeed] }`

This is the spec's central honesty mechanism (§27 over §4): the UI can only ever offer durations the hardware actually reports.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import DeepSkyCore

private func format(min: Double, max: Double) -> FormatCapability {
    FormatCapability(width: 4032, height: 3024,
                     minExposureSeconds: min, maxExposureSeconds: max,
                     minISO: 55, maxISO: 12288,
                     horizontalFieldOfViewDegrees: 68,
                     maxPhotoDimensions: [[4032, 3024]],
                     rawPixelFormats: ["bgg4"])
}

@Test func neverOffersLongerThanHardwareAllows() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.000015, max: 1.0))
    #expect(ladder.allSatisfy { $0.seconds <= 1.0 })
    #expect(ladder.contains { $0.seconds == 1.0 })
    #expect(!ladder.contains { $0.seconds == 30.0 })
}

@Test func neverOffersShorterThanHardwareAllows() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.001, max: 1.0))
    #expect(ladder.allSatisfy { $0.seconds >= 0.001 })
}

@Test func includesHardwareEndpointsExactly() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.002, max: 0.7))
    #expect(ladder.first?.seconds == 0.002)
    #expect(ladder.last?.seconds == 0.7)
}

@Test func isSortedAscendingAndDeduplicated() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.000015, max: 1.0))
    #expect(ladder == ladder.sorted())
    #expect(Set(ladder).count == ladder.count)
}

@Test func extendsToThirtySecondsWhenHardwareAllows() {
    // If a future device reports a 30s ceiling, §4's full ladder appears.
    let ladder = ShutterLadder.ladder(for: format(min: 0.000015, max: 30.0))
    #expect(ladder.contains { $0.seconds == 30.0 })
    #expect(ladder.contains { $0.seconds == 15.0 })
}

@Test func handlesDegenerateRangeWithoutCrashing() {
    let ladder = ShutterLadder.ladder(for: format(min: 0.5, max: 0.5))
    #expect(ladder.count == 1)
    #expect(ladder[0].seconds == 0.5)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter ShutterLadderTests`
Expected: FAIL — "cannot find 'ShutterLadder' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum ShutterLadder {
    /// Conventional photographic stops. This list is a *filter*, never a
    /// promise — entries survive only if the hardware reports it can
    /// actually expose for that long (spec §27 governs over §4).
    static let canonicalSeconds: [Double] = [
        1.0/8000, 1.0/4000, 1.0/2000, 1.0/1000, 1.0/500, 1.0/250,
        1.0/125, 1.0/60, 1.0/30, 1.0/15, 1.0/8, 1.0/4, 1.0/2,
        1, 2, 4, 8, 15, 20, 30,
    ]

    public static func ladder(for format: FormatCapability) -> [ShutterSpeed] {
        let lo = format.minExposureSeconds
        let hi = format.maxExposureSeconds
        guard hi > lo else { return [ShutterSpeed(seconds: lo)] }

        var values = canonicalSeconds.filter { $0 > lo && $0 < hi }
        values.append(lo)
        values.append(hi)

        let unique = Array(Set(values)).sorted()
        return unique.map(ShutterSpeed.init(seconds:))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter ShutterLadderTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCore/ShutterLadder.swift \
        Packages/DeepSkyKit/Tests/DeepSkyCoreTests/ShutterLadderTests.swift
git commit -m "feat: derive shutter ladder from hardware limits at runtime"
```

---

### Task 5: CapturePlan and the total-capture-time solver

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/CapturePlan.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/CapturePlanTests.swift`

**Interfaces:**
- Consumes: `ShutterSpeed` (Task 2)
- Produces: `public struct CapturePlan: Sendable, Codable, Hashable` with `sensorExposure: ShutterSpeed`, `intervalSeconds: Double`, `frameCount: Int`, computed `effectiveExposureSeconds`, `totalCaptureSeconds`, and `static func solve(totalCaptureSeconds:sensorExposure:intervalSeconds:) -> CapturePlan`.

Implements spec §6. The four quantities must never be conflated — that is the §27 honesty requirement expressed in arithmetic.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import DeepSkyCore

@Test func effectiveExposureIsFramesTimesSensorExposure() {
    let plan = CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                           intervalSeconds: 0.05, frameCount: 60)
    #expect(plan.effectiveExposureSeconds == 60.0)
}

@Test func totalCaptureTimeIncludesIntervals() {
    let plan = CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                           intervalSeconds: 0.05, frameCount: 60)
    #expect(abs(plan.totalCaptureSeconds - 63.0) < 0.0001)
}

@Test func totalCaptureTimeAlwaysExceedsEffectiveExposure() {
    let plan = CapturePlan(sensorExposure: ShutterSpeed(seconds: 0.5),
                           intervalSeconds: 0.1, frameCount: 20)
    #expect(plan.totalCaptureSeconds > plan.effectiveExposureSeconds)
}

@Test func solverDerivesFrameCountFromRequestedTotal() {
    let plan = CapturePlan.solve(totalCaptureSeconds: 300,
                                 sensorExposure: ShutterSpeed(seconds: 1.0),
                                 intervalSeconds: 0.0)
    #expect(plan.frameCount == 300)
}

@Test func solverRoundsDownSoTotalIsNeverExceeded() {
    let plan = CapturePlan.solve(totalCaptureSeconds: 10,
                                 sensorExposure: ShutterSpeed(seconds: 3.0),
                                 intervalSeconds: 0.0)
    #expect(plan.frameCount == 3)
    #expect(plan.totalCaptureSeconds <= 10.0)
}

@Test func solverAlwaysProducesAtLeastOneFrame() {
    let plan = CapturePlan.solve(totalCaptureSeconds: 1,
                                 sensorExposure: ShutterSpeed(seconds: 10.0),
                                 intervalSeconds: 0.0)
    #expect(plan.frameCount == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter CapturePlanTests`
Expected: FAIL — "cannot find 'CapturePlan' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct CapturePlan: Sendable, Codable, Hashable {
    public var sensorExposure: ShutterSpeed
    public var intervalSeconds: Double
    public var frameCount: Int

    public init(sensorExposure: ShutterSpeed, intervalSeconds: Double, frameCount: Int) {
        self.sensorExposure = sensorExposure
        self.intervalSeconds = intervalSeconds
        self.frameCount = frameCount
    }

    /// What the stack is *equivalent* to. Always presented alongside the
    /// sensor exposure, never in place of it (spec §27).
    public var effectiveExposureSeconds: Double {
        sensorExposure.seconds * Double(frameCount)
    }

    /// Wall-clock duration the user will stand in the cold for.
    public var totalCaptureSeconds: Double {
        (sensorExposure.seconds + intervalSeconds) * Double(frameCount)
    }

    /// Spec §6: the user picks a total; frame count is derived. Rounds
    /// down so the session never runs longer than the requested total.
    public static func solve(totalCaptureSeconds: Double,
                             sensorExposure: ShutterSpeed,
                             intervalSeconds: Double) -> CapturePlan {
        let perFrame = sensorExposure.seconds + intervalSeconds
        let count = perFrame > 0 ? Int((totalCaptureSeconds / perFrame).rounded(.down)) : 1
        return CapturePlan(sensorExposure: sensorExposure,
                           intervalSeconds: intervalSeconds,
                           frameCount: max(1, count))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter CapturePlanTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCore/CapturePlan.swift \
        Packages/DeepSkyKit/Tests/DeepSkyCoreTests/CapturePlanTests.swift
git commit -m "feat: add CapturePlan with total-capture-time solver"
```

---

### Task 6: Session record types

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/SessionRecords.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/SessionRecordsTests.swift`

**Interfaces:**
- Consumes: `ShutterSpeed`, `CapturePlan`, `DeviceCapabilities`
- Produces: `FrameFlag` (closed enum), `StabilityBand`, `StabilityReading`, `ThermalState`, `FrameRecord`, `SessionManifest`, `SessionCompletion`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import DeepSkyCore

@Test func frameFlagIsAClosedSetWithStableRawValues() {
    #expect(FrameFlag.motion.rawValue == "motion")
    #expect(FrameFlag.thermalPause.rawValue == "thermalPause")
    #expect(FrameFlag.sessionInterrupted.rawValue == "sessionInterrupted")
    #expect(FrameFlag.writeRetry.rawValue == "writeRetry")
    #expect(FrameFlag.settingsDrift.rawValue == "settingsDrift")
    #expect(FrameFlag.allCases.count == 5)
}

@Test func frameRecordRoundTripsAsSingleJSONLine() throws {
    let record = FrameRecord(
        index: 1, file: "frames/frame_0001.dng",
        capturedAt: Date(timeIntervalSince1970: 776000000),
        iso: 1600, exposureSeconds: 1.0, lensPosition: 1.0,
        whiteBalanceKelvin: 3900, bytes: 26_214_400,
        thermalState: .nominal,
        stability: StabilityReading(rmsAngularRateRadPerSec: 0.0021,
                                    predictedDriftPixels: 0.41, band: .excellent),
        flags: [], isDark: false)

    let data = try JSONEncoder().encode(record)
    let line = String(data: data, encoding: .utf8)!
    #expect(!line.contains("\n"))

    let decoded = try JSONDecoder().decode(FrameRecord.self, from: data)
    #expect(decoded.index == 1)
    #expect(decoded.stability.band == .excellent)
    #expect(decoded.flags.isEmpty)
}

@Test func decodesUnknownFlagWithoutThrowing() throws {
    // Forward compatibility: a newer writer must not break an older reader.
    let json = """
    {"index":1,"file":"f.dng","capturedAt":776000000,"iso":1600,
     "exposureSeconds":1.0,"lensPosition":1.0,"whiteBalanceKelvin":3900,
     "bytes":100,"thermalState":"nominal",
     "stability":{"rmsAngularRateRadPerSec":0.1,"predictedDriftPixels":2.0,"band":"poor"},
     "flags":["motion","somethingNew"],"isDark":false}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(FrameRecord.self, from: json)
    #expect(decoded.flags == [.motion])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter SessionRecordsTests`
Expected: FAIL — "cannot find 'FrameFlag' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum FrameFlag: String, Sendable, Codable, Hashable, CaseIterable {
    case motion
    case thermalPause
    case sessionInterrupted
    case writeRetry
    case settingsDrift
}

public enum StabilityBand: String, Sendable, Codable, Hashable {
    case excellent, good, poor
}

public enum ThermalState: String, Sendable, Codable, Hashable {
    case nominal, fair, serious, critical
}

public struct StabilityReading: Sendable, Codable, Hashable {
    public let rmsAngularRateRadPerSec: Double
    public let predictedDriftPixels: Double
    public let band: StabilityBand

    public init(rmsAngularRateRadPerSec: Double, predictedDriftPixels: Double, band: StabilityBand) {
        self.rmsAngularRateRadPerSec = rmsAngularRateRadPerSec
        self.predictedDriftPixels = predictedDriftPixels
        self.band = band
    }
}

public struct FrameRecord: Sendable, Codable, Hashable {
    public let index: Int
    public let file: String
    public let capturedAt: Date
    public let iso: Float
    public let exposureSeconds: Double
    public let lensPosition: Float
    public let whiteBalanceKelvin: Int
    public let bytes: Int
    public let thermalState: ThermalState
    public let stability: StabilityReading
    public let flags: [FrameFlag]
    public let isDark: Bool

    public init(index: Int, file: String, capturedAt: Date, iso: Float,
                exposureSeconds: Double, lensPosition: Float, whiteBalanceKelvin: Int,
                bytes: Int, thermalState: ThermalState, stability: StabilityReading,
                flags: [FrameFlag], isDark: Bool) {
        self.index = index
        self.file = file
        self.capturedAt = capturedAt
        self.iso = iso
        self.exposureSeconds = exposureSeconds
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.bytes = bytes
        self.thermalState = thermalState
        self.stability = stability
        self.flags = flags
        self.isDark = isDark
    }

    // Unknown flags from a newer writer are dropped rather than thrown on.
    // Every other field is required — a frame record with no exposure is a bug,
    // not a compatibility question.
    private enum CodingKeys: String, CodingKey {
        case index, file, capturedAt, iso, exposureSeconds, lensPosition
        case whiteBalanceKelvin, bytes, thermalState, stability, flags, isDark
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        file = try c.decode(String.self, forKey: .file)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        iso = try c.decode(Float.self, forKey: .iso)
        exposureSeconds = try c.decode(Double.self, forKey: .exposureSeconds)
        lensPosition = try c.decode(Float.self, forKey: .lensPosition)
        whiteBalanceKelvin = try c.decode(Int.self, forKey: .whiteBalanceKelvin)
        bytes = try c.decode(Int.self, forKey: .bytes)
        thermalState = try c.decode(ThermalState.self, forKey: .thermalState)
        stability = try c.decode(StabilityReading.self, forKey: .stability)
        isDark = try c.decode(Bool.self, forKey: .isDark)
        let rawFlags = try c.decode([String].self, forKey: .flags)
        flags = rawFlags.compactMap(FrameFlag.init(rawValue:))
    }
}

public struct SessionManifest: Sendable, Codable, Hashable {
    public let id: String
    public let name: String
    public let startedAt: Date
    public let plan: CapturePlan
    public let capabilities: DeviceCapabilities

    public init(id: String, name: String, startedAt: Date,
                plan: CapturePlan, capabilities: DeviceCapabilities) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.plan = plan
        self.capabilities = capabilities
    }
}

public struct SessionCompletion: Sendable, Codable, Hashable {
    public let endedAt: Date
    public let framesWritten: Int
    public let framesFlagged: Int
    public let darksWritten: Int

    public init(endedAt: Date, framesWritten: Int, framesFlagged: Int, darksWritten: Int) {
        self.endedAt = endedAt
        self.framesWritten = framesWritten
        self.framesFlagged = framesFlagged
        self.darksWritten = darksWritten
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter SessionRecordsTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCore/SessionRecords.swift \
        Packages/DeepSkyKit/Tests/DeepSkyCoreTests/SessionRecordsTests.swift
git commit -m "feat: add session record types with closed flag set"
```

---

### Task 7: Crash-safe session store

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkySession/SessionStore.swift`
- Delete: `Packages/DeepSkyKit/Sources/DeepSkySession/DeepSkySession.swift` (the Task 1 placeholder — the target now has a real file, so the placeholder `DeepSkySessionModule` enum is dead code)
- Test: `Packages/DeepSkyKit/Tests/DeepSkySessionTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `SessionManifest`, `FrameRecord`, `SessionCompletion` (Task 6)
- Produces: `public actor SessionStore` with `init(root: URL)`, `func create(manifest:) throws -> URL`, `func append(_ record: FrameRecord, to: URL) throws`, `func complete(_:at:) throws`, `nonisolated static func readFrames(at: URL) throws -> [FrameRecord]`, `func incompleteSessions() throws -> [URL]`.

**This task carries the single most important test in the plan.** The append-only design exists so a session interrupted at 3am is recoverable (spec §39). If truncation recovery is wrong, the whole crash-safety story is fiction.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import DeepSkyCore
@testable import DeepSkySession

private func makeManifest() -> SessionManifest {
    SessionManifest(
        id: UUID().uuidString, name: "Milky Way",
        startedAt: Date(timeIntervalSince1970: 776000000),
        plan: CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                          intervalSeconds: 0.05, frameCount: 60),
        capabilities: DeviceCapabilities(deviceModel: "iPhone17,1", osVersion: "26.3",
                                         supportsAppleProRAW: true, lenses: [],
                                         probedAt: Date(timeIntervalSince1970: 776000000)))
}

private func makeRecord(_ i: Int) -> FrameRecord {
    FrameRecord(index: i, file: "frames/frame_\(i).dng",
                capturedAt: Date(timeIntervalSince1970: 776000000 + Double(i)),
                iso: 1600, exposureSeconds: 1.0, lensPosition: 1.0,
                whiteBalanceKelvin: 3900, bytes: 100, thermalState: .nominal,
                stability: StabilityReading(rmsAngularRateRadPerSec: 0.001,
                                            predictedDriftPixels: 0.2, band: .excellent),
                flags: [], isDark: false)
}

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepsky-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func createsSessionDirectoryStructure() async throws {
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("session.json").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("frames").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("darks").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("thumbs").path))
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("completion.json").path))
}

@Test func appendsOneLinePerFrame() async throws {
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    for i in 1...3 { try await store.append(makeRecord(i), to: dir) }

    let text = try String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 3)

    let records = try SessionStore.readFrames(at: dir)
    #expect(records.map(\.index) == [1, 2, 3])
}

@Test func recoversFromTruncatedFinalLine() async throws {
    // Simulates power loss mid-write: the last JSON object is cut in half.
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    for i in 1...5 { try await store.append(makeRecord(i), to: dir) }

    let jsonl = dir.appendingPathComponent("frames.jsonl")
    var text = try String(contentsOf: jsonl, encoding: .utf8)
    text = String(text.dropLast(40))   // shear off part of record 5
    try text.write(to: jsonl, atomically: true, encoding: .utf8)

    let records = try SessionStore.readFrames(at: dir)
    #expect(records.count == 4)
    #expect(records.map(\.index) == [1, 2, 3, 4])
}

@Test func completionMarkerDistinguishesFinishedSessions() async throws {
    let root = tempRoot()
    let store = SessionStore(root: root)
    let finished = try await store.create(manifest: makeManifest())
    let abandoned = try await store.create(manifest: makeManifest())

    try await store.append(makeRecord(1), to: finished)
    try await store.complete(SessionCompletion(endedAt: Date(), framesWritten: 1,
                                               framesFlagged: 0, darksWritten: 0), at: finished)

    let incomplete = try await store.incompleteSessions()
    #expect(incomplete.count == 1)
    #expect(incomplete[0].lastPathComponent == abandoned.lastPathComponent)
}

@Test func neverRewritesSessionManifest() async throws {
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    let manifestURL = dir.appendingPathComponent("session.json")
    let before = try Data(contentsOf: manifestURL)

    for i in 1...3 { try await store.append(makeRecord(i), to: dir) }
    try await store.complete(SessionCompletion(endedAt: Date(), framesWritten: 3,
                                               framesFlagged: 0, darksWritten: 0), at: dir)

    let after = try Data(contentsOf: manifestURL)
    #expect(before == after)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter SessionStoreTests`
Expected: FAIL — "cannot find 'SessionStore' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import DeepSkyCore

public actor SessionStore {
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func create(manifest: SessionManifest) throws -> URL {
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: manifest.startedAt)
        let slug = manifest.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let dir = root.appendingPathComponent("\(stamp)-\(slug)-\(manifest.id)")

        let fm = FileManager.default
        for sub in ["frames", "darks", "thumbs"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub),
                                   withIntermediateDirectories: true)
        }
        // Write-once. Never mutated for the life of the session.
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("session.json"))
        fm.createFile(atPath: dir.appendingPathComponent("frames.jsonl").path, contents: nil)
        return dir
    }

    /// Appends one JSON object plus a newline, then fsyncs. Append-only is
    /// what makes an interrupted session recoverable (spec §39).
    public func append(_ record: FrameRecord, to session: URL) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)

        let url = session.appendingPathComponent("frames.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func complete(_ completion: SessionCompletion, at session: URL) throws {
        try encoder.encode(completion)
            .write(to: session.appendingPathComponent("completion.json"))
    }

    /// Discards a trailing partial line rather than throwing. A half-written
    /// record means the process died mid-append; the frames before it are
    /// still perfectly good.
    public nonisolated static func readFrames(at session: URL) throws -> [FrameRecord] {
        let url = session.appendingPathComponent("frames.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(FrameRecord.self, from: data)
            }
    }

    /// A session directory without completion.json is by definition incomplete.
    public func incompleteSessions() throws -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
            else { return false }
            let hasManifest = fm.fileExists(atPath: dir.appendingPathComponent("session.json").path)
            let hasCompletion = fm.fileExists(atPath: dir.appendingPathComponent("completion.json").path)
            return hasManifest && !hasCompletion
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension ISO8601DateFormatter {
    static let filenameSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        return f
    }()
}
```

Note: colons from the ISO timestamp are legal in APFS filenames but display awkwardly in Finder. If `create` produces confusing names, replace `:` with `-` in `stamp` and re-run — the tests do not depend on the exact format, only that names sort chronologically.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter SessionStoreTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkySession/SessionStore.swift \
        Packages/DeepSkyKit/Tests/DeepSkySessionTests/SessionStoreTests.swift
git commit -m "feat: add crash-safe append-only session store"
```

---

### Task 8: Stability banding in image-plane pixels

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyMetrics/StabilityEstimator.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyMetricsTests/StabilityEstimatorTests.swift`

**Interfaces:**
- Consumes: `StabilityReading`, `StabilityBand`, `FormatCapability` (Tasks 3, 6)
- Produces: `public enum StabilityEstimator { public static func reading(rmsAngularRateRadPerSec:exposureSeconds:format:) -> StabilityReading }`

Bands are defined in predicted image-plane drift, not raw angular rate, so they adapt across lenses and devices with no magic constants (spec §9).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import DeepSkyCore
import DeepSkyMetrics

private func wideFormat() -> FormatCapability {
    // 4032 px across a 68° horizontal field ≈ 3396 px per radian.
    FormatCapability(width: 4032, height: 3024,
                     minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                     minISO: 55, maxISO: 12288,
                     horizontalFieldOfViewDegrees: 68,
                     maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
}

@Test func perfectlyStillIsExcellent() {
    let r = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0,
                                       exposureSeconds: 1.0, format: wideFormat())
    #expect(r.predictedDriftPixels == 0.0)
    #expect(r.band == .excellent)
}

@Test func driftScalesWithExposureTime() {
    let short = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0001,
                                           exposureSeconds: 1.0, format: wideFormat())
    let long = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0001,
                                          exposureSeconds: 4.0, format: wideFormat())
    #expect(abs(long.predictedDriftPixels - short.predictedDriftPixels * 4.0) < 0.0001)
}

@Test func bandsAtHalfAndOnePointFivePixels() {
    let f = wideFormat()
    // pixelsPerRadian ≈ 4032 / (68° in radians) ≈ 3396.4
    let ppr = Double(f.width) / (Double(f.horizontalFieldOfViewDegrees) * .pi / 180.0)

    let justUnderHalf = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 0.4 / ppr, exposureSeconds: 1.0, format: f)
    #expect(justUnderHalf.band == .excellent)

    let onePixel = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 1.0 / ppr, exposureSeconds: 1.0, format: f)
    #expect(onePixel.band == .good)

    let twoPixels = StabilityEstimator.reading(
        rmsAngularRateRadPerSec: 2.0 / ppr, exposureSeconds: 1.0, format: f)
    #expect(twoPixels.band == .poor)
}

@Test func narrowerFieldOfViewIsLessForgiving() {
    // Same shake, longer lens: a telephoto magnifies angular error.
    let wide = wideFormat()
    let tele = FormatCapability(width: 4032, height: 3024,
                                minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                                minISO: 55, maxISO: 12288,
                                horizontalFieldOfViewDegrees: 20,
                                maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
    let w = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0002,
                                       exposureSeconds: 1.0, format: wide)
    let t = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.0002,
                                       exposureSeconds: 1.0, format: tele)
    #expect(t.predictedDriftPixels > w.predictedDriftPixels)
}

@Test func guardsAgainstZeroFieldOfView() {
    let broken = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.1, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: 0,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: [])
    let r = StabilityEstimator.reading(rmsAngularRateRadPerSec: 0.01,
                                       exposureSeconds: 1.0, format: broken)
    #expect(r.predictedDriftPixels.isFinite)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter StabilityEstimatorTests`
Expected: FAIL — "cannot find 'StabilityEstimator' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import DeepSkyCore

public enum StabilityEstimator {
    /// Drift below this many pixels over the exposure counts as excellent.
    static let excellentPixels = 0.5
    /// Drift below this many pixels still stacks cleanly.
    static let goodPixels = 1.5

    public static func reading(rmsAngularRateRadPerSec: Double,
                               exposureSeconds: Double,
                               format: FormatCapability) -> StabilityReading {
        let fovRadians = Double(format.horizontalFieldOfViewDegrees) * .pi / 180.0
        // A malformed format must not produce infinity and poison the manifest.
        let pixelsPerRadian = fovRadians > 0 ? Double(format.width) / fovRadians : 0

        let drift = rmsAngularRateRadPerSec * exposureSeconds * pixelsPerRadian

        let band: StabilityBand
        if drift < excellentPixels {
            band = .excellent
        } else if drift < goodPixels {
            band = .good
        } else {
            band = .poor
        }

        return StabilityReading(rmsAngularRateRadPerSec: rmsAngularRateRadPerSec,
                                predictedDriftPixels: drift, band: band)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter StabilityEstimatorTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyMetrics/StabilityEstimator.swift \
        Packages/DeepSkyKit/Tests/DeepSkyMetricsTests/StabilityEstimatorTests.swift
git commit -m "feat: band stability by predicted image-plane drift"
```

---

### Task 9: Half-Flux Diameter focus metric

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyMetrics/HalfFluxDiameter.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyMetricsTests/HalfFluxDiameterTests.swift`

**Interfaces:**
- Consumes: nothing beyond Foundation
- Produces: `public struct LuminancePatch: Sendable` (`init(width:height:pixels:[Float])`, `subscript(x:y:)`) and `public enum HalfFluxDiameter { public static func measure(_ patch: LuminancePatch) -> Double? }`.

HFD, not Laplacian variance — contrast metrics plateau near focus, HFD degrades monotonically either side of it (spec §9). The metric operates on a plain float array so it is testable without any imaging framework.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import DeepSkyMetrics

/// Renders a Gaussian star of a given sigma into a square patch.
private func syntheticStar(size: Int, sigma: Double, background: Float = 0.02) -> LuminancePatch {
    var pixels = [Float](repeating: background, count: size * size)
    let c = Double(size - 1) / 2.0
    for y in 0..<size {
        for x in 0..<size {
            let dx = Double(x) - c, dy = Double(y) - c
            let v = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            pixels[y * size + x] += Float(v)
        }
    }
    return LuminancePatch(width: size, height: size, pixels: pixels)
}

@Test func tighterStarYieldsSmallerHFD() {
    let sharp = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 1.5))
    let blurry = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 4.0))
    #expect(sharp != nil && blurry != nil)
    #expect(sharp! < blurry!)
}

@Test func hfdIncreasesMonotonicallyWithDefocus() {
    // This monotonicity is the entire reason HFD was chosen over contrast metrics.
    let sigmas = [1.0, 2.0, 3.0, 4.0, 5.0]
    let measured = sigmas.compactMap { HalfFluxDiameter.measure(syntheticStar(size: 96, sigma: $0)) }
    #expect(measured.count == sigmas.count)
    for i in 1..<measured.count {
        #expect(measured[i] > measured[i - 1])
    }
}

@Test func returnsNilOnFeaturelessPatch() {
    let flat = LuminancePatch(width: 32, height: 32,
                              pixels: [Float](repeating: 0.05, count: 32 * 32))
    #expect(HalfFluxDiameter.measure(flat) == nil)
}

@Test func isRobustToBackgroundOffset() {
    // A brighter sky must not change the measured star size much.
    let dark = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 2.0, background: 0.01))!
    let bright = HalfFluxDiameter.measure(syntheticStar(size: 64, sigma: 2.0, background: 0.30))!
    #expect(abs(dark - bright) < 0.5)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter HalfFluxDiameterTests`
Expected: FAIL — "cannot find 'LuminancePatch' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct LuminancePatch: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Float { pixels[y * width + x] }
}

public enum HalfFluxDiameter {
    /// Returns the half-flux diameter in pixels, or nil when the patch holds
    /// no usable point source.
    ///
    /// 1. background = median of the patch
    /// 2. reject the patch if the peak barely exceeds the background
    /// 3. flux-weighted centroid of the above-background signal
    /// 4. find the radius enclosing half the total flux
    /// 5. HFD = 2 * that radius
    public static func measure(_ patch: LuminancePatch) -> Double? {
        let sorted = patch.pixels.sorted()
        guard !sorted.isEmpty else { return nil }
        let background = Double(sorted[sorted.count / 2])
        let peak = Double(sorted[sorted.count - 1])

        // A featureless patch has nothing to focus on.
        guard peak - background > 0.05 else { return nil }

        var totalFlux = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for y in 0..<patch.height {
            for x in 0..<patch.width {
                let f = max(0.0, Double(patch[x, y]) - background)
                totalFlux += f
                sumX += f * Double(x)
                sumY += f * Double(y)
            }
        }
        guard totalFlux > 0 else { return nil }

        let cx = sumX / totalFlux
        let cy = sumY / totalFlux

        // Collect (radius, flux) and accumulate outward until half the flux
        // is enclosed.
        var samples: [(r: Double, f: Double)] = []
        samples.reserveCapacity(patch.width * patch.height)
        for y in 0..<patch.height {
            for x in 0..<patch.width {
                let f = max(0.0, Double(patch[x, y]) - background)
                guard f > 0 else { continue }
                let dx = Double(x) - cx, dy = Double(y) - cy
                samples.append((r: (dx * dx + dy * dy).squareRoot(), f: f))
            }
        }
        samples.sort { $0.r < $1.r }

        let halfFlux = totalFlux / 2.0
        var accumulated = 0.0
        for sample in samples {
            accumulated += sample.f
            if accumulated >= halfFlux {
                return 2.0 * sample.r
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter HalfFluxDiameterTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyMetrics/HalfFluxDiameter.swift \
        Packages/DeepSkyKit/Tests/DeepSkyMetricsTests/HalfFluxDiameterTests.swift
git commit -m "feat: add half-flux-diameter focus metric"
```

---

### Task 10: Storage and thermal capture policy

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCore/CapturePolicy.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkyCoreTests/CapturePolicyTests.swift`

**Interfaces:**
- Consumes: `CapturePlan` (Task 5), `ThermalState` (Task 6)
- Produces: `public enum CaptureDecision: Sendable, Equatable { case proceed, pause(reason: String), stop(reason: String) }` and `public enum CapturePolicy { static func storageRequirement(plan:bytesPerFrame:) -> Int64; static func decide(thermal:freeBytes:bytesPerFrame:framesRemaining:) -> CaptureDecision }`.

Pure decision logic, extracted from the capture loop precisely so it can be tested without a camera (spec §11).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import DeepSkyCore

private let mb = 1_048_576
private let plan60 = CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                                 intervalSeconds: 0.05, frameCount: 60)

@Test func storageRequirementAddsHeadroomAndReserve() {
    // 60 frames x 25 MB x 1.15 + 500 MB reserve
    let required = CapturePolicy.storageRequirement(plan: plan60, bytesPerFrame: 25 * mb)
    let expected = Int64(Double(60 * 25 * mb) * 1.15) + Int64(500 * mb)
    #expect(required == expected)
}

@Test func proceedsWhenCoolAndRoomy() {
    let d = CapturePolicy.decide(thermal: .nominal, freeBytes: Int64(50_000 * mb),
                                 bytesPerFrame: 25 * mb, framesRemaining: 60)
    #expect(d == .proceed)
}

@Test func proceedsAtFairThermalState() {
    let d = CapturePolicy.decide(thermal: .fair, freeBytes: Int64(50_000 * mb),
                                 bytesPerFrame: 25 * mb, framesRemaining: 60)
    #expect(d == .proceed)
}

@Test func pausesAtSeriousThermalState() {
    let d = CapturePolicy.decide(thermal: .serious, freeBytes: Int64(50_000 * mb),
                                 bytesPerFrame: 25 * mb, framesRemaining: 60)
    #expect(d == .pause(reason: "Device temperature high"))
}

@Test func stopsAtCriticalThermalState() {
    let d = CapturePolicy.decide(thermal: .critical, freeBytes: Int64(50_000 * mb),
                                 bytesPerFrame: 25 * mb, framesRemaining: 60)
    #expect(d == .stop(reason: "Device temperature critical"))
}

@Test func stopsWhenRemainingFramesWillNotFit() {
    let d = CapturePolicy.decide(thermal: .nominal, freeBytes: Int64(100 * mb),
                                 bytesPerFrame: 25 * mb, framesRemaining: 60)
    #expect(d == .stop(reason: "Insufficient storage"))
}

@Test func thermalCriticalOutranksStorage() {
    // Both conditions bad: report the one that can damage the device.
    let d = CapturePolicy.decide(thermal: .critical, freeBytes: Int64(1 * mb),
                                 bytesPerFrame: 25 * mb, framesRemaining: 60)
    #expect(d == .stop(reason: "Device temperature critical"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter CapturePolicyTests`
Expected: FAIL — "cannot find 'CapturePolicy' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum CaptureDecision: Sendable, Equatable {
    case proceed
    case pause(reason: String)
    case stop(reason: String)
}

public enum CapturePolicy {
    /// 15% headroom for frame-size variance, plus a fixed reserve so the
    /// device never fills its disk completely.
    static let headroomMultiplier = 1.15
    static let reserveBytes: Int64 = 500 * 1_048_576

    public static func storageRequirement(plan: CapturePlan, bytesPerFrame: Int) -> Int64 {
        let raw = Double(plan.frameCount) * Double(bytesPerFrame) * headroomMultiplier
        return Int64(raw) + reserveBytes
    }

    public static func decide(thermal: ThermalState,
                              freeBytes: Int64,
                              bytesPerFrame: Int,
                              framesRemaining: Int) -> CaptureDecision {
        // Thermal criticality outranks everything — it can damage hardware.
        if thermal == .critical {
            return .stop(reason: "Device temperature critical")
        }

        let needed = Int64(Double(framesRemaining) * Double(bytesPerFrame) * headroomMultiplier)
            + reserveBytes
        if freeBytes < needed {
            return .stop(reason: "Insufficient storage")
        }

        if thermal == .serious {
            return .pause(reason: "Device temperature high")
        }
        return .proceed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter CapturePolicyTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCore/CapturePolicy.swift \
        Packages/DeepSkyKit/Tests/DeepSkyCoreTests/CapturePolicyTests.swift
git commit -m "feat: add storage and thermal capture policy"
```

---

### Task 11: CameraDevice protocol and synthetic driver

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkyCapture/CameraDevice.swift`
- Create: `Packages/DeepSkyKit/Sources/DeepSkySynthetic/SyntheticDriver.swift`
- Delete: `Packages/DeepSkyKit/Sources/DeepSkyCapture/DeepSkyCapture.swift` and `Packages/DeepSkyKit/Sources/DeepSkySynthetic/DeepSkySynthetic.swift` (the Task 1 placeholders — both targets now have real files, so the `*Module` enums are dead code)
- Test: `Packages/DeepSkyKit/Tests/DeepSkySyntheticTests/SyntheticDriverTests.swift`

**Interfaces:**
- Consumes: `DeviceCapabilities`, `ShutterSpeed`, `FormatCapability`
- Produces:
  - `public struct CaptureSettings: Sendable, Codable, Hashable` — `lensIndex: Int`, `iso: Float`, `exposure: ShutterSpeed`, `lensPosition: Float`, `whiteBalanceKelvin: Int`, `exposureBias: Float`
  - `public struct CapturedFrame: Sendable` — `index: Int`, `rawData: Data`, `bytes: Int`, `capturedAt: Date`, `appliedSettings: CaptureSettings`
  - `public protocol CameraDevice: Actor` — `var capabilities: DeviceCapabilities { get }`, `func apply(_:) async throws`, `func captureFrame(index:) async throws -> CapturedFrame`
  - `public actor SyntheticDriver: CameraDevice` — `init(capabilities:seed:)`, plus `var appliedSettingsHistory: [CaptureSettings]`

`previewFrames()` from the spec sketch is deferred to Plan 2; nothing in this plan consumes a preview stream, and adding it now would be untested surface area (YAGNI).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import DeepSkyCore
import DeepSkyCapture
import DeepSkySynthetic

private func testCapabilities() -> DeviceCapabilities {
    let format = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: 68,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
    return DeviceCapabilities(deviceModel: "Synthetic", osVersion: "26.3",
                              supportsAppleProRAW: true,
                              lenses: [LensCapability(deviceType: "wide", localizedName: "Wide",
                                                      focalLengthEquivalent: 24, formats: [format])],
                              probedAt: Date(timeIntervalSince1970: 776000000))
}

private func settings() -> CaptureSettings {
    CaptureSettings(lensIndex: 0, iso: 1600, exposure: ShutterSpeed(seconds: 1.0),
                    lensPosition: 1.0, whiteBalanceKelvin: 3900, exposureBias: 0)
}

@Test func producesFrameDataOnCapture() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    try await driver.apply(settings())
    let frame = try await driver.captureFrame(index: 1)
    #expect(frame.index == 1)
    #expect(frame.bytes > 0)
    #expect(frame.rawData.count == frame.bytes)
}

@Test func isDeterministicForAGivenSeed() async throws {
    let a = SyntheticDriver(capabilities: testCapabilities(), seed: 7)
    let b = SyntheticDriver(capabilities: testCapabilities(), seed: 7)
    try await a.apply(settings())
    try await b.apply(settings())
    let fa = try await a.captureFrame(index: 1)
    let fb = try await b.captureFrame(index: 1)
    #expect(fa.rawData == fb.rawData)
}

@Test func differentSeedsProduceDifferentFrames() async throws {
    let a = SyntheticDriver(capabilities: testCapabilities(), seed: 1)
    let b = SyntheticDriver(capabilities: testCapabilities(), seed: 2)
    try await a.apply(settings())
    try await b.apply(settings())
    let fa = try await a.captureFrame(index: 1)
    let fb = try await b.captureFrame(index: 1)
    #expect(fa.rawData != fb.rawData)
}

@Test func recordsAppliedSettings() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    try await driver.apply(settings())
    let frame = try await driver.captureFrame(index: 1)
    #expect(frame.appliedSettings.iso == 1600)
    #expect(await driver.appliedSettingsHistory.count == 1)
}

@Test func rejectsExposureBeyondHardwareLimit() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    var bad = settings()
    bad.exposure = ShutterSpeed(seconds: 30.0)   // hardware max is 1.0s
    await #expect(throws: CaptureError.self) {
        try await driver.apply(bad)
    }
}

@Test func rejectsCaptureBeforeSettingsApplied() async throws {
    let driver = SyntheticDriver(capabilities: testCapabilities(), seed: 42)
    await #expect(throws: CaptureError.self) {
        _ = try await driver.captureFrame(index: 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter SyntheticDriverTests`
Expected: FAIL — "cannot find 'CaptureSettings' in scope".

- [ ] **Step 3: Write minimal implementation**

`Sources/DeepSkyCapture/CameraDevice.swift` (new file; delete the placeholder `DeepSkyCapture.swift`):

```swift
import Foundation
import DeepSkyCore

public enum CaptureError: Error, Sendable, Equatable {
    case settingsNotApplied
    case exposureOutOfRange(requested: Double, max: Double)
    case isoOutOfRange(requested: Float, max: Float)
    case invalidLensIndex(Int)
}

public struct CaptureSettings: Sendable, Codable, Hashable {
    public var lensIndex: Int
    public var iso: Float
    public var exposure: ShutterSpeed
    public var lensPosition: Float
    public var whiteBalanceKelvin: Int
    public var exposureBias: Float

    public init(lensIndex: Int, iso: Float, exposure: ShutterSpeed,
                lensPosition: Float, whiteBalanceKelvin: Int, exposureBias: Float) {
        self.lensIndex = lensIndex
        self.iso = iso
        self.exposure = exposure
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.exposureBias = exposureBias
    }
}

public struct CapturedFrame: Sendable {
    public let index: Int
    public let rawData: Data
    public let bytes: Int
    public let capturedAt: Date
    public let appliedSettings: CaptureSettings

    public init(index: Int, rawData: Data, capturedAt: Date, appliedSettings: CaptureSettings) {
        self.index = index
        self.rawData = rawData
        self.bytes = rawData.count
        self.capturedAt = capturedAt
        self.appliedSettings = appliedSettings
    }
}

/// The single seam between the app and the camera. `AVCaptureDriver`
/// (Plan 2) and `SyntheticDriver` both conform; nothing above this
/// protocol imports AVFoundation.
public protocol CameraDevice: Actor {
    var capabilities: DeviceCapabilities { get }
    func apply(_ settings: CaptureSettings) async throws
    func captureFrame(index: Int) async throws -> CapturedFrame
}
```

`Sources/DeepSkySynthetic/SyntheticDriver.swift` (new file; delete the placeholder `DeepSkySynthetic.swift`):

```swift
import Foundation
import DeepSkyCore
import DeepSkyCapture

/// Deterministic pseudo-random source so a given seed always yields the
/// same frames — that determinism is what makes it usable as a test fixture.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Stands in for a real camera. Emits small synthetic "RAW" payloads whose
/// byte pattern varies with seed, frame index and applied settings.
///
/// Deliberately NOT a real DNG: this plan tests capture orchestration, not
/// image encoding. Plan 2's AVCaptureDriver produces genuine ProRAW DNGs.
public actor SyntheticDriver: CameraDevice {
    public let capabilities: DeviceCapabilities
    private let seed: UInt64
    private var applied: CaptureSettings?
    public private(set) var appliedSettingsHistory: [CaptureSettings] = []

    /// Payload size per synthetic frame. Small enough to keep tests fast,
    /// large enough that byte-comparison is meaningful.
    static let syntheticFrameBytes = 4096

    public init(capabilities: DeviceCapabilities, seed: UInt64) {
        self.capabilities = capabilities
        self.seed = seed
    }

    public func apply(_ settings: CaptureSettings) async throws {
        guard settings.lensIndex >= 0, settings.lensIndex < capabilities.lenses.count else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        let lens = capabilities.lenses[settings.lensIndex]
        guard let format = lens.formats.first else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }
        guard settings.exposure.seconds <= format.maxExposureSeconds else {
            throw CaptureError.exposureOutOfRange(requested: settings.exposure.seconds,
                                                  max: format.maxExposureSeconds)
        }
        guard settings.iso <= format.maxISO else {
            throw CaptureError.isoOutOfRange(requested: settings.iso, max: format.maxISO)
        }
        applied = settings
        appliedSettingsHistory.append(settings)
    }

    public func captureFrame(index: Int) async throws -> CapturedFrame {
        guard let settings = applied else { throw CaptureError.settingsNotApplied }

        var rng = SeededGenerator(seed: seed &+ UInt64(index))
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.syntheticFrameBytes)
        for _ in 0..<Self.syntheticFrameBytes {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }

        return CapturedFrame(index: index, rawData: Data(bytes),
                             capturedAt: Date(timeIntervalSince1970: 776000000 + Double(index)),
                             appliedSettings: settings)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter SyntheticDriverTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/DeepSkyKit/Sources/DeepSkyCapture/CameraDevice.swift \
        Packages/DeepSkyKit/Sources/DeepSkySynthetic/SyntheticDriver.swift \
        Packages/DeepSkyKit/Tests/DeepSkySyntheticTests/SyntheticDriverTests.swift
git commit -m "feat: add CameraDevice protocol and deterministic synthetic driver"
```

---

### Task 12: Capture coordinator — the end-to-end session

**Files:**
- Create: `Packages/DeepSkyKit/Sources/DeepSkySession/CaptureCoordinator.swift`
- Test: `Packages/DeepSkyKit/Tests/DeepSkySessionTests/CaptureCoordinatorTests.swift`
- Modify: `Packages/DeepSkyKit/Package.swift` — add `DeepSkyCapture` and `DeepSkyMetrics` to the `DeepSkySession` target's dependencies, and `DeepSkySynthetic` to `DeepSkySessionTests`.

**Interfaces:**
- Consumes: everything above
- Produces: `public protocol EnvironmentSensor: Sendable` (`func thermalState() -> ThermalState`, `func freeBytes() -> Int64`, `func rmsAngularRate() -> Double`) and `public actor CaptureCoordinator` with `init(camera:store:sensor:)` and `func run(manifest:settings:isDark:) async throws -> SessionCompletion`.

This is the task that makes Plan 1 *working software*: a complete session, orchestrated, persisted, and recoverable — with no camera hardware anywhere.

Note the dependency-rule change: `DeepSkySession` now depends on `DeepSkyCapture` and `DeepSkyMetrics` as well as `DeepSkyCore`. That is still one-way and acyclic. `DeepSkySynthetic` remains test-only from this target's perspective.

- [ ] **Step 1: Update the package manifest**

In `Package.swift`, change the `DeepSkySession` target and its test target:

```swift
.target(name: "DeepSkySession",
        dependencies: ["DeepSkyCore", "DeepSkyCapture", "DeepSkyMetrics"]),
.testTarget(name: "DeepSkySessionTests",
            dependencies: ["DeepSkySession", "DeepSkyCore", "DeepSkyCapture", "DeepSkySynthetic"]),
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import Foundation
import DeepSkyCore
import DeepSkyCapture
import DeepSkySynthetic
@testable import DeepSkySession

private struct StubSensor: EnvironmentSensor {
    var thermal: ThermalState = .nominal
    var free: Int64 = 100_000_000_000
    var rate: Double = 0.0001
    func thermalState() -> ThermalState { thermal }
    func freeBytes() -> Int64 { free }
    func rmsAngularRate() -> Double { rate }
}

private func caps() -> DeviceCapabilities {
    let format = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: 68,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
    return DeviceCapabilities(deviceModel: "Synthetic", osVersion: "26.3",
                              supportsAppleProRAW: true,
                              lenses: [LensCapability(deviceType: "wide", localizedName: "Wide",
                                                      focalLengthEquivalent: 24, formats: [format])],
                              probedAt: Date(timeIntervalSince1970: 776000000))
}

private func manifest(frames: Int) -> SessionManifest {
    SessionManifest(id: UUID().uuidString, name: "Test",
                    startedAt: Date(timeIntervalSince1970: 776000000),
                    plan: CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                                      intervalSeconds: 0.0, frameCount: frames),
                    capabilities: caps())
}

private func stdSettings() -> CaptureSettings {
    CaptureSettings(lensIndex: 0, iso: 1600, exposure: ShutterSpeed(seconds: 1.0),
                    lensPosition: 1.0, whiteBalanceKelvin: 3900, exposureBias: 0)
}

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepsky-coord-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func runsCompleteSessionAndWritesEveryFrame() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    let completion = try await coordinator.run(manifest: manifest(frames: 10),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 10)

    let store = SessionStore(root: root)
    let incomplete = try await store.incompleteSessions()
    #expect(incomplete.isEmpty)   // completion.json was written
}

@Test func writesEachFrameToDiskWithMatchingManifestEntry() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())
    _ = try await coordinator.run(manifest: manifest(frames: 5),
                                  settings: stdSettings(), isDark: false)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let records = try SessionStore.readFrames(at: dir)
    #expect(records.count == 5)
    for record in records {
        let path = dir.appendingPathComponent(record.file)
        #expect(FileManager.default.fileExists(atPath: path.path))
        let size = try Data(contentsOf: path).count
        #expect(size == record.bytes)
    }
}

@Test func flagsShakyFramesButNeverDiscardsThem() async throws {
    // Spec D11: excessive motion is recorded, never acted on destructively.
    let root = tempRoot()
    var shaky = StubSensor()
    shaky.rate = 0.01   // far beyond the 1.5 px threshold at 1s
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: shaky)

    let completion = try await coordinator.run(manifest: manifest(frames: 6),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 6)      // nothing thrown away
    #expect(completion.framesFlagged == 6)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let records = try SessionStore.readFrames(at: dir)
    #expect(records.allSatisfy { $0.flags.contains(.motion) })
    #expect(records.allSatisfy { $0.stability.band == .poor })
}

@Test func stopsEarlyOnCriticalThermalAndStillCompletesSession() async throws {
    let root = tempRoot()
    var hot = StubSensor()
    hot.thermal = .critical
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: hot)

    let completion = try await coordinator.run(manifest: manifest(frames: 20),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 0)

    // Even an aborted session is finalised, not left dangling.
    let store = SessionStore(root: root)
    #expect(try await store.incompleteSessions().isEmpty)
}

@Test func stopsWhenStorageRunsOut() async throws {
    let root = tempRoot()
    var full = StubSensor()
    full.free = 1024   // nowhere near the 500 MB reserve
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: full)

    let completion = try await coordinator.run(manifest: manifest(frames: 20),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 0)
}

@Test func darkFramesGoToDarksDirectory() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    let completion = try await coordinator.run(manifest: manifest(frames: 4),
                                               settings: stdSettings(), isDark: true)
    #expect(completion.darksWritten == 4)
    #expect(completion.framesWritten == 0)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let records = try SessionStore.readFrames(at: dir)
    #expect(records.allSatisfy { $0.isDark })
    #expect(records.allSatisfy { $0.file.hasPrefix("darks/") })
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path Packages/DeepSkyKit --filter CaptureCoordinatorTests`
Expected: FAIL — "cannot find 'CaptureCoordinator' in scope".

- [ ] **Step 4: Write minimal implementation**

```swift
import Foundation
import DeepSkyCore
import DeepSkyCapture
import DeepSkyMetrics

/// Everything the coordinator needs to know about the world that isn't the
/// camera. Injected so thermal, storage and motion conditions can be driven
/// deterministically in tests — on device, Plan 2 supplies a real implementation
/// backed by ProcessInfo, FileManager and CoreMotion.
public protocol EnvironmentSensor: Sendable {
    func thermalState() -> ThermalState
    func freeBytes() -> Int64
    func rmsAngularRate() -> Double
}

public actor CaptureCoordinator {
    private let camera: any CameraDevice
    private let store: SessionStore
    private let sensor: any EnvironmentSensor

    public init(camera: any CameraDevice, store: SessionStore, sensor: any EnvironmentSensor) {
        self.camera = camera
        self.store = store
        self.sensor = sensor
    }

    public func run(manifest: SessionManifest,
                    settings: CaptureSettings,
                    isDark: Bool) async throws -> SessionCompletion {
        let dir = try await store.create(manifest: manifest)
        try await camera.apply(settings)

        // Until a frame is actually captured we have no measured size, so
        // the policy is seeded with a conservative 12 MP ProRAW estimate.
        var bytesPerFrame = 25 * 1_048_576
        var written = 0
        var flagged = 0

        // A lens with no format is a malformed capability profile, not a
        // runtime condition — fail loudly rather than index-crash later.
        guard settings.lensIndex < manifest.capabilities.lenses.count,
              let format = manifest.capabilities.lenses[settings.lensIndex].formats.first else {
            throw CaptureError.invalidLensIndex(settings.lensIndex)
        }

        // Labelled so the exit is explicit. A bare `break` inside a `switch`
        // exits the switch, not the loop — a classic Swift trap.
        captureLoop: for index in 1...manifest.plan.frameCount {
            let decision = CapturePolicy.decide(
                thermal: sensor.thermalState(),
                freeBytes: sensor.freeBytes(),
                bytesPerFrame: bytesPerFrame,
                framesRemaining: manifest.plan.frameCount - written)

            switch decision {
            case .stop:
                // Abort, but finalise properly — an aborted session is still
                // a valid session with fewer frames (spec §39).
                break captureLoop

            case .pause:
                // Plan 2's UI drives the countdown and retry. Headless there
                // is nothing to wait on, so a pause ends the run; every frame
                // already written is kept.
                break captureLoop

            case .proceed:
                let stability = StabilityEstimator.reading(
                    rmsAngularRateRadPerSec: sensor.rmsAngularRate(),
                    exposureSeconds: settings.exposure.seconds,
                    format: format)

                let frame = try await camera.captureFrame(index: index)
                bytesPerFrame = frame.bytes

                let name = isDark
                    ? String(format: "darks/dark_%04d.dng", index)
                    : String(format: "frames/frame_%04d.dng", index)
                try frame.rawData.write(to: dir.appendingPathComponent(name))

                var flags: [FrameFlag] = []
                if stability.band == .poor { flags.append(.motion) }
                if !flags.isEmpty { flagged += 1 }

                let record = FrameRecord(
                    index: index, file: name, capturedAt: frame.capturedAt,
                    iso: frame.appliedSettings.iso,
                    exposureSeconds: frame.appliedSettings.exposure.seconds,
                    lensPosition: frame.appliedSettings.lensPosition,
                    whiteBalanceKelvin: frame.appliedSettings.whiteBalanceKelvin,
                    bytes: frame.bytes, thermalState: sensor.thermalState(),
                    stability: stability, flags: flags, isDark: isDark)

                try await store.append(record, to: dir)
                written += 1
            }
        }

        let completion = SessionCompletion(
            endedAt: Date(),
            framesWritten: isDark ? 0 : written,
            framesFlagged: flagged,
            darksWritten: isDark ? written : 0)
        try await store.complete(completion, at: dir)
        return completion
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Packages/DeepSkyKit --filter CaptureCoordinatorTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the entire suite**

Run: `swift test --package-path Packages/DeepSkyKit`
Expected: PASS, all tests across all targets (55 tests).

- [ ] **Step 7: Commit**

```bash
git add Packages/DeepSkyKit
git commit -m "feat: add capture coordinator driving end-to-end sessions"
```

---

## Plan 1 Definition of Done

- `swift test --package-path Packages/DeepSkyKit` passes with zero failures.
- A synthetic 10-frame session produces a directory containing `session.json`, `frames.jsonl` with 10 valid records, 10 files under `frames/`, and `completion.json`.
- Truncating `frames.jsonl` mid-record still yields all preceding frames.
- No target imports AVFoundation, CoreMotion, UIKit, or SwiftUI.
- No code path deletes a captured frame.

## Explicitly deferred to Plan 2 (not gaps)

Two items from spec §9 have no task here, deliberately:

- **RGB / luminance / astro histogram.** It consumes live preview buffers via
  `vImageHistogramCalculation`. Its input only exists once a real preview pipeline does, and
  building it against synthetic float arrays would test a shape the device never produces.
  It ships with the preview path in Plan 2.
- **`previewFrames() -> AsyncStream<PreviewFrame>`** on `CameraDevice`. Nothing in Plan 1 consumes
  a preview stream, so adding it now would be untested public surface. Plan 2 widens the protocol;
  `SyntheticDriver` gains a conforming implementation at the same time.

`HalfFluxDiameter` is built here rather than deferred because it is pure array mathematics whose
correctness — monotonic degradation either side of focus — is far easier to prove against
synthetic stars of known sigma than against a real sky.

## What Plan 2 inherits

`CameraDevice`, `CaptureSettings`, `CapturedFrame`, `EnvironmentSensor`, `SessionStore`,
`CaptureCoordinator`, `ShutterLadder`, `CapturePolicy`, `StabilityEstimator`,
`HalfFluxDiameter`, `LuminancePatch`. Plan 2 adds `AVCaptureDriver: CameraDevice`, a real
`EnvironmentSensor` over ProcessInfo/FileManager/CoreMotion, the capability probe that emits
`DeviceCapabilities` JSON from live hardware, the SwiftUI surface, and the TestFlight pipeline.
