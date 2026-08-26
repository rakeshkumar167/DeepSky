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
