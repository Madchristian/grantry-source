import SwiftUI

/// Suchfeld im Inhalt über einer Tabelle (§3.7): Lupe, Eingabe und Löschen-Knopf auf der Mulde als Kapsel. Ersetzt
/// `.searchable` in der Symbolleiste, wo das Feld die Tabs des Task-Managers verdrängte (Bewertung 2026.11.7, Mangel 8).
/// Der Platzhalter dient zugleich als Bedienungshilfen-Kennung (UI-Tests). Im Bild (`ImageRenderer`) statt des
/// AppKit-Felds ein gezeichneter Text.
public struct InstrumentSearchField: View {
    @Binding var text: String
    let prompt: String

    @Environment(\.chartSnapshotRendering) private var snapshot
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String) {
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            Image(systemName: "magnifyingglass").foregroundStyle(.instrumentSecondary).accessibilityHidden(true)
            if snapshot {
                Text(verbatim: text.isEmpty ? prompt : text).foregroundStyle(text.isEmpty ? .instrumentSecondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .accessibilityIdentifier(prompt)
                    .accessibilityLabel(Text(verbatim: prompt))
                    .accessibilityAddTraits(.isSearchField)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.instrumentSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Suche leeren"))
            }
        }
        .font(InstrumentFont.body)
        .lineLimit(1)
        .padding(.horizontal, InstrumentSpacing.cell)
        .padding(.vertical, InstrumentSpacing.item)
        .background(Capsule().fill(.primary.opacity(InstrumentOpacity.well)))
        .overlay {
            if isFocused { Capsule().strokeBorder(.tint, lineWidth: InstrumentStroke.border) }
        }
        .frame(maxWidth: InstrumentSize.columnWide)
    }
}
