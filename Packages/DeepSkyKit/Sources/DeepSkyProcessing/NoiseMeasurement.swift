import Foundation

public struct PatchRegion: Sendable, Hashable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Measures background noise, which is how the entire pipeline is judged:
/// stacking N frames must reduce σ by about √N (spec §6).
///
/// This exists before the stacker on purpose. Without a yardstick the only way
/// to assess a stack is to look at it, and "looks cleaner" is exactly the kind
/// of claim that hides a broken pipeline.
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

    /// Picks the `size`×`size` region whose median is closest to the image's own
    /// median — background sky rather than a star or the horizon.
    ///
    /// Sampled on a coarse grid: scanning every offset of a 12MP frame is
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
