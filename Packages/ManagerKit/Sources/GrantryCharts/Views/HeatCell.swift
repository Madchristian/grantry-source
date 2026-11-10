import SwiftUI

/// Tabellenzelle mit Hitze (§2.6, Prozessliste): Grund in der Farbe der Messgröße der Spalte, Deckkraft nach Last
/// (`HeatShade`). Ohne Wert (`heat == nil`) bleibt der Grund leer. Ab `emphasisThreshold` halbfett, bei „Kontrast
/// erhöhen“ zusätzlich mit Rand. Werte und Grund wechseln ohne Übergang: In einer nach CPU sortierten Tabelle wechselt
/// fast in jedem Takt irgendeine Zelle die Stufe, und jeder Übergang (`ValueTransition`) zeichnete die Tabelle 0,3 s lang
/// im Bildtakt neu – rund die Hälfte der Last von „Prozesse“ (Bewertung 2026.11.9, Mangel 2, #478).
public struct HeatCell: View {
    static let emphasisThreshold = 0.7

    let text: String
    let heat: Double?
    let hue: InstrumentHue

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.self) private var environment

    public init(_ text: String, heat: Double?, hue: InstrumentHue = .cpu) {
        self.text = text
        self.heat = heat.map { min(max($0, 0), 1) }
        self.hue = hue
    }

    public var body: some View {
        let heat = heat ?? 0
        let dark = colorScheme == .dark
        let color = environment.instrumentColor(hue)
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
        // Zählpunkt am Text: Hier kommt jede Animation an – aus der Zelle selbst oder von außen, etwa animiertes
        // Umsortieren.
        Text(verbatim: text)
            .renderProbe("HeatCell")
            .font(InstrumentFont.numeric)
            .fontWeight(heat >= Self.emphasisThreshold ? .semibold : .regular)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.inline + 1)
            .background {
                shape.fill(color.opacity(HeatShade.opacity(forHeat: heat, hue: hue, dark: dark)))
                    .overlay {
                        if contrast == .increased && heat >= 0.5 {
                            shape.strokeBorder(color, lineWidth: InstrumentStroke.border)
                        }
                    }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: text))
    }
}

/// Grund einer Zelle im Chip-Tab (Kern, Taktstufe; §2.6): Messgrößenfarbe nach Hitze unter Schrift `.primary`,
/// mindestens wie ein Chip sichtbar, bei „Kontrast erhöhen“ ab der Hälfte mit Rand.
struct HeatTile: View {
    let heat: Double
    let hue: InstrumentHue

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.self) private var environment

    var body: some View {
        let heat = min(max(heat.isFinite ? heat : 0, 0), 1)
        let color = environment.instrumentColor(hue)
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
        shape.fill(color.opacity(max(HeatShade.opacity(forHeat: heat, hue: hue, dark: colorScheme == .dark),
                                     InstrumentOpacity.chip)))
            .overlay {
                if contrast == .increased && heat >= 0.5 {
                    shape.strokeBorder(color, lineWidth: InstrumentStroke.border)
                }
            }
    }
}
