import Foundation

/// Accumulates frames into a running mean.
///
/// Deliberately a plain mean rather than the spec's sigma-clipped default
/// (spec §4). Sigma clipping needs either two passes over the frames or
/// running variance, and its principal benefit is rejecting satellite and
/// aircraft trails — across ~19 frames an unrejected trail lands at 1/19
/// intensity, faint and arguably an honest record of what crossed the sky.
/// It is the first fast-follow after the MVP.
///
/// Memory is one accumulator regardless of frame count (spec §38): a frame is
/// added and discarded, never retained. That is what lets a 30-minute session
/// stack without the memory footprint growing with it.
public struct FrameStacker: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0

    /// Double rather than Float: summing hundreds of frames in Float loses
    /// precision in exactly the faint end this app exists to recover.
    private var accumulator: [Double]

    public init(width: Int, height: Int) {
        let w = max(width, 0), h = max(height, 0)
        self.width = w
        self.height = h
        self.accumulator = [Double](repeating: 0, count: w * h)
    }

    /// Returns false for a frame whose dimensions do not match, rather than
    /// trapping — one malformed frame must not lose the session.
    @discardableResult
    public mutating func add(_ image: FloatImage) -> Bool {
        guard image.width == width, image.height == height else { return false }
        for i in 0..<accumulator.count {
            accumulator[i] += Double(image.pixels[i])
        }
        frameCount += 1
        return true
    }

    public func result() -> FloatImage? {
        guard frameCount > 0 else { return nil }
        let divisor = Double(frameCount)
        return FloatImage(width: width, height: height,
                          pixels: accumulator.map { Float($0 / divisor) })
    }
}
