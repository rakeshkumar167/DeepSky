import Foundation

/// Separable box blur, used as the scale-separation primitive.
///
/// Three box passes approximate a Gaussian closely enough for this purpose and
/// cost far less: each pass is O(pixels) via a running sum, independent of
/// radius, where a true Gaussian convolution is O(pixels × radius). At the
/// radii local-contrast work needs — tens of pixels — that difference is the
/// whole budget.
enum Blur {

    /// Passes used to approximate a Gaussian. Three is the standard choice:
    /// the central limit theorem makes repeated box blurs converge on a
    /// Gaussian, and by three the difference is invisible here.
    static let gaussianPasses = 3

    static func gaussianApproximation(_ image: FloatImage, radius: Int) -> FloatImage {
        guard radius > 0 else { return image }
        var result = image
        for _ in 0..<gaussianPasses {
            result = horizontal(result, radius: radius)
            result = vertical(result, radius: radius)
        }
        return result
    }

    /// Edges clamp rather than wrap or darken: a zero-padded blur would pull
    /// the border toward black and put a dark frame around every image.
    static func horizontal(_ image: FloatImage, radius: Int) -> FloatImage {
        let width = image.width, height = image.height
        guard width > 0, radius > 0 else { return image }
        var output = [Float](repeating: 0, count: width * height)
        let window = Float(radius * 2 + 1)

        for y in 0..<height {
            let row = y * width
            // Seed the running sum for x = 0, with the left edge clamped.
            var sum: Float = image.pixels[row] * Float(radius + 1)
            for x in 1...radius where x < width { sum += image.pixels[row + x] }
            if width <= radius {
                // Degenerate: the window is wider than the image.
                for x in 1...radius where x >= width { sum += image.pixels[row + width - 1] }
            }

            for x in 0..<width {
                output[row + x] = sum / window
                let leaving = image.pixels[row + max(x - radius, 0)]
                let entering = image.pixels[row + min(x + radius + 1, width - 1)]
                sum += entering - leaving
            }
        }
        return FloatImage(width: width, height: height, pixels: output) ?? image
    }

    static func vertical(_ image: FloatImage, radius: Int) -> FloatImage {
        let width = image.width, height = image.height
        guard height > 0, radius > 0 else { return image }
        var output = [Float](repeating: 0, count: width * height)
        let window = Float(radius * 2 + 1)

        for x in 0..<width {
            var sum: Float = image.pixels[x] * Float(radius + 1)
            for y in 1...radius where y < height { sum += image.pixels[y * width + x] }
            if height <= radius {
                for y in 1...radius where y >= height { sum += image.pixels[(height - 1) * width + x] }
            }

            for y in 0..<height {
                output[y * width + x] = sum / window
                let leaving = image.pixels[max(y - radius, 0) * width + x]
                let entering = image.pixels[min(y + radius + 1, height - 1) * width + x]
                sum += entering - leaving
            }
        }
        return FloatImage(width: width, height: height, pixels: output) ?? image
    }
}
