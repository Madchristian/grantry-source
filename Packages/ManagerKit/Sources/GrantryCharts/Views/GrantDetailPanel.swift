import SwiftUI

// Detail einer Gruppe von Berechtigungen im Lagebild (LB-2.2, #539; Entwurf LB-2.1, #538): eine App mit ihren
// Berechtigungen oder eine Berechtigung mit ihren Apps. Kopf, Knopfzeile, Hinweise, Angaben und je Berechtigung ein
// Eintrag auf der Mulde mit Zustandschip, Hinweisen und Knöpfen (Spec §11.1 c, §11.2 c und d). Symbole, Knöpfe und
// weitere Gruppen (Autostart einer App) liefert die Ansicht der App.

/// Hinweis im Detail: Text und Art (`InstrumentNote`).
public struct DetailNoteContent: Hashable, Sendable {
    public let text: String
    public let kind: InstrumentNote.Kind

    public init(_ text: String, kind: InstrumentNote.Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Schlüssel-Wert-Zeile im Detail (`DetailEntry`).
public struct DetailFactContent: Hashable, Sendable {
    public let key: String
    public let value: String
    public let tone: StatusTone?
    public let isCode: Bool

    public init(_ key: String, value: String, tone: StatusTone? = nil, isCode: Bool = false) {
        self.key = key
        self.value = value
        self.tone = tone
        self.isCode = isCode
    }
}

/// Eine Berechtigung im Detail: Zeilenkopf, Hinweise und laufende Aktion.
public struct GrantEntryContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let row: InstrumentRowContent
    public let notes: [DetailNoteContent]
    public let runningText: String?

    public init(id: String, row: InstrumentRowContent, notes: [DetailNoteContent] = [], runningText: String? = nil) {
        self.id = id
        self.row = row
        self.notes = notes
        self.runningText = runningText
    }
}

/// Inhalt des Details einer App bzw. einer Berechtigung.
public struct GrantDetailContent: Hashable, Sendable {
    /// SF-Symbol im Kopf, wenn die Ansicht kein eigenes Symbol (App-Symbol) liefert.
    public let symbol: String
    public let title: String
    public let subtitle: String
    public let items: [StatusItem]
    public let finding: Bool
    public let notes: [DetailNoteContent]
    public let facts: [DetailFactContent]
    /// Überschrift der Gruppe mit den Berechtigungen („Berechtigungen“ bzw. „Apps“).
    public let grantsTitle: String
    public let emptyGrantsText: String
    public let grants: [GrantEntryContent]

    public init(symbol: String, title: String, subtitle: String, items: [StatusItem] = [], finding: Bool = false,
                notes: [DetailNoteContent] = [], facts: [DetailFactContent] = [], grantsTitle: String,
                emptyGrantsText: String, grants: [GrantEntryContent]) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.finding = finding
        self.notes = notes
        self.facts = facts
        self.grantsTitle = grantsTitle
        self.emptyGrantsText = emptyGrantsText
        self.grants = grants
    }
}

/// Detail-Panel einer App mit ihren Berechtigungen bzw. einer Berechtigung mit ihren Apps: Kopf, darunter die Knopfzeile
/// (`actions`), Hinweise, Angaben, die Berechtigungen als Einträge mit `grantActions` und zuletzt `extra`.
public struct GrantDetailPanel<Icon: View, Actions: View, GrantIcon: View, GrantActions: View, Extra: View>: View {
    let content: GrantDetailContent
    let icon: Icon
    let actions: Actions
    let grantIcon: (GrantEntryContent) -> GrantIcon
    let grantActions: (GrantEntryContent) -> GrantActions
    let extra: Extra

    public init(content: GrantDetailContent, @ViewBuilder icon: () -> Icon, @ViewBuilder actions: () -> Actions,
                @ViewBuilder grantIcon: @escaping (GrantEntryContent) -> GrantIcon,
                @ViewBuilder grantActions: @escaping (GrantEntryContent) -> GrantActions,
                @ViewBuilder extra: () -> Extra) {
        self.content = content
        self.icon = icon()
        self.actions = actions()
        self.grantIcon = grantIcon
        self.grantActions = grantActions
        self.extra = extra()
    }

    public var body: some View {
        DetailPanel {
            DetailHead(title: content.title, subtitle: content.subtitle, items: content.items,
                       finding: content.finding) { icon }
            actions
            ForEach(content.notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
            if !content.facts.isEmpty {
                DetailGroup(String(localized: "Angaben")) {
                    ForEach(content.facts, id: \.self) { fact in
                        DetailEntry(fact.key, value: fact.value, tone: fact.tone, isCode: fact.isCode)
                    }
                }
            }
            DetailGroup(content.grantsTitle, count: content.grants.count) {
                if content.grants.isEmpty {
                    Text(verbatim: content.emptyGrantsText).font(InstrumentFont.body)
                        .foregroundStyle(.instrumentSecondary)
                }
                ForEach(content.grants) { grant in
                    DetailItem(grant.row, runningText: grant.runningText) {
                        grantIcon(grant)
                    } notes: {
                        ForEach(grant.notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
                    } actions: {
                        grantActions(grant)
                    }
                }
            }
            extra
        }
    }
}

extension GrantDetailPanel where Icon == InstrumentRowIcon, Actions == EmptyView, GrantIcon == InstrumentRowIcon,
    GrantActions == EmptyView, Extra == EmptyView {
    /// Nur Anzeige mit SF-Symbolen, ohne Knöpfe (Galerie, Tests).
    public init(content: GrantDetailContent) {
        self.init(content: content) {
            InstrumentRowIcon(symbol: content.symbol, size: InstrumentSize.shield)
        } actions: {
            EmptyView()
        } grantIcon: {
            InstrumentRowIcon(symbol: $0.row.symbol)
        } grantActions: { _ in
            EmptyView()
        } extra: {
            EmptyView()
        }
    }
}
