import AppKit
import SwiftUI
@testable import GrantryCharts

/// Erscheinungsbilder der Bild-Tests (Spec §4, §7: hell, dunkel, „Kontrast erhöhen“).
enum ChartAppearance: String, CaseIterable, Sendable {
    case light, dark, contrast

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var contrast: ColorSchemeContrast { self == .contrast ? .increased : .standard }
    var background: Color { self == .dark ? Color(white: 0.09) : Color(white: 0.97) }
}

/// Bild einer Ansicht per `ImageRenderer` – ohne Fenster und ohne Bildschirmaufnahme-Berechtigung – als RGBA-Pixel,
/// meist in doppelter Auflösung (ganze Tabs in einfacher, `task_manager_snapshots.swift`). Liquid Glass und Bildlauf zeichnet `ImageRenderer` nicht; `chartSnapshotRendering` ersetzt sie
/// wie in der Sichtprüfung durch Zeichenbares.
struct ChartImage: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    @MainActor
    init?(_ view: some View, size: CGSize, appearance: ChartAppearance = .light, paused: Bool = true,
          scale: CGFloat = 2) {
        let content = view
            .frame(width: size.width, height: size.height)
            .background(appearance.background)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\._colorSchemeContrast, appearance.contrast)
            .environment(\.chartSnapshotRendering, true)
            .environment(\.chartDrawsSwitches, true)
            .environment(\.chartRenderingPaused, paused)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        self.init(image)
    }

    init?(png: Data) {
        guard let image = NSBitmapImageRep(data: png)?.cgImage else { return nil }
        self.init(image)
    }

    /// Einheitlich als sRGB-RGBA8, damit gespeicherte und frisch gerenderte Bilder vergleichbar sind.
    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var png: Data? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Anteil der Pixel, die in einem Kanal um mehr als `tolerance` abweichen; 1 bei anderer Größe.
    func difference(to other: ChartImage, tolerance: Int = 8) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        let differing = other.pixels.withUnsafeBytes { reference in
            countPixels(differingFrom: reference, referenceStride: 4, tolerance: tolerance)
        }
        return Double(differing) / Double(width * height)
    }

    /// Ob das Bild mehr als den Hintergrund zeigt (Anteil der Pixel abseits der Farbe links oben).
    var coverage: Double {
        let background = Array(pixels[0..<4])
        let drawn = background.withUnsafeBytes { reference in
            countPixels(differingFrom: reference, referenceStride: 0, tolerance: 8)
        }
        return Double(drawn) / Double(width * height)
    }

    /// Zählt Pixel, bei denen ein Kanal um mehr als `tolerance` vom Referenzpixel abweicht; `referenceStride` 4 läuft
    /// Pixel für Pixel mit, 0 vergleicht jedes Pixel mit demselben. Die Tests laufen unoptimiert (Debug) und seriell auf
    /// dem MainActor: Rohzeiger und der 32-Bit-Schnellweg für gleiche Pixel halten den Vergleich eines Galeriebilds bei
    /// Millisekunden statt Sekunden (Array-Indizes mit Slices und Closures kosteten je Bild über eine Sekunde).
    private func countPixels(differingFrom reference: UnsafeRawBufferPointer, referenceStride: Int,
                             tolerance: Int) -> Int {
        pixels.withUnsafeBytes { own in
            guard let ownBase = own.baseAddress, let referenceBase = reference.baseAddress else { return 0 }
            let limit = UInt32(clamping: max(tolerance, 0))
            var count = 0
            var offset = 0
            var referenceOffset = 0
            while offset < own.count {
                let ownPixel = ownBase.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let referencePixel = referenceBase.loadUnaligned(fromByteOffset: referenceOffset, as: UInt32.self)
                if ownPixel != referencePixel, Self.anyChannel(of: ownPixel, and: referencePixel, differsBeyond: limit) {
                    count += 1
                }
                offset += 4
                referenceOffset += referenceStride
            }
            return count
        }
    }

    private static func anyChannel(of first: UInt32, and second: UInt32, differsBeyond limit: UInt32) -> Bool {
        var shift: UInt32 = 0
        while shift < 32 {
            let one = (first >> shift) & 0xFF
            let other = (second >> shift) & 0xFF
            if (one > other ? one - other : other - one) > limit { return true }
            shift += 8
        }
        return false
    }
}
