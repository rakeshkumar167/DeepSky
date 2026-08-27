import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes a processed image out in the formats spec §36 asks for.
///
/// The bit-depth split is the point of offering more than one. A stacked
/// astrophotograph has had an aggressive stretch applied to a narrow slice of
/// the original range, so the tonal steps between adjacent background values
/// are small — small enough that 8 bits per channel visibly bands a smooth
/// sky. PNG and TIFF carry 16 bits and keep those steps; JPEG and HEIF cannot,
/// and are offered for sharing rather than for further editing.
public enum ImageExport {

    public enum Format: String, CaseIterable, Sendable {
        case png, tiff, heif, jpeg

        public var displayName: String {
            switch self {
            case .png: "PNG"
            case .tiff: "TIFF"
            case .heif: "HEIF"
            case .jpeg: "JPEG"
            }
        }

        public var fileExtension: String {
            switch self {
            case .png: "png"
            case .tiff: "tiff"
            case .heif: "heic"
            case .jpeg: "jpg"
            }
        }

        /// Whether the container can hold 16 bits per channel.
        public var isHighBitDepth: Bool {
            switch self {
            case .png, .tiff: true
            case .heif, .jpeg: false
            }
        }

        /// One line on what this format is for, shown beside the choice so the
        /// decision does not require knowing the formats.
        public var summary: String {
            switch self {
            case .png: "16-bit, lossless. Best for further editing."
            case .tiff: "16-bit, lossless. Widest support in astro tools."
            case .heif: "8-bit, compact. Best for sharing."
            case .jpeg: "8-bit, compact. Universally readable."
            }
        }

        var contentType: UTType {
            switch self {
            case .png: .png
            case .tiff: .tiff
            case .heif: .heic
            case .jpeg: .jpeg
            }
        }
    }

    public enum ExportError: Error, Sendable, Equatable {
        case unsupportedFormat(String)
        case encodingFailed(String)
    }

    /// Compression for the lossy formats. High enough that the artefacts stay
    /// well below the noise floor of a stacked frame.
    static let lossyQuality = 0.95

    /// Builds a CGImage at the format's native bit depth.
    ///
    /// The 16-bit samples are a Swift `[UInt16]` copied straight out of memory,
    /// so they are in the platform's NATIVE byte order — little-endian on every
    /// device this ships to. Declaring `.byteOrder16Big` instead told Core
    /// Graphics to read each sample's low byte as its high byte, which turns a
    /// smooth gradient into per-pixel speckle: the low byte is the fastest
    /// varying part of the value. The file still opened and still had the right
    /// dimensions, which is exactly why this needs a test that looks at pixel
    /// VALUES rather than at whether the encode succeeded.
    static func cgImage(_ image: RGBImage, highBitDepth: Bool) -> CGImage? {
        let count = image.width * image.height
        guard count > 0 else { return nil }

        let data: Data
        let bitsPerComponent: Int
        let bitmapInfo: CGBitmapInfo

        if highBitDepth {
            var samples = [UInt16](repeating: 0, count: count * 3)
            for i in 0..<count {
                samples[i * 3] = quantise16(image.red.pixels[i])
                samples[i * 3 + 1] = quantise16(image.green.pixels[i])
                samples[i * 3 + 2] = quantise16(image.blue.pixels[i])
            }
            data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            bitsPerComponent = 16
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                .union(.byteOrder16Little)
        } else {
            var samples = [UInt8](repeating: 0, count: count * 3)
            for i in 0..<count {
                samples[i * 3] = quantise8(image.red.pixels[i])
                samples[i * 3 + 1] = quantise8(image.green.pixels[i])
                samples[i * 3 + 2] = quantise8(image.blue.pixels[i])
            }
            data = Data(samples)
            bitsPerComponent = 8
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        }

        let bytesPerComponent = bitsPerComponent / 8
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: bitsPerComponent,
                       bitsPerPixel: bitsPerComponent * 3,
                       bytesPerRow: image.width * 3 * bytesPerComponent,
                       space: space, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func quantise8(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255)
    }

    static func quantise16(_ value: Float) -> UInt16 {
        UInt16(min(max(value, 0), 1) * 65535)
    }

    /// Encodes to the requested format.
    public static func data(_ image: RGBImage, format: Format) throws -> Data {
        guard let cg = cgImage(image, highBitDepth: format.isHighBitDepth) else {
            throw ExportError.encodingFailed("could not build a bitmap")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                output, format.contentType.identifier as CFString, 1, nil) else {
            // HEIF encoding is unavailable on some simulators, so this is a
            // real runtime possibility rather than a programmer error.
            throw ExportError.unsupportedFormat(format.displayName)
        }

        let options: [CFString: Any] = format.isHighBitDepth
            ? [:] : [kCGImageDestinationLossyCompressionQuality: lossyQuality]
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed(format.displayName)
        }
        return output as Data
    }

    /// Writes to `directory` and returns the file's location.
    ///
    /// The name carries the session and the frame count, so an exported file
    /// still says what it came from once it has left the app.
    public static func write(_ image: RGBImage, format: Format,
                             sessionName: String, frameCount: Int,
                             to directory: URL) throws -> URL {
        let safe = sessionName
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let base = safe.isEmpty ? "deepsky" : safe
        let url = directory.appendingPathComponent(
            "\(base)-\(frameCount)frames.\(format.fileExtension)")
        try data(image, format: format).write(to: url, options: .atomic)
        return url
    }
}
