import SwiftUI

/// Flächen der Instrumententafel, Gestaltung „Lagebild“ (§2.1): Nachtblau als Grund, darauf abgesetzte, abgerundete
/// Panels; hell gleichwertig mit weißen Panels auf hellem Blaugrau.
public enum InstrumentSurface {
    public static let cornerRadius = InstrumentRadius.panel

    static let backgroundDark: Contrast.RGB = (0.043, 0.059, 0.114)
    static let backgroundLight: Contrast.RGB = (0.925, 0.937, 0.961)
    static let panelDark: Contrast.RGB = (0.075, 0.098, 0.169)
    static let panelLight = Contrast.white
    /// Tönung der gewählten Zeile im dunklen Erscheinungsbild.
    static let selectionTintDark: Contrast.RGB = (0.45, 0.50, 0.95)

    public static func background(_ scheme: ColorScheme) -> Color {
        Color(scheme == .dark ? backgroundDark : backgroundLight)
    }

    public static func panel(_ scheme: ColorScheme) -> Color {
        Color(scheme == .dark ? panelDark : panelLight)
    }

    /// Rand eines Panels; die Grenze zum Grund trägt er, die Flächen selbst unterscheiden sich kaum.
    static func border(_ scheme: ColorScheme, increasedContrast: Bool) -> Color {
        let base = scheme == .dark ? Color.white : GrantryBrand.indigo
        if increasedContrast { return Color.primary.opacity(InstrumentOpacity.borderIncreased) }
        return base.opacity(scheme == .dark ? InstrumentOpacity.borderDark : InstrumentOpacity.borderLight)
    }

    /// Grund der gewählten Tabellenzeile.
    public static func selection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(selectionTintDark).opacity(InstrumentOpacity.selectionDark)
            : GrantryBrand.indigo.opacity(InstrumentOpacity.selectionLight)
    }

    /// Gewählte Zeile als Mischfarbe über dem Panel, für Kontrastrechnungen.
    nonisolated static func selectionRGB(dark: Bool) -> Contrast.RGB {
        dark ? Contrast.mix(selectionTintDark, opacity: InstrumentOpacity.selectionDark, over: panelDark)
            : Contrast.mix(GrantryBrand.indigoRGB, opacity: InstrumentOpacity.selectionLight, over: panelLight)
    }
}

extension ShapeStyle where Self == Color {
    /// Sekundärer Text und Symbole der Instrumententafel (§2.2): Vordergrund mit `InstrumentOpacity.secondaryText`. Das
    /// System-`.secondary` erreicht hell auf Panel und gewählter Zeile nur etwa 3 : 1, dieses mindestens 5 : 1 auf
    /// Panel, Grund, Mulde und Auswahl in beiden Erscheinungsbildern.
    public static var instrumentSecondary: Color { .primary.opacity(InstrumentOpacity.secondaryText) }
}
