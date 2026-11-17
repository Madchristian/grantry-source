import GrantryCharts
import ManagerKit
import SwiftUI

/// Katalog unter der Tafel (Spec 2026-11-09-uebersicht-baukasten § 5): die verfügbaren Kacheln, die noch fehlen, mit
/// Symbol, Titel und erlaubten Größen. Zum Hinzufügen auf die Tafel ziehen, oder wählen und ↩ (bzw. Doppelklick oder
/// die VoiceOver-Aktion): hinten anfügen in der Standardgröße.
struct OverviewTileCatalog: View {
    let kinds: [OverviewTileKind]
    let space: NamedCoordinateSpace
    let focus: FocusState<OverviewEditorFocus?>.Binding
    /// Hinten anfügen.
    let add: (OverviewTileKind) -> Void
    /// Ziehen an den Punkt `location` (im Raum des Editors), `nil` beim Loslassen.
    let drag: (OverviewTileKind, _ location: CGPoint?) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: InstrumentSpacing.group),
                                count: OverviewGrid.columns)

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            Text(kinds.isEmpty ? "Katalog – alle Kacheln sind auf der Tafel"
                               : "Katalog – zum Hinzufügen auf die Tafel ziehen oder wählen und ↩")
                .font(InstrumentFont.label)
                .foregroundStyle(.instrumentSecondary)
                .accessibilityAddTraits(.isHeader)
            if !kinds.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: InstrumentSpacing.group) {
                    ForEach(kinds) { kind in
                        OverviewCatalogChip(kind: kind, isFocused: focus.wrappedValue == .catalog(kind),
                                            space: space, select: { focus.wrappedValue = .catalog(kind) }, add: add,
                                            drag: drag)
                            .focused(focus, equals: .catalog(kind))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Katalog"))
        .accessibilityIdentifier("overviewTileCatalog")
    }
}

/// Eintrag des Katalogs.
private struct OverviewCatalogChip: View {
    let kind: OverviewTileKind
    let isFocused: Bool
    let space: NamedCoordinateSpace
    let select: () -> Void
    let add: (OverviewTileKind) -> Void
    let drag: (OverviewTileKind, CGPoint?) -> Void

    private var spans: String { kind.allowedSpans.map(\.description).joined(separator: " · ") }

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            Label(kind.title, systemImage: kind.symbolName)
                .font(InstrumentFont.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(verbatim: spans)
                .font(InstrumentFont.micro)
                .foregroundStyle(.instrumentSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .instrumentPanel(padding: InstrumentSpacing.group, radius: InstrumentRadius.block, focused: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: InstrumentRadius.block, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            add(kind)
            return .handled
        }
        .onTapGesture(count: 2) { add(kind) }
        .onTapGesture(perform: select)
        .gesture(DragGesture(minimumDistance: InstrumentSpacing.inline, coordinateSpace: space)
            .onChanged { drag(kind, $0.location) }
            .onEnded { _ in drag(kind, nil) })
        .pointerStyle(.grabIdle)
        .help(String(localized: "Auf die Tafel ziehen oder doppelklicken"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: kind.title))
        // ax-value: Knopf (isButton) mit eigener Rolle, der Wert kommt an (#520).
        .accessibilityValue(Text("Größen \(spans)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Fügt die Kachel hinten an"))
        .accessibilityAction { add(kind) }
        .accessibilityAction(named: Text("Hinzufügen")) { add(kind) }
        .accessibilityIdentifier("overviewCatalogTile.\(kind.rawValue)")
    }
}
