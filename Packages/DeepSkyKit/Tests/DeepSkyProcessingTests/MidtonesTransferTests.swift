import Testing
import Foundation
@testable import DeepSkyProcessing

struct MidtonesTransferTests {

    /// The three fixed points that define the function.
    @Test func endpointsAndMidpointAreFixed() {
        for m in [Float(0.05), 0.2, 0.5, 0.8] {
            #expect(MidtonesTransfer.apply(0, midtone: m) == 0)
            #expect(MidtonesTransfer.apply(1, midtone: m) == 1)
            #expect(abs(MidtonesTransfer.apply(m, midtone: m) - 0.5) < 1e-5,
                    "m=\(m) should map to 0.5")
        }
    }

    /// m = 0.5 is the identity — the straight line the old linear stretch was
    /// stuck on, and the baseline everything else is measured against.
    @Test func aMidtoneOfAHalfIsTheIdentity() {
        for x in stride(from: Float(0), through: 1, by: 0.1) {
            #expect(abs(MidtonesTransfer.apply(x, midtone: 0.5) - x) < 1e-5)
        }
    }

    @Test func isMonotonicallyIncreasing() {
        for m in [Float(0.01), 0.1, 0.3, 0.5, 0.9] {
            var previous = MidtonesTransfer.apply(0, midtone: m)
            for step in 1...200 {
                let value = MidtonesTransfer.apply(Float(step) / 200, midtone: m)
                #expect(value >= previous - 1e-6, "m=\(m) not monotonic at \(step)")
                previous = value
            }
        }
    }

    /// A midtone below 0.5 must brighten, above must darken. This is the
    /// property the whole stretch depends on.
    @Test func lowMidtonesBrightenAndHighMidtonesDarken() {
        let x: Float = 0.1
        #expect(MidtonesTransfer.apply(x, midtone: 0.05) > x)
        #expect(MidtonesTransfer.apply(x, midtone: 0.9) < x)
    }

    /// THE identity the auto-stretch relies on: solving MTF(x, m) = target for
    /// m is the same as evaluating MTF(x, target). Without this the stretch
    /// would need numerical root-finding per image.
    @Test func solvingForTheMidtoneLandsTheBackgroundOnTheTarget() {
        for background in [Float(0.001), 0.01, 0.05, 0.2, 0.5] {
            for target in [Float(0.1), 0.25, 0.5, 0.75] {
                let m = MidtonesTransfer.midtone(mappingBackground: background, to: target)
                let landed = MidtonesTransfer.apply(background, midtone: m)
                #expect(abs(landed - target) < 1e-4,
                        "background \(background) target \(target) landed \(landed)")
            }
        }
    }

    /// Degenerate parameters must not produce NaN — they reach the display.
    @Test func extremeParametersStayFinite() {
        for m in [Float(0), 1, -0.5, 1.5] {
            for x in [Float(0), 0.5, 1] {
                #expect(MidtonesTransfer.apply(x, midtone: m).isFinite)
            }
        }
    }
}
