import SwiftUI

// Übersicht im Lagebild (LB-3.2, #544; Entwurf LB-3.1, #543): Kachelraster und die Panels „Beobachtung“ und „Letzte
// Änderungen“ aus Inhaltsdaten, damit App, Galerie und Snapshot-Tests dieselbe Darstellung zeichnen. Texte und Ziele
// kommen von der App; Knöpfe bleiben native Steuerelemente.

/// Zählkacheln in gleich breiten Spalten: fünf in einer Reihe, im schmalen Fenster drei (3 + 2).
public struct JumpTileGrid<Content: View>: View {
    let columns: Int
    let content: Content

    public init(columns: Int, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: InstrumentSpacing.panel), count: columns),
                  alignment: .leading, spacing: InstrumentSpacing.panel) {
            content
        }
    }
}

/// Panel „Beobachtung“: ohne laufende Beobachtung der Einstieg mit Erklärung und Knopf, sonst Laufzeit im Kopf und die
/// Beobachtung als Sprungzeile.
public struct ObservationOverviewPanel: View {
    public enum State: Hashable, Sendable {
        /// Keine Beobachtung läuft; `isAvailable` sperrt den Knopf ohne Ablage.
        case idle(message: String, isAvailable: Bool)
        /// Kopf „läuft seit 12 Min.“ mit „4 neu“ rechts, darunter die Beobachtung.
        case running(since: String, value: String, row: InstrumentRowContent, destination: String)
    }

    let state: State
    let start: () -> Void
    let show: () -> Void

    public init(state: State, start: @escaping () -> Void, show: @escaping () -> Void) {
        self.state = state
        self.start = start
        self.show = show
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            switch state {
            case .idle(let message, let isAvailable):
                PeilHead(String(localized: "Beobachtung"), detail: String(localized: "keine läuft"))
                Text(verbatim: message)
                    .font(InstrumentFont.body)
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Installation beobachten …"), action: start)
                    .disabled(!isAvailable)
            case .running(let since, let value, let row, let destination):
                PeilHead(String(localized: "Beobachtung"), detail: since, value: value)
                JumpRow(row, destination: destination, action: show)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

/// Panel „Letzte Änderungen“: Sprungzeilen zum Eintrag, rechts „Verlauf anzeigen“; ohne Änderungen ein Hinweis.
public struct RecentChangesOverviewPanel: View {
    /// Eine Änderung: Zeile und Bereich, den der Sprung zeigt.
    public struct Change: Hashable, Sendable, Identifiable {
        public let id: String
        public let row: InstrumentRowContent
        public let destination: String

        public init(id: String, row: InstrumentRowContent, destination: String) {
            self.id = id
            self.row = row
            self.destination = destination
        }
    }

    let changes: [Change]
    let emptyText: String
    let showHistory: () -> Void
    let select: (Change.ID) -> Void

    public init(changes: [Change], emptyText: String, showHistory: @escaping () -> Void,
                select: @escaping (Change.ID) -> Void) {
        self.changes = changes
        self.emptyText = emptyText
        self.showHistory = showHistory
        self.select = select
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            HStack(alignment: .firstTextBaseline) {
                PeilHead(String(localized: "Letzte Änderungen"),
                         detail: changes.isEmpty ? "" : String(localized: "neueste zuerst"))
                Button(String(localized: "Verlauf anzeigen"), action: showHistory)
                    .buttonStyle(.link)
                    .font(InstrumentFont.label)
            }
            if changes.isEmpty {
                InstrumentNote(emptyText, kind: .info)
            } else {
                VStack(spacing: InstrumentSpacing.stack) {
                    ForEach(changes) { change in
                        JumpRow(change.row, destination: change.destination) { select(change.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}
