import SwiftUI

// Beobachtungen im Lagebild (LB-3.4, #546; Entwurf LB-3.1, #543, Spec 2026-11-10 §11.3): Detail einer Beobachtung mit
// Kopf, Hinweisen, Bilanz als Zählkacheln, Einträgen je Art als Sprungzeilen, Aufräumen mit Häkchenzeilen und früheren
// Durchgängen; Leerzustand des Bereichs und Blatt „Installation beobachten“ (§11.3 h). Inhalte kommen als Daten von der
// App, damit App, Galerie und Snapshot-Tests dieselbe Darstellung zeichnen. Knöpfe und Textfelder bleiben native
// Steuerelemente; Bestätigungen und die Rückfrage beim Start bleiben Systemdialoge der App.

/// Ein Eintrag der Bilanz als Sprungzeile in den Bereich `destination` (entfernte in den Verlauf).
public struct ObservationEntryRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let content: InstrumentRowContent
    public let destination: String

    public init(id: String, content: InstrumentRowContent, destination: String) {
        self.id = id
        self.content = content
        self.destination = destination
    }
}

/// Einträge einer Art („Neue Apps“, „Geänderte Einträge“) mit optionalem Hinweis unter der Überschrift.
public struct ObservationEntryGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let note: DetailNoteContent?
    public let rows: [ObservationEntryRow]

    public init(id: String, title: String, note: DetailNoteContent? = nil, rows: [ObservationEntryRow]) {
        self.id = id
        self.title = title
        self.note = note
        self.rows = rows
    }
}

/// Bilanz als drei Zählkacheln, darunter der Satz; `note` erklärt eine leere Bilanz (Entwarnung nur bei voller Abdeckung).
public struct ObservationBalanceContent: Hashable, Sendable {
    public let new: Int
    public let modified: Int
    public let removed: Int
    public let summary: String
    public let note: DetailNoteContent?

    public init(new: Int, modified: Int, removed: Int, summary: String, note: DetailNoteContent? = nil) {
        self.new = new
        self.modified = modified
        self.removed = removed
        self.summary = summary
        self.note = note
    }
}

/// Ein früherer Aufräum-Durchgang: Zeitpunkt mit Ergebnis, danach je Eintrag Name und Ausgang mit Ton.
public struct ObservationRecordContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let facts: [DetailFactContent]

    public init(id: String, facts: [DetailFactContent]) {
        self.id = id
        self.facts = facts
    }
}

/// Inhalt des Details einer Beobachtung; gleichwertig vergleichbar, damit ein unverändertes Detail nicht neu zeichnet.
public struct ObservationDetailContent: Hashable, Sendable {
    public let title: String
    /// Zeitraum, etwa „10. Nov. 2026, 10:12 – 10:31 (19 Min.)“.
    public let subtitle: String
    public let status: StatusItem
    /// Befund-Punkt am Kopf: die Bilanz ist unvollständig.
    public let finding: Bool
    /// Schlüssel-Wert-Zeilen unter dem Kopf (Notiz).
    public let facts: [DetailFactContent]
    public let notes: [DetailNoteContent]
    public let balance: ObservationBalanceContent?
    public let groups: [ObservationEntryGroup]
    public let records: [ObservationRecordContent]

    public init(title: String, subtitle: String, status: StatusItem, finding: Bool = false,
                facts: [DetailFactContent] = [], notes: [DetailNoteContent] = [],
                balance: ObservationBalanceContent? = nil, groups: [ObservationEntryGroup] = [],
                records: [ObservationRecordContent] = []) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.finding = finding
        self.facts = facts
        self.notes = notes
        self.balance = balance
        self.groups = groups
        self.records = records
    }
}

/// Detail-Panel einer Beobachtung: Kopf, Knopfzeile (`actions`), Fortschritt oder Anleitung (`progress`), Notiz,
/// Hinweise, Bilanz, Einträge je Art (`rowAccessory` unter jeder Zeile, etwa der geänderte Befehl), Aufräumen
/// (`cleanup`) und frühere Durchgänge.
public struct ObservationDetailPanel<Actions: View, Progress: View, RowAccessory: View, Cleanup: View>: View {
    let content: ObservationDetailContent
    let select: (ObservationEntryRow) -> Void
    let actions: Actions
    let progress: Progress
    let rowAccessory: (ObservationEntryRow) -> RowAccessory
    let cleanup: Cleanup

    public init(content: ObservationDetailContent, select: @escaping (ObservationEntryRow) -> Void,
                @ViewBuilder actions: () -> Actions, @ViewBuilder progress: () -> Progress,
                @ViewBuilder rowAccessory: @escaping (ObservationEntryRow) -> RowAccessory,
                @ViewBuilder cleanup: () -> Cleanup) {
        self.content = content
        self.select = select
        self.actions = actions()
        self.progress = progress()
        self.rowAccessory = rowAccessory
        self.cleanup = cleanup()
    }

    public var body: some View {
        DetailPanel {
            DetailHead(symbol: "binoculars", title: content.title, subtitle: content.subtitle, items: [content.status],
                       finding: content.finding)
            actions
            progress
            ForEach(content.facts, id: \.self) { DetailEntry($0.key, value: $0.value, tone: $0.tone) }
            if !content.notes.isEmpty {
                DetailGroup(String(localized: "Hinweise"), count: content.notes.count) {
                    ForEach(content.notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
                }
            }
            if let balance = content.balance { ObservationBalanceGroup(balance) }
            ForEach(content.groups) { group in
                DetailGroup(group.title, count: group.rows.count) {
                    if let note = group.note { InstrumentNote(note.text, kind: note.kind) }
                    VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                        ForEach(group.rows) { row in
                            JumpRow(row.content, destination: row.destination) { select(row) }
                            rowAccessory(row)
                        }
                    }
                }
            }
            cleanup
            if !content.records.isEmpty {
                DetailGroup(String(localized: "Aufgeräumt"), count: content.records.count) {
                    ForEach(content.records) { record in
                        ForEach(record.facts, id: \.self) { DetailEntry($0.key, value: $0.value, tone: $0.tone) }
                    }
                }
            }
        }
    }
}

/// Gruppe „Bilanz“: Neu, Geändert, Entfernt als Zählkacheln, darunter der Satz und gegebenenfalls die Erklärung.
/// VoiceOver liest je Kachel die Art als Beschriftung und die Zahl als Wert.
public struct ObservationBalanceGroup: View {
    let content: ObservationBalanceContent

    public init(_ content: ObservationBalanceContent) {
        self.content = content
    }

    public var body: some View {
        DetailGroup(String(localized: "Bilanz")) {
            HStack(spacing: InstrumentSpacing.group) {
                tile(String(localized: "Neu"), value: content.new, tone: .info)
                tile(String(localized: "Geändert"), value: content.modified, tone: .neutral)
                tile(String(localized: "Entfernt"), value: content.removed, tone: .neutral)
            }
            Text(verbatim: content.summary).font(InstrumentFont.body.weight(.medium))
            if let note = content.note { InstrumentNote(note.text, kind: note.kind) }
        }
    }

    private func tile(_ title: String, value: Int, tone: StatusTone) -> some View {
        CountTile(title: title, value: value, tone: tone)
            .accessibilityReading(Text(verbatim: title), value: Text(verbatim: value.formatted()))
    }
}

// MARK: - Aufräumen

/// Ein noch vorhandener neuer Eintrag zum Ankreuzen; `offersLeftovers` zeigt bei Apps „Mit Resten entfernen …“.
public struct ObservationCleanupRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let size: String
    public let hint: StatusItem?
    /// Tooltip der Zeile, etwa warum die Zuordnung unsicher ist.
    public let help: String?
    public let lockedReason: String?
    public let offersLeftovers: Bool

    public init(id: String, title: String, detail: String, size: String, hint: StatusItem? = nil, help: String? = nil,
                lockedReason: String? = nil, offersLeftovers: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.size = size
        self.hint = hint
        self.help = help
        self.lockedReason = lockedReason
        self.offersLeftovers = offersLeftovers
    }
}

/// Inhalt der Gruppe „Aufräumen“: Zeilen, Hinweise, Erklärung und Zustand des Knopfs „Ausgewähltes entfernen …“.
public struct ObservationCleanupContent: Hashable, Sendable {
    public let rows: [ObservationCleanupRow]
    public let notes: [DetailNoteContent]
    public let footnote: String
    /// Ohne Angebot (noch kein Scan) steht kein Knopf.
    public let offersAction: Bool
    public let canRemove: Bool
    public let canRemoveWithLeftovers: Bool
    /// Zeilen gesperrt, solange eine Aktion vorbereitet wird oder läuft.
    public let isLocked: Bool
    public let runningText: String?

    public init(rows: [ObservationCleanupRow], notes: [DetailNoteContent] = [], footnote: String,
                offersAction: Bool, canRemove: Bool, canRemoveWithLeftovers: Bool, isLocked: Bool = false,
                runningText: String? = nil) {
        self.rows = rows
        self.notes = notes
        self.footnote = footnote
        self.offersAction = offersAction
        self.canRemove = canRemove
        self.canRemoveWithLeftovers = canRemoveWithLeftovers
        self.isLocked = isLocked
        self.runningText = runningText
    }

    /// Derselbe Inhalt mit laufender Aktion: Zeilen und Knöpfe gesperrt, Text neben dem Knopf.
    public func running(_ text: String?) -> Self {
        guard let text else { return self }
        return Self(rows: rows, notes: notes, footnote: footnote, offersAction: offersAction, canRemove: false,
                    canRemoveWithLeftovers: false, isLocked: true, runningText: text)
    }
}

/// Gruppe „Aufräumen“ (§11.3): Häkchenzeilen (Vorauswahl bleibt beim Modell), bei Apps „Mit Resten entfernen …“,
/// Hinweise und Erklärung, unten rechts „Ausgewähltes entfernen …“ mit laufender Aktion daneben.
public struct ObservationCleanupGroup: View {
    let content: ObservationCleanupContent
    let isSelected: (String) -> Binding<Bool>
    let removeWithLeftovers: (String) -> Void
    let remove: () -> Void

    public init(content: ObservationCleanupContent, isSelected: @escaping (String) -> Binding<Bool>,
                removeWithLeftovers: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.content = content
        self.isSelected = isSelected
        self.removeWithLeftovers = removeWithLeftovers
        self.remove = remove
    }

    public var body: some View {
        DetailGroup(String(localized: "Aufräumen"), count: content.rows.count) {
            if !content.rows.isEmpty {
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    ForEach(content.rows) { row in
                        HStack(spacing: InstrumentSpacing.group) {
                            SelectionCheckRow(row.title, detail: row.detail, size: row.size, isOn: isSelected(row.id),
                                              hint: row.hint, lockedReason: row.lockedReason)
                                .disabled(content.isLocked)
                                .help(row.help.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
                            if row.offersLeftovers {
                                Button(String(localized: "Mit Resten entfernen …")) { removeWithLeftovers(row.id) }
                                    .buttonStyle(.link)
                                    .font(InstrumentFont.label)
                                    .disabled(!content.canRemoveWithLeftovers)
                            }
                        }
                    }
                }
            }
            ForEach(content.notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
            InstrumentNote(content.footnote, kind: .info)
            if content.offersAction {
                HStack(spacing: InstrumentSpacing.group) {
                    Spacer(minLength: 0)
                    DetailActions(runningText: content.runningText) {
                        Button(String(localized: "Ausgewähltes entfernen …"), role: .destructive, action: remove)
                            .disabled(!content.canRemove)
                    }
                }
            }
        }
    }
}

// MARK: - Bereich ohne Beobachtungen

/// Bereich ohne gespeicherte Beobachtung: Zustandszeile und darunter über die ganze Breite der Leerzustand mit dem
/// Knopf zum Starten (`action`); Seitenrand und Grund wie `InventoryBoard`.
public struct ObservationsEmptyBoard<Action: View>: View {
    let head: InventoryHead
    let message: String
    let action: Action

    public init(head: InventoryHead, message: String, @ViewBuilder action: () -> Action) {
        self.head = head
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: head.verdict, shield: head.shield, items: head.items, facts: head.facts)
            VStack(spacing: InstrumentSpacing.group) {
                InstrumentEmptyState(symbol: "binoculars", title: String(localized: "Keine Beobachtungen"),
                                     message: message)
                action
            }
            .padding(.bottom, InstrumentSpacing.empty)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .instrumentPanel()
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }
}

// MARK: - Blatt

/// Blatt „Installation beobachten“ im Lagebild (§11.3 h): Peilkopf ohne Ring, Erklärung, Name und Notiz als
/// Schlüssel-Wert-Zeilen mit nativen Textfeldern, Hinweise, Fortschritt (`progress`) und native Knöpfe unten rechts.
/// Abbrechen mit Escape, Starten mit Return.
public struct ObservationStartForm<Progress: View>: View {
    @Binding var name: String
    @Binding var note: String
    let notes: [DetailNoteContent]
    let isBusy: Bool
    let canStart: Bool
    let cancel: () -> Void
    let start: () -> Void
    let progress: Progress

    public init(name: Binding<String>, note: Binding<String>, notes: [DetailNoteContent], isBusy: Bool, canStart: Bool,
                cancel: @escaping () -> Void, start: @escaping () -> Void, @ViewBuilder progress: () -> Progress) {
        _name = name
        _note = note
        self.notes = notes
        self.isBusy = isBusy
        self.canStart = canStart
        self.cancel = cancel
        self.start = start
        self.progress = progress()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            PeilHead(String(localized: "Installation beobachten"), detail: String(localized: "hält den Ausgangsstand fest"))
            Text("Grantry hält jetzt fest, was auf dem Mac eingerichtet ist. Installiere danach das Tool und starte es einmal; beim Beenden der Beobachtung zeigt Grantry, was seitdem hinzugekommen ist – und räumt es auf Wunsch wieder auf.")
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                DetailEntry(String(localized: "Name")) {
                    TextField(String(localized: "Name"), text: $name, prompt: Text("z. B. Cursor"))
                        .labelsHidden()
                }
                DetailEntry(String(localized: "Notiz")) {
                    TextField(String(localized: "Notiz (optional)"), text: $note, prompt: Text("optional"),
                              axis: .vertical)
                        .lineLimit(2...4)
                        .labelsHidden()
                }
            }
            .disabled(isBusy)
            ForEach(notes, id: \.self) { InstrumentNote($0.text, kind: $0.kind) }
            progress
            HStack(spacing: InstrumentSpacing.group) {
                Spacer(minLength: 0)
                Button(String(localized: "Abbrechen"), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Beobachtung starten"), action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(InstrumentSpacing.empty)
    }
}
