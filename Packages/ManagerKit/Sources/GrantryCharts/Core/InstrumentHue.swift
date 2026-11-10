import SwiftUI

/// Feste Farbe je Messgröße, Gestaltung „Lagebild“ (docs/design/instrumententafel.md §2.3): eine kühle Reihe aus dem
/// Grantry-Verlauf – CPU Petrol-Türkis, Effizienzkerne Lila, Arbeitsspeicher Violett, GPU Limette, Neural Engine
/// Rosé, Netz Blau und Pink, Datenträger Grün und Cyan, Leistung Koralle, Akku Gelbgrün. Orange und Bernstein bleiben dem
/// Befund vorbehalten. Dunkel unverändert; hell für Grafik ×0,62 und für Text ×0,50 abgedunkelt (≥ 3 : 1 bzw. ≥ 4,5 : 1
/// auf Weiß), bei „Kontrast erhöhen“ ×0,42.
public enum InstrumentHue: Sendable, CaseIterable {
    case cpu, efficiencyCores, memory, diskRead, diskWrite, received, sent, gpu, power, battery, neuralEngine

    /// Farbe im dunklen Erscheinungsbild (RGB 0…1).
    var base: (red: Double, green: Double, blue: Double) {
        switch self {
        case .cpu: (0.18, 0.83, 0.75)
        // Lila statt Himmelblau (#495): neben dem Türkis der Leistungskerne auch bei Farbsehschwäche klar getrennt.
        case .efficiencyCores: (0.75, 0.35, 1.00)
        case .memory: (0.66, 0.55, 0.98)
        case .diskRead: (0.29, 0.87, 0.50)
        case .diskWrite: (0.13, 0.80, 0.93)
        case .received: (0.38, 0.65, 0.98)
        case .sent: (0.96, 0.45, 0.71)
        case .gpu: (0.64, 0.90, 0.21)
        case .power: (1.00, 0.45, 0.36)
        case .battery: (0.85, 0.93, 0.35)
        case .neuralEngine: (0.98, 0.44, 0.52)
        }
    }

    /// Farbe für Linie, Ring, Spur und Rahmen.
    public func color(in scheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        shaded(scheme == .dark ? 1 : (increasedContrast ? 0.42 : 0.62))
    }

    /// Farbe für Werte als Text.
    public func textColor(in scheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        shaded(scheme == .dark ? 1 : (increasedContrast ? 0.42 : 0.5))
    }

    private func shaded(_ factor: Double) -> Color {
        let base = base
        return Color(red: base.red * factor, green: base.green * factor, blue: base.blue * factor)
    }
}

extension EnvironmentValues {
    /// Grafikfarbe einer Messgröße im aktuellen Erscheinungsbild.
    public func instrumentColor(_ hue: InstrumentHue) -> Color {
        hue.color(in: colorScheme, increasedContrast: colorSchemeContrast == .increased)
    }

    /// Textfarbe einer Messgröße im aktuellen Erscheinungsbild.
    public func instrumentTextColor(_ hue: InstrumentHue) -> Color {
        hue.textColor(in: colorScheme, increasedContrast: colorSchemeContrast == .increased)
    }
}
