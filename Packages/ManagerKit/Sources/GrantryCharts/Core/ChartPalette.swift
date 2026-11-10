import SwiftUI

/// Farbverläufe nach Last (Spec §4; Optik 2026-11-07 wie eine Pegelanzeige): grün bei Leerlauf über gelb und orange zu
/// rot bei Volllast. `colorblindSafe` und `highContrast` gelten
/// für „Farben unterscheiden ohne Farbe“ bzw. „Kontrast erhöhen“; `efficiency` färbt Effizienzkerne.
public enum ChartPalette: Sendable, Equatable {
    case standard, efficiency, colorblindSafe, highContrast

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        func mixed(with other: RGB, by fraction: Double) -> RGB {
            RGB(red: red + (other.red - red) * fraction, green: green + (other.green - green) * fraction,
                blue: blue + (other.blue - blue) * fraction)
        }
    }

    var stops: [(load: Double, color: RGB)] {
        switch self {
        case .standard:
            [(0, RGB(red: 0.32, green: 0.96, blue: 0.48)), (0.5, RGB(red: 0.98, green: 0.86, blue: 0.30)),
             (0.75, RGB(red: 1.00, green: 0.60, blue: 0.24)), (1, RGB(red: 1.00, green: 0.32, blue: 0.30))]
        case .efficiency:
            [(0, RGB(red: 0.18, green: 0.85, blue: 0.75)), (0.6, RGB(red: 0.45, green: 0.90, blue: 0.40)),
             (1, RGB(red: 0.98, green: 0.82, blue: 0.20))]
        case .colorblindSafe:
            [(0, RGB(red: 0.00, green: 0.45, blue: 0.70)), (1, RGB(red: 0.94, green: 0.89, blue: 0.26))]
        case .highContrast:
            [(0, RGB(red: 0.00, green: 0.48, blue: 1.00)), (1, RGB(red: 1.00, green: 0.23, blue: 0.19))]
        }
    }

    func rgb(forLoad load: Double) -> RGB {
        let load = min(max(load.isFinite ? load : 0, 0), 1)
        let stops = stops
        guard let upperIndex = stops.firstIndex(where: { $0.load >= load }), upperIndex > 0 else {
            return stops[0].color
        }
        let lower = stops[upperIndex - 1], upper = stops[upperIndex]
        guard load < upper.load else { return upper.color }
        return lower.color.mixed(with: upper.color, by: (load - lower.load) / (upper.load - lower.load))
    }

    public func color(forLoad load: Double) -> Color {
        let rgb = rgb(forLoad: load)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Für Linien, Ringe und Leisten: im hellen Erscheinungsbild abgedunkelt wie `InstrumentHue`, damit Gelb und Grün
    /// auf Weiß lesbar bleiben. Flächen mit geringer Deckkraft (Heatmap) nehmen `color(forLoad:)`.
    public func strokeColor(forLoad load: Double, in scheme: ColorScheme) -> Color {
        let rgb = rgb(forLoad: load), factor = scheme == .dark ? 1 : 0.66
        return Color(red: rgb.red * factor, green: rgb.green * factor, blue: rgb.blue * factor)
    }
}
