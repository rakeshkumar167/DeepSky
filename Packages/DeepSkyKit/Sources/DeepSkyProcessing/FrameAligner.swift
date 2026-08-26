import Foundation

public struct Offset: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// Estimates and corrects translation between frames before stacking.
///
/// This was originally scoped OUT of the MVP, on the reasoning that the
/// per-lens frame ceiling would hold drift under the trailing threshold. Real
/// sessions disproved that: a deliberately braced phone still drifted 19–64
/// pixels per frame, and stacking frames offset by that much smears structure
/// instead of averaging noise — measured noise went UP, 0.78× rather than the
/// ideal 2.24×.
///
/// So alignment is not "longer integration, later". Without it the core
/// feature does not function outside of a genuine tripod.
///
/// Translation only. Field rotation matters over long integrations, but a
/// handheld or braced phone drifts far more than it rotates, and translation
/// is what recovers the bulk of it.
public enum FrameAligner {

    /// Downscale factor for the coarse search. Correlating full-resolution
    /// frames over a ±40px window is enormously more work for no extra
    /// accuracy at the pixel level we need.
    static let coarseFactor = 4

    /// Estimates how far `image` has moved relative to `reference`.
    ///
    /// Two-stage: a coarse search on downscaled images to find the
    /// neighbourhood, then a fine search at full resolution around it. A
    /// single full-resolution search over ±40px would be ~6500 offsets ×
    /// every pixel, which is far too slow on a phone.
    public static func estimateOffset(of image: FloatImage,
                                      against reference: FloatImage,
                                      maxShift: Int) -> Offset {
        guard image.width == reference.width, image.height == reference.height,
              maxShift > 0 else { return Offset(x: 0, y: 0) }

        let coarseMax = max(maxShift / coarseFactor, 1)
        guard let smallImage = downscale(image, by: coarseFactor),
              let smallReference = downscale(reference, by: coarseFactor) else {
            return search(image, reference, centre: Offset(x: 0, y: 0), radius: maxShift)
        }

        let coarse = search(smallImage, smallReference,
                            centre: Offset(x: 0, y: 0), radius: coarseMax)
        let seed = Offset(x: coarse.x * coarseFactor, y: coarse.y * coarseFactor)

        // Fine pass covers the whole downscale step plus one, so the coarse
        // result cannot strand the true offset just outside the window.
        return search(image, reference, centre: seed, radius: coarseFactor + 1)
    }

    /// Highest normalised cross-correlation over the candidate offsets.
    ///
    /// Normalised rather than raw: a raw sum favours offsets that happen to
    /// overlap brighter regions, which drifts the answer toward the sky's
    /// gradient rather than its stars.
    static func search(_ image: FloatImage, _ reference: FloatImage,
                       centre: Offset, radius: Int) -> Offset {
        var best = centre
        var bestScore = -Double.infinity

        for dy in (centre.y - radius)...(centre.y + radius) {
            for dx in (centre.x - radius)...(centre.x + radius) {
                let score = correlation(image, reference, dx: dx, dy: dy)
                if score > bestScore {
                    bestScore = score
                    best = Offset(x: dx, y: dy)
                }
            }
        }
        return best
    }

    /// Zero-mean normalised correlation over the overlapping area only.
    ///
    /// Sign convention: `(dx, dy)` is how far `image` has MOVED relative to
    /// `reference`, so content at `reference[p]` is found at `image[p + d]`.
    /// The caller negates it to correct. Getting this backwards produces
    /// perfectly correct magnitudes with inverted signs, which then doubles
    /// the drift instead of removing it.
    static func correlation(_ image: FloatImage, _ reference: FloatImage,
                            dx: Int, dy: Int) -> Double {
        let xStart = max(0, -dx), xEnd = min(image.width, image.width - dx)
        let yStart = max(0, -dy), yEnd = min(image.height, image.height - dy)
        guard xEnd > xStart, yEnd > yStart else { return -.infinity }

        var sumA = 0.0, sumB = 0.0
        var count = 0.0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                sumA += Double(reference[x, y])
                sumB += Double(image[x + dx, y + dy])
                count += 1
            }
        }
        guard count > 0 else { return -.infinity }
        let meanA = sumA / count, meanB = sumB / count

        var num = 0.0, denA = 0.0, denB = 0.0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let a = Double(reference[x, y]) - meanA
                let b = Double(image[x + dx, y + dy]) - meanB
                num += a * b
                denA += a * a
                denB += b * b
            }
        }
        let denominator = (denA * denB).squareRoot()
        return denominator > 1e-12 ? num / denominator : -.infinity
    }

    /// Translates an image. Pixels shifted in from outside the frame are zero —
    /// there is no data behind them and inventing some would be exactly the
    /// fabrication the spec forbids.
    public static func shift(_ image: FloatImage, by offset: Offset) -> FloatImage? {
        var pixels = [Float](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let sourceY = y - offset.y
            guard sourceY >= 0, sourceY < image.height else { continue }
            for x in 0..<image.width {
                let sourceX = x - offset.x
                guard sourceX >= 0, sourceX < image.width else { continue }
                pixels[y * image.width + x] = image[sourceX, sourceY]
            }
        }
        return FloatImage(width: image.width, height: image.height, pixels: pixels)
    }

    static func downscale(_ image: FloatImage, by factor: Int) -> FloatImage? {
        guard factor > 1 else { return image }
        let width = image.width / factor, height = image.height / factor
        guard width > 0, height > 0 else { return nil }

        var pixels = [Float](repeating: 0, count: width * height)
        let divisor = Float(factor * factor)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        sum += image[x * factor + dx, y * factor + dy]
                    }
                }
                pixels[y * width + x] = sum / divisor
            }
        }
        return FloatImage(width: width, height: height, pixels: pixels)
    }
}
