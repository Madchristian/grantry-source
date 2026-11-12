import CoreGraphics
import Foundation
import Testing

/// Pixelvergleich der Bild-Tests: welche Pixel als abweichend oder gezeichnet zählen (Toleranz je Kanal, irgendein
/// Kanal genügt) und dass ein Vergleich großer Bilder auch im Debug-Build schnell bleibt – jedes Referenzbild läuft
/// durch `coverage` und `difference(to:)`, seriell auf dem MainActor.
@Suite struct ChartImageComparisonTests {
    /// 4 × 1 Pixel, opak: Hintergrund, knapp in der Toleranz, knapp darüber (nur Alpha), deutlich anders.
    private static let base: [UInt8] = [10, 20, 30, 255, 10, 20, 30, 255, 10, 20, 30, 255, 10, 20, 30, 255]

    private static func image(_ pixels: [UInt8], width: Int) throws -> ChartImage {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(width: width, height: pixels.count / 4 / width, bitsPerComponent: 8,
                                           bitsPerPixel: 32, bytesPerRow: width * 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false,
                                           intent: .defaultIntent))
        return try #require(ChartImage(cgImage))
    }

    @Test func differenceCountsPixelsWithAnyChannelBeyondTheTolerance() throws {
        let reference = try Self.image(Self.base, width: 4)
        var changed = Self.base
        changed[4] = 18 // Pixel 2: 8 Stufen – noch gleich
        changed[11] = 246 // Pixel 3: Alpha 9 Stufen – abweichend
        changed[12] = 200 // Pixel 4: Rot deutlich – abweichend
        changed[13] = 0
        let other = try Self.image(changed, width: 4)
        #expect(reference.difference(to: other) == 0.5)
        #expect(other.difference(to: reference) == 0.5)
        #expect(reference.difference(to: other, tolerance: 200) == 0)
        #expect(reference.difference(to: reference) == 0)
    }

    @Test func differentSizesDifferCompletely() throws {
        let wide = try Self.image(Self.base, width: 4)
        let square = try Self.image(Self.base, width: 2)
        #expect(wide.difference(to: square) == 1)
    }

    @Test func coverageCountsPixelsAwayFromTheTopLeftColour() throws {
        var pixels = Self.base
        pixels[6] = 38 // Pixel 2: Blau 8 Stufen – Hintergrund
        pixels[9] = 29 // Pixel 3: Grün 9 Stufen – gezeichnet
        pixels[15] = 0 // Pixel 4: Alpha – gezeichnet
        #expect(try Self.image(pixels, width: 4).coverage == 0.5)
        #expect(try Self.image(Self.base, width: 4).coverage == 0)
    }

    /// Ein Bild in Galeriegröße (1180 × 820 bei doppelter Auflösung, 3,9 Megapixel). Vorher kostete jeder der beiden
    /// Durchläufe im Debug-Build rund 1,7 Sekunden; bei über 300 Referenzbildern trieb das die CI ans Job-Timeout.
    @Test func comparingAGalleryImageStaysFastInDebugBuilds() throws {
        let width = 2360
        let height = 1640
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        for index in stride(from: 0, to: pixels.count, by: 4 * 97) { pixels[index] = 0 }
        let first = try Self.image(pixels, width: width)
        pixels[0] = 255
        let second = try Self.image(pixels, width: width)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(first.coverage > 0.01)
            #expect(first.difference(to: second) > 0)
        }
        #expect(elapsed < .seconds(1), "Pixelvergleich dauerte \(elapsed)")
    }
}
