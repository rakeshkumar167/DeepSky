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
