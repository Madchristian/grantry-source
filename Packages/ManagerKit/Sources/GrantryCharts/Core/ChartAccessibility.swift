import SwiftUI

/// Entwicklung einer Metrik für VoiceOver (Spec §4: aktueller Wert und Trend).
public enum ChartTrend: Equatable, Sendable {
    case rising, falling, steady

    var label: String {
        switch self {
        case .rising: String(localized: "steigend")
        case .falling: String(localized: "fallend")
        case .steady: String(localized: "gleichbleibend")
        }
    }
}

enum ChartAccessibility {
    /// Vergleicht den Mittelwert der letzten `window` Werte mit dem der `window` davor; Abweichungen unter `tolerance`
    /// gelten als gleichbleibend.
    static func trend(of values: [Double?], window: Int = 5, tolerance: Double) -> ChartTrend {
        let measured = values.compactMap { $0 }
        guard measured.count >= window * 2 else { return .steady }
        let recent = measured.suffix(window), earlier = measured.dropLast(window).suffix(window)
        let difference = mean(recent) - mean(earlier)
        if difference > tolerance { return .rising }
        if difference < -tolerance { return .falling }
        return .steady
    }

    static func value(current: String, trend: ChartTrend) -> String { "\(current), \(trend.label)" }

    private static func mean(_ values: some Collection<Double>) -> Double { values.reduce(0, +) / Double(values.count) }
}

public extension View {
    /// Messwert für VoiceOver als ein Element: Beschriftung („CPU 3“) und Wert („12 %“), Inhalt darunter verborgen. Das
    /// Merkmal „statischer Text“ ist nötig: Ohne Rolle meldet SwiftUI unter macOS 27 das Element als AXUnknown und den
    /// Wert nur als AXValueDescription, AXValue bleibt leer (Abnahme 2026.11.10/1547, #520). Aktionen wie
    /// `accessibilityAdjustableAction` bleiben erhalten. Bedienelemente behalten ihre Rolle und brauchen das nicht.
    func accessibilityReading(_ label: Text, value: Text) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(.isStaticText)
    }
}
