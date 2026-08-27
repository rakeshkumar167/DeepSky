import Foundation
import CoreImage

public enum RAWDecoder {
    public enum DecodeError: Error, Sendable, Equatable {
        case notRAW(String)
        case renderFailed(String)
    }

    /// Shared context. Creating one per frame is expensive and there is no
    /// per-frame state worth isolating.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Decodes a RAW file to single-channel luminance, downscaled so the long
    /// edge is at most `maxDimension`.
    ///
    /// Core Image handles black level, demosaic and white balance — the parts
    /// that are tedious to get right and easy to get subtly wrong. Owning a
    /// demosaic would be an enormous amount of scope for no MVP benefit.
    ///
    /// `boostAmount = 0` and gamut mapping off get as close to sensor-linear
    /// as CIRAWFilter allows. Whether that is linear *enough* is measured
    /// rather than assumed — the √N check in the pipeline is what detects a
    /// tone curve hiding in here.
    ///
    /// Downscaling is deliberate for the MVP: a 12MP frame is 36MB as floats,
    /// and the measurements that matter are scale-invariant. Full resolution
    /// follows once the numbers are right.
    public static func decodeLuminance(contentsOf url: URL, maxDimension: Int) throws -> FloatImage {
        try decodeRGB(contentsOf: url, maxDimension: maxDimension).luminance
    }

    /// Decodes a RAW file to three linear colour planes.
    ///
    /// Colour is not decoration: it is most of what makes a night sky read as
    /// a photograph rather than a sensor dump, and discarding it also discards
    /// star temperature and any real nebula hue. The luminance path above is
    /// now derived from this rather than decoded separately, so there is one
    /// decode and one place where the RAW conversion is defined.
    public static func decodeRGB(contentsOf url: URL, maxDimension: Int) throws -> RGBImage {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw DecodeError.notRAW(url.lastPathComponent)
        }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.shadowBias = 0

        guard let output = filter.outputImage else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }

        let extent = output.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }

        let scale = min(1.0, Double(maxDimension) / Double(max(extent.width, extent.height)))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let target = scaled.extent.integral
        let width = Int(target.width), height = Int(target.height)
        guard width > 0, height > 0 else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }

        // Render RGBA float, then take luminance. Linear-light weighting is
        // correct here precisely because the data is (near) linear.
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(scaled,
                           toBitmap: base,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: target,
                           format: .RGBAf,
                           colorSpace: nil)
        }

        var red = [Float](repeating: 0, count: width * height)
        var green = [Float](repeating: 0, count: width * height)
        var blue = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            red[i] = rgba[i * 4]
            green[i] = rgba[i * 4 + 1]
            blue[i] = rgba[i * 4 + 2]
        }

        guard let r = FloatImage(width: width, height: height, pixels: red),
              let g = FloatImage(width: width, height: height, pixels: green),
              let b = FloatImage(width: width, height: height, pixels: blue),
              let image = RGBImage(red: r, green: g, blue: b) else {
            throw DecodeError.renderFailed(url.lastPathComponent)
        }
        return image
    }
}
