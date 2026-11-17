import GrantryCharts
import SwiftUI

/// Rahmen einer Kachel im Bearbeitungsmodus (Spec 2026-11-09-uebersicht-baukasten § 5): gestrichelt, gewählt im
/// Grantry-Verlauf; „Entfernen“ links oben, Größengriff rechts unten. Beide ragen etwas über die Kachel hinaus, damit
/// sie neben dem Inhalt treffbar bleiben.
struct OverviewEditChrome<Handle: Gesture>: View {
    let title: String
    let isSelected: Bool
    let remove: () -> Void
    let handle: Handle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous)
        ZStack {
            if isSelected {
                shape.strokeBorder(GrantryBrand.focus(colorScheme), lineWidth: InstrumentStroke.focus)
            } else {
                // Zurückhaltend neben dem Inhalt; „Kontrast erhöhen“ zieht ihn auf die Sekundärfarbe.
                shape.strokeBorder(contrast == .increased ? Color.instrumentSecondary
                                                          : Color.primary.opacity(InstrumentOpacity.secondaryLine),
                                   style: StrokeStyle(lineWidth: InstrumentStroke.border,
                                                      dash: [InstrumentSpacing.inline, InstrumentSpacing.inline]))
            }
            Button(action: remove) {
                OverviewEditBadge(symbolName: "minus", fill: AnyShapeStyle(.instrumentSecondary))
            }
            .buttonStyle(.plain)
            .help(String(localized: "\(title) entfernen"))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: -InstrumentSpacing.item, y: -InstrumentSpacing.item)
            OverviewEditBadge(symbolName: "arrow.up.left.and.arrow.down.right",
                              fill: isSelected ? AnyShapeStyle(GrantryBrand.focus(colorScheme))
                                               : AnyShapeStyle(.instrumentSecondary))
                .contentShape(Circle())
                .pointerStyle(.frameResize(position: .bottomTrailing))
                .gesture(handle)
                .help(String(localized: "Ziehen ändert die Größe"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: InstrumentSpacing.item, y: InstrumentSpacing.item)
        }
        // VoiceOver bedient die Kachel über ihre Aktionen (`OverviewEditableTile`), nicht über diese Knöpfe.
        .accessibilityHidden(true)
    }
}

/// Runder Knopf am Rand einer Kachel: Symbol im Ton des Panels auf `fill`, deckend über Rahmen und Inhalt.
private struct OverviewEditBadge: View {
    let symbolName: String
    let fill: AnyShapeStyle

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: symbolName)
            .font(InstrumentFont.micro.weight(.bold))
            .foregroundStyle(InstrumentSurface.panel(colorScheme))
            .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
            .background(Circle().fill(InstrumentSurface.panel(colorScheme)).overlay(Circle().fill(fill)))
    }
}

/// Platz, an dem die gezogene Kachel einrasten würde.
struct OverviewDropSlot: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous)
        shape.fill(InstrumentSurface.selection(colorScheme))
            .overlay(shape.strokeBorder(GrantryBrand.focus(colorScheme),
                                        style: StrokeStyle(lineWidth: InstrumentStroke.focus,
                                                           dash: [InstrumentSpacing.item, InstrumentSpacing.inline])))
            .accessibilityHidden(true)
    }
}
