import Foundation

/// Three colour planes that always share dimensions.
///
/// Planar rather than interleaved so each channel is a `FloatImage` and every
/// single-channel tool in this module — the stacker, the gradient fit, the
/// noise measurement — applies to a plane unchanged. Interleaving would have
/// meant a parallel implementation of each.
public struct RGBImage: Sendable {
    public let red: FloatImage
    public let green: FloatImage
    public let blue: FloatImage

    public var width: Int { red.width }
    public var height: Int { red.height }

    public init?(red: FloatImage, green: FloatImage, blue: FloatImage) {
        guard red.width == green.width, green.width == blue.width,
              red.height == green.height, green.height == blue.height else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A grey image repeated across all three channels, for the paths that
    /// still have only luminance to offer.
    public init(grey: FloatImage) {
        self.red = grey
        self.green = grey
        self.blue = grey
    }

    public var planes: [FloatImage] { [red, green, blue] }

    /// Rebuilds from three transformed planes, preserving order.
    public func withPlanes(_ planes: [FloatImage]) -> RGBImage? {
        guard planes.count == 3 else { return nil }
        return RGBImage(red: planes[0], green: planes[1], blue: planes[2])
    }

    public func map(_ transform: (FloatImage) -> FloatImage) -> RGBImage {
        RGBImage(red: transform(red), green: transform(green), blue: transform(blue)) ?? self
    }

    /// Rec. 709 luminance. The linear-light weighting is correct here
    /// precisely because the data is (near) linear.
    public var luminance: FloatImage {
        var pixels = [Float](repeating: 0, count: red.pixels.count)
        for i in 0..<pixels.count {
            pixels[i] = 0.2126 * red.pixels[i] + 0.7152 * green.pixels[i] + 0.0722 * blue.pixels[i]
        }
        return FloatImage(width: width, height: height, pixels: pixels) ?? red
    }
}

/// Accumulates colour frames into a running mean, one `FrameStacker` per
/// plane. Memory stays flat regardless of frame count, exactly as the
/// single-channel stacker does.
public struct RGBStacker: Sendable {
    private var red: FrameStacker
    private var green: FrameStacker
    private var blue: FrameStacker

    public var frameCount: Int { red.frameCount }

    public init(width: Int, height: Int) {
        red = FrameStacker(width: width, height: height)
        green = FrameStacker(width: width, height: height)
        blue = FrameStacker(width: width, height: height)
    }

    /// All three planes are added or none are — a partial add would leave the
    /// channels averaged over different frame counts, which shows up as a
    /// colour cast rather than an error.
    @discardableResult
    public mutating func add(_ image: RGBImage) -> Bool {
        guard image.width == red.width, image.height == red.height else { return false }
        red.add(image.red)
        green.add(image.green)
        blue.add(image.blue)
        return true
    }

    public func result() -> RGBImage? {
        guard let r = red.result(), let g = green.result(), let b = blue.result() else {
            return nil
        }
        return RGBImage(red: r, green: g, blue: b)
    }
}
