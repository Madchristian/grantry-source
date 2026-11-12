import SwiftUI

// Detail eines Eintrags im Lagebild aus Inhaltsdaten (LB-2.4, #541; Entwurf LB-2.1, #538): Kopf, Knopfzeile, Hinweise
// ohne Gruppe direkt darunter (Spec §11.2 c und d), danach Gruppen mit Schlüssel-Wert-Zeilen und Hinweisen. Was je Gruppe
// bedient wird (Dateiknöpfe, Sprungzeilen), liefert die Ansicht über `accessory`. Erst für Agenten (MCP-Server und
// Freigaben); gedacht für jedes Detail ohne Einträge auf der Mulde (für die gibt es `GrantDetailPanel`).

/// Gruppe im Detail: Überschrift mit optionaler Anzahl, Schlüssel-Wert-Zeilen, danach Hinweise.
public struct DetailGroupContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let count: Int?
    public let facts: [DetailFactContent]
    public let notes: [DetailNoteContent]

    public init(id: String, title: String, count: Int? = nil, facts: [DetailFactContent] = [],
                notes: [DetailNoteContent] = []) {
        self.id = id
        self.title = title
        self.count = count
        self.facts = facts
        self.notes = notes
    }
}

/// Inhalt des Details eines Eintrags; gleichwertig vergleichbar, damit ein unverändertes Detail nicht neu zeichnet.
public struct RecordDetailContent: Hashable, Sendable {
    /// SF-Symbol im Kopf, wenn die Ansicht kein eigenes Symbol liefert.
    public let symbol: String
    public let title: String
    public let subtitle: String
    public let items: [StatusItem]
    public let finding: Bool
    /// Hinweise ohne Gruppe direkt unter Kopf und Knopfzeile.
    public let notes: [DetailNoteContent]
    public let groups: [DetailGroupContent]

    public init(symbol: String, title: String, subtitle: String, items: [StatusItem] = [], finding: Bool = false,
                notes: [DetailNoteContent] = [], groups: [DetailGroupContent] = []) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.finding = finding
        self.notes = notes
        self.groups = groups
    }
}

/// Detail-Panel eines Eintrags: Kopf, Knopfzeile (`actions`), Hinweise, Gruppen; `accessory` steht am Ende jeder Gruppe.
public struct RecordDetailPanel<Icon: View, Actions: View, Accessory: View>: View {
    let content: RecordDetailContent
    let icon: Icon
    let actions: Actions
    let accessory: (DetailGroupContent) -> Accessory

    public init(content: RecordDetailContent, @ViewBuilder icon: () -> Icon, @ViewBuilder actions: () -> Actions,
                @ViewBuilder accessory: @escaping (DetailGroupContent) -> Accessory) {
        self.content = content
        self.icon = icon()
        self.actions = actions()
        self.accessory = accessory
    }

    public var body: some View {
        DetailPanel {
            DetailHead(title: content.title, subtitle: content.subtitle, items: content.items,
                       finding: content.finding) { icon }
            actions
            ForEach(content.notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
            ForEach(content.groups) { group in
                DetailGroup(group.title, count: group.count) {
                    ForEach(group.facts, id: \.self) { fact in
                        DetailEntry(fact.key, value: fact.value, tone: fact.tone, isCode: fact.isCode)
                    }
                    ForEach(group.notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
                    accessory(group)
                }
            }
        }
    }
}

extension RecordDetailPanel where Icon == InstrumentRowIcon, Actions == EmptyView, Accessory == EmptyView {
    /// Nur Anzeige mit SF-Symbol, ohne Knöpfe (Galerie, Tests).
    public init(content: RecordDetailContent) {
        self.init(content: content) {
            InstrumentRowIcon(symbol: content.symbol, size: InstrumentSize.shield)
        } actions: {
            EmptyView()
        } accessory: { _ in
            EmptyView()
        }
    }
}
