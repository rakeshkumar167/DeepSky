import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import DeepSkyProcessing

/// A gradient with distinct per-channel values, so a channel swap or a byte
/// order mistake shows up as a wrong pixel rather than a plausible image.
private func testImage(size: Int = 32) -> RGBImage {
    func plane(_ base: Float, _ slope: Float) -> FloatImage {
        var pixels = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                pixels[y * size + x] = min(base + slope * Float(x) / Float(size - 1), 1)
            }
        }
        return FloatImage(width: size, height: size, pixels: pixels)!
    }
    return RGBImage(red: plane(0.10, 0.6), green: plane(0.30, 0.3), blue: plane(0.55, 0.1))!
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepsky-export-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ImageExportTests {

    @Test func everyFormatEncodesToNonEmptyData() throws {
        for format in ImageExport.Format.allCases {
            let data = try ImageExport.data(testImage(), format: format)
            #expect(!data.isEmpty, "\(format.displayName) produced no data")
        }
    }

    /// Round-trips through ImageIO: the file must be readable, the right size,
    /// and carry the bit depth the format promised.
    @Test func everyFormatRoundTripsAtTheAdvertisedBitDepth() throws {
        for format in ImageExport.Format.allCases {
            let data = try ImageExport.data(testImage(size: 16), format: format)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil),
                                      "\(format.displayName) is not readable")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

            #expect(decoded.width == 16 && decoded.height == 16,
                    "\(format.displayName) changed dimensions")
            if format.isHighBitDepth {
                #expect(decoded.bitsPerComponent == 16,
                        "\(format.displayName) claims 16-bit but wrote \(decoded.bitsPerComponent)")
            }
        }
    }

    /// Draws a decoded image into a known 8-bit RGBA buffer.
    ///
    /// Reading the decoder's own provider bytes and interpreting them with an
    /// assumed byte order is how the first version of this test passed while
    /// the 16-bit path was writing swapped bytes: both readings agreed with
    /// themselves. Rasterising through Core Graphics removes the assumption —
    /// this is what any viewer would show.
    private func rasterise(_ image: CGImage) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &buffer, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// THE regression test for the 16-bit byte order.
    ///
    /// A swapped low and high byte still encodes, still opens, and still has
    /// the right dimensions — it just turns a smooth gradient into per-pixel
    /// speckle, because the low byte varies fastest. Only comparing actual
    /// pixel values catches it.
    @Test func everyFormatPreservesPixelValues() throws {
        let size = 8
        let source = testImage(size: size)

        for format in ImageExport.Format.allCases {
            let data = try ImageExport.data(source, format: format)
            let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            let pixels = try rasterise(decoded)

            // Lossy formats move values around a little; lossless must not.
            let tolerance = format.isHighBitDepth ? 2 : 12

            for index in [0, size + 3, size * size - 1] {
                let expectedRed = Int(ImageExport.quantise8(source.red.pixels[index]))
                let expectedGreen = Int(ImageExport.quantise8(source.green.pixels[index]))
                let expectedBlue = Int(ImageExport.quantise8(source.blue.pixels[index]))

                #expect(abs(Int(pixels[index * 4]) - expectedRed) <= tolerance,
                        "\(format.displayName) red at \(index): \(pixels[index * 4]) vs \(expectedRed)")
                #expect(abs(Int(pixels[index * 4 + 1]) - expectedGreen) <= tolerance,
                        "\(format.displayName) green at \(index): \(pixels[index * 4 + 1]) vs \(expectedGreen)")
                #expect(abs(Int(pixels[index * 4 + 2]) - expectedBlue) <= tolerance,
                        "\(format.displayName) blue at \(index): \(pixels[index * 4 + 2]) vs \(expectedBlue)")
            }
        }
    }

    /// A smooth ramp must stay smooth. This is the shape of the byte-order
    /// failure specifically: neighbouring pixels that differed by one step
    /// come back differing by hundreds.
    @Test func aSmoothRampStaysSmoothThroughLosslessFormats() throws {
        let size = 64
        var pixels = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size { pixels[y * size + x] = 0.2 + 0.6 * Float(x) / Float(size - 1) }
        }
        let ramp = FloatImage(width: size, height: size, pixels: pixels)!
        let source = RGBImage(grey: ramp)

        for format in ImageExport.Format.allCases where format.isHighBitDepth {
            let data = try ImageExport.data(source, format: format)
            let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            let raster = try rasterise(decoded)

            var maxStep = 0
            for x in 1..<size {
                let previous = Int(raster[(x - 1) * 4])
                let current = Int(raster[x * 4])
                maxStep = max(maxStep, abs(current - previous))
            }
            // The ramp climbs ~150 levels over 64 pixels: about 3 per step.
            #expect(maxStep <= 8,
                    "\(format.displayName) has a \(maxStep)-level jump between neighbours")
        }
    }

    @Test func quantisationClampsOutOfRangeValues() {
        #expect(ImageExport.quantise8(-1) == 0)
        #expect(ImageExport.quantise8(2) == 255)
        #expect(ImageExport.quantise16(-0.5) == 0)
        #expect(ImageExport.quantise16(1.5) == 65535)
    }

    @Test func sixteenBitUsesTheFullRange() {
        #expect(ImageExport.quantise16(1) == 65535)
        #expect(ImageExport.quantise16(0) == 0)
    }

    @Test func writesAFileNamedForItsSession() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ImageExport.write(testImage(), format: .png,
                                        sessionName: "Orion Test", frameCount: 12,
                                        to: directory)
        #expect(url.lastPathComponent == "orion-test-12frames.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A session name is user input and reaches the filesystem, so awkward
    /// characters must not produce an awkward path.
    @Test func sanitisesAwkwardSessionNames() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ImageExport.write(testImage(), format: .jpeg,
                                        sessionName: "../../etc/passwd ★",
                                        frameCount: 3, to: directory)
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains(".."))
        #expect(url.deletingLastPathComponent().path == directory.path)
    }

    @Test func anEmptyNameStillProducesAUsableFile() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ImageExport.write(testImage(), format: .png,
                                        sessionName: "***", frameCount: 1, to: directory)
        #expect(url.lastPathComponent == "deepsky-1frames.png")
    }

    @Test func everyFormatHasADistinctExtensionAndSummary() {
        let extensions = Set(ImageExport.Format.allCases.map(\.fileExtension))
        #expect(extensions.count == ImageExport.Format.allCases.count)
        for format in ImageExport.Format.allCases {
            #expect(!format.summary.isEmpty)
            #expect(!format.displayName.isEmpty)
        }
    }
}
