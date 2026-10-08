import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ManagerKit

/// Review N4: Symbole werden sofort und verkleinert dekodiert (`CGImageSourceCreateThumbnailAtIndex`), nicht erst beim
/// Zeichnen auf dem Main Thread. Die `.icns`-Daten entstehen im Speicher – keine Datei, kein Systemdienst.
@Suite struct AppIconDecoderTests {
    private func icns(sizes: [Int]) throws -> Data {
        try images(sizes: sizes, type: .icns)
    }

    /// Mehrere quadratische Bilder in einer Datei des Typs `type` (TIFF erlaubt Kanten über 1024 px).
    private func images(sizes: [Int], type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, sizes.count, nil))
        for size in sizes {
            let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func largeIconsAreScaledDownToTheMaximum() throws {
        let image = try #require(AppIconDecoder.image(fromICNS: try icns(sizes: [16, 128, 512])))
        #expect(image.width == AppIconDecoder.maximumPixelSize)
        #expect(image.height == AppIconDecoder.maximumPixelSize)
    }

    @Test func smallIconsAreNotScaledUp() throws {
        let image = try #require(AppIconDecoder.image(fromICNS: try icns(sizes: [16, 32])))
        #expect(image.width == 32)
    }

    /// Review N7: Bilder über `maximumSourceEdge` werden übersprungen, bevor etwas dekodiert wird.
    @Test func oversizedImagesAreSkipped() throws {
        let mixed = try #require(AppIconDecoder.image(fromICNS: try images(sizes: [64, 2048], type: .tiff)))
        #expect(mixed.width == 64)
        #expect(AppIconDecoder.image(fromICNS: try images(sizes: [2048], type: .tiff)) == nil)
        #expect(AppIconDecoder.maximumSourceEdge == 1024)
    }

    @Test func invalidDataGivesNoImage() {
        #expect(AppIconDecoder.image(fromICNS: Data("icns kaputt".utf8)) == nil)
        #expect(AppIconDecoder.image(fromICNS: Data()) == nil)
    }
}
