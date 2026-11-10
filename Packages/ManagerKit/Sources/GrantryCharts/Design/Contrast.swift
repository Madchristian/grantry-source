import SwiftUI

/// Kontrast nach WCAG 2.x (§2.2) für Farben, die Grantry selbst mischt – etwa die Schrift auf Hitze-Zellen – und für die
/// Tests der Farbreihen. Werte in sRGB 0…1.
enum Contrast {
    typealias RGB = (red: Double, green: Double, blue: Double)

    static let black: RGB = (0, 0, 0)
    static let white: RGB = (1, 1, 1)

    nonisolated static func luminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    nonisolated static func ratio(_ first: RGB, _ second: RGB) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `top` mit Deckkraft `opacity` über `bottom`.
    nonisolated static func mix(_ top: RGB, opacity: Double, over bottom: RGB) -> RGB {
        (top.red * opacity + bottom.red * (1 - opacity), top.green * opacity + bottom.green * (1 - opacity),
         top.blue * opacity + bottom.blue * (1 - opacity))
    }
}

extension Color {
    init(_ rgb: Contrast.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
