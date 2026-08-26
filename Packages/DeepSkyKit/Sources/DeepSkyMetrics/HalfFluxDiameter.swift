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
