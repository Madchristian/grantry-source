import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 8): Größe rein, Ansicht raus. Jede Kachel
/// liest aus dem fertigen Stand nur ihren eigenen Wert (`value(from:)`), damit ein Takt nur Kacheln mit geänderten Werten
/// neu auswertet, und passt ihren Inhalt `span` an. Was sie an Quellen braucht, steht im Kit
/// (`OverviewTileKind.requirements`), damit Messung und Tests es ohne SwiftUI kennen.
protocol OverviewTile: View {
    associatedtype Value
    static var kind: OverviewTileKind { get }
    /// Eigener Wert der Kachel; `nil` heißt „nicht gemessen“ (die Kachel bleibt stehen und sagt das).
    static func value(from source: OverviewTileSource) -> Value?
    init(value: Value, span: OverviewTileSpan, open: @escaping () -> Void)
}

/// Fertiger Stand eines Takts für alle Kacheln: Übersicht und Verläufe der letzten Minute (`nil` bei geschlossenem
/// Popover – dann zeichnet keine Kachel einen Graphen).
struct OverviewTileSource {
    let overview: MenuBarOverview
    let history: ChartHistory?
}

/// Kachel ohne gemessenen Wert: Titel und „nicht gemessen“ statt 0 (Spec § 7), in jeder Größe gleich.
struct OverviewTileUnmeasured: View {
    let kind: OverviewTileKind
    let open: () -> Void

    var body: some View {
        OverviewCard(title: kind.title, spokenValue: String(localized: "nicht gemessen"), open: open) {
            Text("nicht gemessen")
                .font(InstrumentFont.label)
                .foregroundStyle(.instrumentSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Platzhalter einer Kachel, deren Ansicht noch fehlt (bis die Teile B und C sie liefern).
struct OverviewTilePlaceholder: View {
    let kind: OverviewTileKind
    let span: OverviewTileSpan

    var body: some View {
        PlaceholderTile(title: kind.title, symbolName: kind.symbolName, columns: span.columns, rows: span.rows)
    }
}
