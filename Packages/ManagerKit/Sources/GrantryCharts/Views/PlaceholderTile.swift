import SwiftUI

/// Platzhalter einer Kachel im Übersichts-Baukasten (Spec 2026-11-09-uebersicht-baukasten § 8): gestrichelter Rahmen mit
/// Symbol, Titel und Größe. Steht für Kacheln, deren Ansicht noch fehlt, in Tests und im Editor, bis die echten Kacheln
/// da sind; zeigt wie jede Kachel in 1 × 1 nur das Nötigste.
public struct PlaceholderTile: View {
    let title: String
    let symbolName: String
    let columns: Int
    let rows: Int

    public init(title: String, symbolName: String, columns: Int, rows: Int) {
        self.title = title
        self.symbolName = symbolName
        self.columns = columns
        self.rows = rows
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous)
        Group {
            if columns == 1 {
                VStack(spacing: InstrumentSpacing.inline) {
                    Image(systemName: symbolName).font(InstrumentFont.title)
                    Text(verbatim: title).font(InstrumentFont.label).lineLimit(1).minimumScaleFactor(0.8)
                }
            } else {
                VStack(spacing: InstrumentSpacing.stack) {
                    Label { Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)) } icon: {
                        Image(systemName: symbolName)
                    }
                    .lineLimit(1)
                    Text(verbatim: "\(columns) × \(rows)").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                }
            }
        }
        .foregroundStyle(.instrumentSecondary)
        .padding(InstrumentSpacing.item)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(.quaternary.opacity(InstrumentOpacity.track)))
        .overlay(shape.strokeBorder(.instrumentSecondary,
                                    style: StrokeStyle(lineWidth: InstrumentStroke.border,
                                                       dash: [InstrumentSpacing.inline, InstrumentSpacing.inline])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(columns) × \(rows)"))
    }
}
