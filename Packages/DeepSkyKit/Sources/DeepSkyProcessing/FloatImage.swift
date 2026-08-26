import Foundation

/// A single-channel float image.
///
/// Deliberately not tied to Core Image so the measurement and stacking
/// mathematics stay testable without any imaging framework — which is what
/// lets the √N property be proven hermetically, with no RAW file in sight.
public struct FloatImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init?(width: Int, height: Int, pixels: [Float]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Float { pixels[y * width + x] }
}
