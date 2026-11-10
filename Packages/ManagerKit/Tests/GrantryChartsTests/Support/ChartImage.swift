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
        var differing = 0
        for start in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<4 where abs(Int(pixels[start + channel]) - Int(other.pixels[start + channel])) > tolerance {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(width * height)
    }

    /// Ob das Bild mehr als den Hintergrund zeigt (Anteil der Pixel abseits der Farbe links oben).
    var coverage: Double {
        let background = pixels[0..<4]
        var drawn = 0
        for start in stride(from: 0, to: pixels.count, by: 4)
        where zip(pixels[start..<start + 4], background).contains(where: { abs(Int($0) - Int($1)) > 8 }) {
            drawn += 1
        }
        return Double(drawn) / Double(width * height)
    }
}
