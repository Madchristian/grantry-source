import SwiftUI

// Verlauf im Lagebild (LB-3.3, #545; Entwurf LB-3.1, #543, Spec 2026-11-10 § 11.3 d, e, g): Änderungen nach Tag und
// Belege unter „Wiederherstellbar“ in einem Panel, lazy, ohne Auswahl (eine Zeile führt wie bisher nirgendwohin).
// Aus Inhaltsdaten, damit App, Galerie und Snapshot-Tests dieselbe Darstellung zeichnen; Texte kommen von der App.

/// Eine Zeile des Verlaufs: Änderung oder Beleg ohne geladenes Ereignis.
public struct HistoryEntry: Identifiable, Hashable, Sendable {
    /// Knopf „Wiederherstellen …“ unter der Zeile (§ 11.3 g).
    public enum Restore: Hashable, Sendable {
        /// Bereit; `isEnabled` sperrt ihn, solange eine andere Aktion läuft.
        case available(help: String, isEnabled: Bool)
        /// Diese Wiederherstellung läuft: Knopf gesperrt, daneben Fortschritt mit Text.
        case running
    }

    /// Geänderter Befehl vorher und nachher.
    public struct Command: Hashable, Sendable {
        public let before: String
        public let after: String

        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }
    }

    public let id: String
    /// Name als Titel, darunter Bereich und Art, die Änderung als Chip (§ 11.3 d).
    public let content: InstrumentRowContent
    /// Uhrzeit bzw. relative Zeit rechts.
    public let time: String
    /// Ungelesen: leichter Grund und kleiner Chip (§ 11.3 e).
    public let isUnread: Bool
    public let restore: Restore?
    public let command: Command?
    /// Tooltip: der ganze Satz der Meldung.
    public let help: String?

    public init(id: String, content: InstrumentRowContent, time: String, isUnread: Bool = false,
                restore: Restore? = nil, command: Command? = nil, help: String? = nil) {
        self.id = id
        self.content = content
        self.time = time
        self.isUnread = isUnread
        self.restore = restore
        self.command = command
        self.help = help
    }

    /// Wert für VoiceOver neben dem Namen: „ungelesen, Zustand. Detail, Zeit“.
    public var spokenValue: String {
        [isUnread ? String(localized: "ungelesen") : nil, content.spokenValue, time].compactMap(\.self)
            .joined(separator: ", ")
    }
}

/// Gruppe des Verlaufs: „Wiederherstellbar“ (Leiste im Ton `info`) oder ein Tag.
public struct HistorySection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let tone: StatusTone
    public let entries: [HistoryEntry]

    public init(id: String, title: String, tone: StatusTone = .neutral, entries: [HistoryEntry]) {
        self.id = id
        self.title = title
        self.tone = tone
        self.entries = entries
    }
}

/// Ende der geladenen Seiten.
public enum HistoryLoadMore: Hashable, Sendable {
    case hidden, available, loading
}

/// Zeile einer Änderung: Zeilenkopf mit Chip „ungelesen“ und Zeit, darunter Befehl vorher und nachher und die Knopfzeile
/// „Wiederherstellen …“. Angesprungen (Wachbuch, Benachrichtigung) mit Fläche und Fokusleiste und aufgeklapptem Befehl.
/// Für VoiceOver ein Element mit dem Namen als Beschriftung und „ungelesen, Zustand. Detail, Zeit“ als Wert; Knöpfe eigen.
public struct HistoryRow: View {
    let entry: HistoryEntry
    let isFocused: Bool
    let restore: () -> Void
    let copy: (String) -> Void

    @State private var isExpanded: Bool

    public init(_ entry: HistoryEntry, isFocused: Bool, restore: @escaping () -> Void,
                copy: @escaping (String) -> Void) {
        self.entry = entry
        self.isFocused = isFocused
        self.restore = restore
        self.copy = copy
        _isExpanded = State(initialValue: isFocused)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(spacing: InstrumentSpacing.cell) {
                InstrumentRowLabel(entry.content)
                if entry.isUnread { StatusChip(String(localized: "ungelesen"), tone: .info, isSmall: true) }
                Text(verbatim: entry.time).font(InstrumentFont.label.monospacedDigit())
                    .foregroundStyle(.instrumentSecondary)
                    .lineLimit(1)
            }
            .help(Text(verbatim: entry.help ?? ""))
            .accessibilityReading(Text(verbatim: entry.content.title), value: Text(verbatim: entry.spokenValue))
            if let command = entry.command {
                CommandChangeWell(before: command.before, after: command.after, isExpanded: $isExpanded, copy: copy)
                    .padding(.leading, Self.indent)
            }
            if let restore = entry.restore {
                DetailActions(runningText: restore == .running ? String(localized: "Wird wiederhergestellt …") : nil) {
                    Button(String(localized: "Wiederherstellen …"), action: self.restore)
                        .disabled(!restore.isEnabled)
                        .help(Text(verbatim: restore.help))
                }
                .controlSize(.small)
                .padding(.leading, Self.indent)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
        .instrumentRowBackground(isSelected: isFocused, isSubtle: entry.isUnread)
        .accessibilityElement(children: .contain)
        // Ein Sprung auf eine schon gezeichnete Zeile klappt den Befehl auf.
        .onChange(of: isFocused) { _, focused in if focused { isExpanded = true } }
    }

    /// Einzug unter den Text der Zeile (Symbol und Abstand).
    private static let indent = InstrumentSize.rowIconTall + InstrumentSpacing.cell
}

extension HistoryEntry.Restore {
    var help: String {
        if case .available(let help, _) = self { help } else { "" }
    }

    var isEnabled: Bool {
        if case .available(_, true) = self { true } else { false }
    }
}

/// Verlauf in einem Panel: Gruppen mit Kopf (`InstrumentSectionHeader`), Zeilen, am Ende „Ältere Änderungen laden“.
/// Lazy, ohne eigenen Takt und ohne Übergang. Ist `focusedID` geladen, rollt die Liste dorthin.
public struct HistoryList: View {
    let sections: [HistorySection]
    let focusedID: String?
    let loadMore: HistoryLoadMore
    let restore: (String) -> Void
    let copy: (String) -> Void
    let loadMoreAction: () -> Void

    public init(sections: [HistorySection], focusedID: String?, loadMore: HistoryLoadMore,
                restore: @escaping (String) -> Void, copy: @escaping (String) -> Void,
                loadMoreAction: @escaping () -> Void) {
        self.sections = sections
        self.focusedID = focusedID
        self.loadMore = loadMore
        self.restore = restore
        self.copy = copy
        self.loadMoreAction = loadMoreAction
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ChartScrollView(showsIndicators: true) {
                HistoryRowStack {
                    ForEach(sections) { section in
                        InstrumentSectionHeader(title: section.title, count: section.entries.count, tone: section.tone)
                        ForEach(section.entries) { entry in
                            HistoryRow(entry, isFocused: entry.id == focusedID) { restore(entry.id) } copy: { copy($0) }
                                .id(entry.id)
                        }
                    }
                    if loadMore != .hidden {
                        HistoryLoadMoreRow(isLoading: loadMore == .loading, action: loadMoreAction)
                    }
                }
                .padding(InstrumentSpacing.group)
            }
            // Sprung aus Wachbuch oder Benachrichtigung: zum Eintrag rollen, sobald er geladen ist – ohne Übergang.
            .onChange(of: loadedFocus, initial: true) { _, target in
                if let target { proxy.scrollTo(target, anchor: .center) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
        .instrumentPanel(padding: 0)
    }

    /// `focusedID`, sobald die Zeile geladen ist.
    private var loadedFocus: String? {
        guard let focusedID, sections.contains(where: { $0.entries.contains { $0.id == focusedID } }) else { return nil }
        return focusedID
    }
}

/// Zeilenstapel der Liste: lazy, im Bild für Galerie und Snapshots (`chartSnapshotRendering`) ein `VStack`, weil ein
/// `LazyVStack` außerhalb einer `ScrollView` seine Höhe zu klein meldet.
private struct HistoryRowStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.chartSnapshotRendering) private var snapshot

    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: InstrumentSpacing.stack) { content }
        }
    }
}

/// „Ältere Änderungen laden“ bzw. Fortschritt mit Text.
struct HistoryLoadMoreRow: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            Spacer()
            if isLoading {
                RunningActionLabel(String(localized: "Ältere Änderungen werden geladen …"))
            } else {
                Button(String(localized: "Ältere Änderungen laden"), action: action)
                    .buttonStyle(.link)
                    .font(InstrumentFont.label)
            }
            Spacer()
        }
        .padding(.vertical, InstrumentSpacing.group)
    }
}
