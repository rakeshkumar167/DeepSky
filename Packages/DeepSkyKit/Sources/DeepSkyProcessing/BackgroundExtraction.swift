import Foundation

/// Fits and removes a smooth background gradient.
///
/// Light pollution, moonlight and lens vignetting all put a broad ramp across
/// the frame. Before stretching it looks harmless; afterwards it is the most
/// obvious thing in the picture, because the stretch amplifies a gradient with
/// exactly the same enthusiasm it amplifies real signal.
///
/// It also corrupts the statistics the stretch depends on. A gradient spreads
/// the histogram, so the image's own MAD stops describing its noise and starts
/// describing its ramp — measured on a real session, MAD read 25× the true
/// noise, which pushed the black point below zero and flattened the stretch to
/// nothing.
///
/// The model is a low-order polynomial surface, the same approach as Siril's
/// polynomial `subsky` and the simpler half of PixInsight's DBE. It is
/// deliberately too rigid to absorb nebulosity: a degree-2 surface cannot
/// follow real structure, so it removes the ramp and leaves the sky.
public enum BackgroundExtraction {

    /// Tiles per axis for background sampling. Enough samples to constrain six
    /// coefficients many times over, coarse enough that each tile's median is
    /// a stable estimate.
    static let gridSize = 8

    /// A tile is treated as background only if its median sits within this
    /// many MADs above the global median. Tiles holding the Milky Way core, a
    /// bright star cluster or a lit horizon fail it and are dropped.
    static let rejectionSigmas: Float = 2.0

    /// Degree-2 polynomial: 1, x, y, x², xy, y².
    static let termCount = 6

    private static func terms(x: Double, y: Double) -> [Double] {
        [1, x, y, x * x, x * y, y * y]
    }

    /// Returns the image with its fitted gradient removed, and the background
    /// level restored so absolute brightness is unchanged.
    ///
    /// Returns the input untouched when too few tiles survive rejection to
    /// constrain the fit — a frame that is mostly bright structure has no
    /// background to measure, and inventing one would subtract real signal.
    public static func removeGradient(_ image: FloatImage) -> FloatImage {
        guard let surface = fitSurface(image) else { return image }

        let globalMedian = AutoStretch.median(of: image.pixels)
        var pixels = [Float](repeating: 0, count: image.pixels.count)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = y * image.width + x
                let modelled = Float(surface[index])
                // Restore the overall level: this removes the ramp, it does
                // not darken the image.
                pixels[index] = image.pixels[index] - modelled + globalMedian
            }
        }
        return FloatImage(width: image.width, height: image.height, pixels: pixels) ?? image
    }

    /// Subtracts a supplied surface, restoring the plane's own level so the
    /// ramp goes but the brightness stays.
    public static func subtract(_ surface: [Double], from image: FloatImage) -> FloatImage {
        guard surface.count == image.pixels.count else { return image }
        let level = AutoStretch.median(of: image.pixels)
        var pixels = [Float](repeating: 0, count: image.pixels.count)
        for i in 0..<pixels.count {
            pixels[i] = image.pixels[i] - Float(surface[i]) + level
        }
        return FloatImage(width: image.width, height: image.height, pixels: pixels) ?? image
    }

    /// The fitted background surface, one value per pixel, or nil when the fit
    /// is not constrained.
    public static func fitSurface(_ image: FloatImage) -> [Double]? {
        let samples = backgroundSamples(image)
        guard samples.count >= termCount * 2 else { return nil }

        // Normal equations for a least-squares polynomial fit. Six unknowns,
        // so this stays trivial to solve directly.
        var ata = [[Double]](repeating: [Double](repeating: 0, count: termCount), count: termCount)
        var atb = [Double](repeating: 0, count: termCount)

        for sample in samples {
            let t = terms(x: sample.x, y: sample.y)
            for i in 0..<termCount {
                atb[i] += t[i] * sample.value
                for j in 0..<termCount { ata[i][j] += t[i] * t[j] }
            }
        }
        guard let coefficients = solve(ata, atb) else { return nil }

        var surface = [Double](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let ny = normalise(y, image.height)
            for x in 0..<image.width {
                let t = terms(x: normalise(x, image.width), y: ny)
                var value = 0.0
                for i in 0..<termCount { value += coefficients[i] * t[i] }
                surface[y * image.width + x] = value
            }
        }
        return surface
    }

    /// Coordinates are centred and scaled to [-0.5, 0.5] so the normal
    /// equations stay well conditioned — raw pixel indices would put x⁴ terms
    /// in the 10¹² range against a constant term of 1.
    private static func normalise(_ value: Int, _ extent: Int) -> Double {
        extent > 1 ? Double(value) / Double(extent - 1) - 0.5 : 0
    }

    struct Sample { let x: Double; let y: Double; let value: Double }

    /// One median per tile, keeping only tiles that look like empty sky.
    static func backgroundSamples(_ image: FloatImage) -> [Sample] {
        let globalMedian = AutoStretch.median(of: image.pixels)
        let mad = AutoStretch.noiseSigma(image)
        let ceiling = globalMedian + rejectionSigmas * mad

        let tileWidth = max(image.width / gridSize, 1)
        let tileHeight = max(image.height / gridSize, 1)

        var samples: [Sample] = []
        var tileY = 0
        while tileY < image.height {
            var tileX = 0
            while tileX < image.width {
                let maxX = min(tileX + tileWidth, image.width)
                let maxY = min(tileY + tileHeight, image.height)

                var values: [Float] = []
                values.reserveCapacity((maxX - tileX) * (maxY - tileY))
                for y in tileY..<maxY {
                    let row = y * image.width
                    for x in tileX..<maxX { values.append(image.pixels[row + x]) }
                }
                let tileMedian = AutoStretch.median(of: values)
                if tileMedian <= ceiling {
                    samples.append(Sample(
                        x: normalise((tileX + maxX) / 2, image.width),
                        y: normalise((tileY + maxY) / 2, image.height),
                        value: Double(tileMedian)))
                }
                tileX += tileWidth
            }
            tileY += tileHeight
        }
        return samples
    }

    /// Gaussian elimination with partial pivoting. Six by six — there is no
    /// case for pulling in a linear algebra dependency.
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = matrix
        var b = rhs
        let n = b.count

        for column in 0..<n {
            var pivotRow = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivotRow][column]) {
                pivotRow = row
            }
            guard abs(a[pivotRow][column]) > 1e-12 else { return nil }
            if pivotRow != column {
                a.swapAt(pivotRow, column)
                b.swapAt(pivotRow, column)
            }
            let pivot = a[column][column]
            for row in (column + 1)..<n {
                let factor = a[row][column] / pivot
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }

        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var value = b[row]
            for k in (row + 1)..<n { value -= a[row][k] * solution[k] }
            solution[row] = value / a[row][row]
        }
        return solution.allSatisfy { $0.isFinite } ? solution : nil
    }
}
