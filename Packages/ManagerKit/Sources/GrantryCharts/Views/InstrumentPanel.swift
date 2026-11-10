import SwiftUI

extension View {
    /// Abgesetztes Panel; `focused` zeichnet den Rand im Grantry-Verlauf (gewählte Karte), `tint` tönt den Grund leicht
    /// in einer Messgröße mit Rand in derselben Farbe (Block im Chip-Grundriss, Kerncluster).
    public func instrumentPanel(padding: CGFloat = InstrumentSpacing.panel, radius: CGFloat = InstrumentRadius.panel,
                                focused: Bool = false, tint: Color? = nil) -> some View {
        modifier(InstrumentPanelModifier(padding: padding, radius: radius, focused: focused, tint: tint))
    }

    /// Grund der Instrumententafel hinter den Panels.
    public func instrumentBackground() -> some View {
        modifier(InstrumentBackgroundModifier())
    }

    /// Aktionsleiste am unteren Rand im Ton der Panels, mit Trennlinie oben.
    public func instrumentBar() -> some View {
        modifier(InstrumentBarModifier())
    }

    /// Grund einer Tabellenzeile: gewählt mit Fläche und Fokusleiste im Grantry-Verlauf, sonst `subtle` (eigene Zeile)
    /// oder leer.
    public func instrumentRowBackground(isSelected: Bool, isSubtle: Bool = false) -> some View {
        modifier(InstrumentRowBackground(isSelected: isSelected, isSubtle: isSubtle))
    }
}

private struct InstrumentPanelModifier: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat
    let focused: Bool
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let increased = contrast == .increased
        content
            .padding(padding)
            .background {
                shape.fill(InstrumentSurface.panel(colorScheme))
                if let tint { shape.fill(tint.opacity(InstrumentOpacity.block)) }
            }
            .overlay {
                if focused {
                    shape.strokeBorder(GrantryBrand.focus(colorScheme), lineWidth: InstrumentStroke.focus)
                } else if let tint {
                    shape.strokeBorder(tint.opacity(increased ? InstrumentOpacity.blockBorderIncreased : InstrumentOpacity.blockBorder),
                                       lineWidth: InstrumentStroke.border)
                } else {
                    shape.strokeBorder(InstrumentSurface.border(colorScheme, increasedContrast: increased),
                                       lineWidth: InstrumentStroke.border)
                }
            }
    }
}

private struct InstrumentBarModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, InstrumentSpacing.bar)
            .padding(.vertical, InstrumentSpacing.cell)
            .background(InstrumentSurface.panel(colorScheme))
            .overlay(alignment: .top) { Divider() }
    }
}

private struct InstrumentBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(InstrumentSurface.background(colorScheme).ignoresSafeArea())
    }
}

private struct InstrumentRowBackground: ViewModifier {
    let isSelected: Bool
    let isSubtle: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.control, style: .continuous)
        content.background {
            if isSelected {
                shape.fill(InstrumentSurface.selection(colorScheme))
                    .overlay(alignment: .leading) {
                        Capsule().fill(GrantryBrand.focus(colorScheme)).frame(width: InstrumentStroke.focusBar)
                            .padding(.vertical, InstrumentSpacing.inline)
                    }
            } else if isSubtle {
                shape.fill(.primary.opacity(InstrumentOpacity.subtle))
            }
        }
    }
}
