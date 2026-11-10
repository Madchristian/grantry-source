import SwiftUI

/// Darstellung nach den Bedienungshilfen des Systems (Spec §4): „Bewegung reduzieren“ schaltet Übergänge und
/// Zurückfedern ab, „Kontrast erhöhen“ zeichnet kräftige Linien ohne Glow, „Ohne Farbe unterscheiden“ nutzt die
/// farbenblind-taugliche Palette.
public struct ChartStyle: Equatable, Sendable {
    public var animates: Bool
    public var glows: Bool
    public var lineWidth: CGFloat
    /// Ersetzt jede Palette, wenn gesetzt.
    public var paletteOverride: ChartPalette?

    public static func resolve(reduceMotion: Bool, increasedContrast: Bool, differentiateWithoutColor: Bool) -> ChartStyle {
        ChartStyle(animates: !reduceMotion, glows: !increasedContrast,
                   lineWidth: increasedContrast ? InstrumentStroke.lineIncreased : InstrumentStroke.line,
                   paletteOverride: increasedContrast ? .highContrast : differentiateWithoutColor ? .colorblindSafe : nil)
    }

    public func palette(_ preferred: ChartPalette) -> ChartPalette { paletteOverride ?? preferred }
}

extension EnvironmentValues {
    /// Gesetzt, solange das Fenster der Graphen nicht sichtbar ist (Spec §4: verdeckt, minimiert, Popover zu):
    /// Übergänge stehen wie bei „Bewegung reduzieren“, Farben und Glow bleiben. Die App setzt den Wert über
    /// `pausesChartsWhileHidden()`.
    @Entry public var chartRenderingPaused = false

    /// Aus den Bedienungshilfen abgeleiteter Graphenstil; angehalten, solange `chartRenderingPaused` gilt.
    public var chartStyle: ChartStyle {
        ChartStyle.resolve(reduceMotion: accessibilityReduceMotion || chartRenderingPaused,
                           increasedContrast: colorSchemeContrast == .increased,
                           differentiateWithoutColor: accessibilityDifferentiateWithoutColor)
    }
}
