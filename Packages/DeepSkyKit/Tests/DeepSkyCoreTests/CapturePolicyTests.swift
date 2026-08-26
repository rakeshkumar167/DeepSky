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

@Test func storageRequirementWithMaxFrameCountDoesNotCrash() {
    // Int.max frameCount must not trap when converting to Int64.
    let planMax = CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                              intervalSeconds: 0.05, frameCount: Int.max)
    let result = CapturePolicy.storageRequirement(plan: planMax, bytesPerFrame: 25 * mb)
    // Result should clamp and be a valid Int64
    #expect(result > 0)
    #expect(result <= Int64.max)
}

@Test func decideWithOverflowingFramesDoesNotCrash() {
    // Int.max framesRemaining × bytesPerFrame must not trap when converting to Int64.
    let result = CapturePolicy.decide(thermal: .nominal,
                                      freeBytes: Int64.max,
                                      bytesPerFrame: 25 * mb,
                                      framesRemaining: Int.max)
    // Result should be a valid decision, not a crash
    #expect(result == .proceed)
}

@Test func negativeFrameCountClampsToReserveRatherThanTrapping() {
    // frames: Int.min makes `raw` a huge negative Double. It must not fall
    // through to `Int64(raw)`, which traps — and a negative frame count
    // still needs the reserve, so it clamps to reserveBytes rather than a
    // negative requirement.
    let plan = CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                           intervalSeconds: 0.05, frameCount: Int.min)
    let result = CapturePolicy.storageRequirement(plan: plan, bytesPerFrame: 25 * mb)
    #expect(result == Int64(500 * mb))
}

@Test func decideWithNegativeFramesRemainingDoesNotCrash() {
    let result = CapturePolicy.decide(thermal: .nominal, freeBytes: Int64.max,
                                      bytesPerFrame: 25 * mb, framesRemaining: Int.min)
    #expect(result == .proceed)
}

@Test func largeBytesPerFrameClampsToInt64MaxRatherThanOverflowing() {
    // bytesPerFrame large enough that headroom pushes `raw` up near the
    // true Int64.max boundary. The old guard compared against
    // `Double(Int64.max - reserveBytes)`, which rounds up past the real
    // boundary, letting a value through that then overflowed the checked
    // `Int64(raw) + reserveBytes` addition and trapped.
    let plan = CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                           intervalSeconds: 0.05, frameCount: Int.max)
    let result = CapturePolicy.storageRequirement(plan: plan, bytesPerFrame: Int.max)
    #expect(result == Int64.max)
}

@Test func storageRequirementAndDecideBoundaryAgree() {
    // storageRequirement and decide must use the same calculation.
    // When framesRemaining == plan.frameCount, the requirement should match.
    let required = CapturePolicy.storageRequirement(plan: plan60, bytesPerFrame: 25 * mb)

    // At exactly the boundary (freeBytes == required), should proceed
    let atBoundary = CapturePolicy.decide(thermal: .nominal,
                                          freeBytes: required,
                                          bytesPerFrame: 25 * mb,
                                          framesRemaining: 60)
    #expect(atBoundary == .proceed)

    // One byte below should stop
    let belowBoundary = CapturePolicy.decide(thermal: .nominal,
                                             freeBytes: required - 1,
                                             bytesPerFrame: 25 * mb,
                                             framesRemaining: 60)
    #expect(belowBoundary == .stop(reason: "Insufficient storage"))
}
