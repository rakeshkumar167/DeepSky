import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DeepSkyProcessing

/// Renders real session frames to PNGs so the result can be looked at rather
/// than only measured. Gated behind an environment variable — it writes files
/// and needs a session on disk.
struct RenderSamples {

    static func writePNG(_ image: FloatImage, to url: URL) throws {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(min(max(image.pixels[i], 0), 1) * 255)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let cg = CGImage(width: image.width, height: image.height,
                         bitsPerComponent: 8, bitsPerPixel: 8,
                         bytesPerRow: image.width, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: 0),
                         provider: provider, decode: nil,
                         shouldInterpolate: true, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func writePNG(_ image: RGBImage, to url: URL) throws {
        let count = image.width * image.height
        var bytes = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            bytes[i * 3] = UInt8(min(max(image.red.pixels[i], 0), 1) * 255)
            bytes[i * 3 + 1] = UInt8(min(max(image.green.pixels[i], 0), 1) * 255)
            bytes[i * 3 + 2] = UInt8(min(max(image.blue.pixels[i], 0), 1) * 255)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = CGImage(width: image.width, height: image.height,
                         bitsPerComponent: 8, bitsPerPixel: 24,
                         bytesPerRow: image.width * 3, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: provider, decode: nil,
                         shouldInterpolate: true, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func sideBySide(_ images: [RGBImage], gap: Int = 8) -> RGBImage? {
        guard let planes = (0..<3).map({ plane in
            sideBySide(images.map { $0.planes[plane] }, gap: gap)
        }) as [FloatImage?]? , let r = planes[0], let g = planes[1], let b = planes[2] else {
            return nil
        }
        return RGBImage(red: r, green: g, blue: b)
    }

    /// Places images side by side with a thin divider, for one-glance comparison.
    static func sideBySide(_ images: [FloatImage], gap: Int = 8) -> FloatImage? {
        guard let first = images.first else { return nil }
        let height = first.height
        guard images.allSatisfy({ $0.height == height }) else { return nil }

        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        var pixels = [Float](repeating: 0.5, count: width * height)
        var offset = 0
        for image in images {
            for y in 0..<height {
                let source = y * image.width
                let destination = y * width + offset
                for x in 0..<image.width { pixels[destination + x] = image.pixels[source + x] }
            }
            offset += image.width + gap
        }
        return FloatImage(width: width, height: height, pixels: pixels)
    }

    /// The stretch as it was before the midtones work: MAD sigma, linear gain
    /// onto a 0.18 target, then an sRGB transfer.
    fileprivate static func legacyStretch(_ image: FloatImage) -> FloatImage {
        let median = AutoStretch.median(of: image.pixels)
        let sigma = AutoStretch.noiseSigma(image)
        let black = median - 2.8 * sigma
        let linearTarget = ToneMapper.inverseTransfer(0.18)
        let headroom = median - black
        let gain = headroom > 1e-6 ? linearTarget / headroom : 1
        let mapped = image.pixels.map { value -> Float in
            ToneMapper.transfer(min(max((value - black) * gain, 0), 1))
        }
        return FloatImage(width: image.width, height: image.height, pixels: mapped) ?? image
    }

    /// Set DEEPSKY_RENDER=1, DEEPSKY_SESSION=<session dir> and
    /// DEEPSKY_OUT=<output dir> to produce the comparison PNGs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEEPSKY_RENDER"] != nil
                   && ProcessInfo.processInfo.environment["DEEPSKY_SESSION"] != nil
                   && ProcessInfo.processInfo.environment["DEEPSKY_OUT"] != nil))
    func renderComparisons() throws {
        let environment = ProcessInfo.processInfo.environment
        let sessionPath = try #require(environment["DEEPSKY_SESSION"])
        let out = URL(fileURLWithPath: try #require(environment["DEEPSKY_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let frames = URL(fileURLWithPath: sessionPath).appendingPathComponent("frames")
        let urls = try FileManager.default.contentsOfDirectory(at: frames, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.path < $1.path }

        let result = try StackPipeline.run(frameURLs: urls, maxDimension: 1024, progress: nil)

        let singleNew = ColourRender.display(result.singleFrame,
                                             measuredSigma: result.temporalNoiseSingle)
        let stackNew = ColourRender.display(result.stacked,
                                            measuredSigma: result.temporalNoiseStacked)
        let stackOld = RGBImage(grey: Self.legacyStretch(result.stacked.luminance))
        let singleOld = RGBImage(grey: Self.legacyStretch(result.singleFrame.luminance))

        try Self.writePNG(singleNew, to: out.appendingPathComponent("1-single-frame.png"))
        try Self.writePNG(stackNew, to: out.appendingPathComponent("2-stack-\(result.framesUsed)-frames.png"))
        try Self.writePNG(stackOld, to: out.appendingPathComponent("3-stack-old-stretch.png"))

        if let pair = Self.sideBySide([singleNew, stackNew]) {
            try Self.writePNG(pair, to: out.appendingPathComponent("A-single-vs-stack.png"))
        }
        if let pair = Self.sideBySide([stackOld, stackNew]) {
            try Self.writePNG(pair, to: out.appendingPathComponent("B-old-vs-new-stretch.png"))
        }
        if let row = Self.sideBySide([singleOld, stackOld, singleNew, stackNew]) {
            try Self.writePNG(row, to: out.appendingPathComponent("C-all-four.png"))
        }

        print("""

        frames used   \(result.framesUsed)
        improvement   \(String(format: "%.2f", result.temporalImprovement ?? 0))x
        wrote to      \(out.path)
        """)
        #expect(result.framesUsed >= 2)
    }
}
