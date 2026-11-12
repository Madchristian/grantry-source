import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung der Autostart-Einträge (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-2.3, #540): eine Stelle für
// Zustandszeile, Listenzeilen und Detail, damit Liste und Detail denselben Eintrag gleich zeigen.

enum AutostartBoardMapping {
    /// Zustandszeile (Spec §11.2 a) über alle Einträge, unabhängig von Suche und Filter.
    static func head(_ presentation: PresentationSnapshot?, scannedAt: Date?) -> InventoryHead {
        guard let presentation else {
            return InventoryVerdict.notScanned.head(facts: String(localized: "kein Scan seit dem Start"))
        }
        let items = presentation.autostartSections.flatMap(\.items)
        let coverage = presentation.coverage[.autostart]
        let verdict = InventoryVerdict.autostart(
            items, badges: presentation.badges,
            missingSources: coverage.map { $0.isComplete ? 0 : max($0.gaps.count, 1) } ?? 0
        )
        var facts = items.count == 1 ? String(localized: "1 Eintrag") : String(localized: "\(items.count) Einträge")
        if let scannedAt {
            facts += " · " + String(localized: "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))")
        }
        return verdict.head(facts: facts)
    }

    /// Liste je Art (Anmeldeobjekte, LaunchAgents, LaunchDaemons, Hintergrundobjekte); Gruppen mit Befund mit Punkt.
    static func sections(_ sections: [AutostartSection],
                         presentation: PresentationSnapshot) -> [InstrumentListSection<String>] {
        sections.map { section in
            InstrumentListSection(id: section.title, title: section.title, finding: section.isFlagged,
                                  items: section.items.map { item($0, presentation: presentation) })
        }
    }

    static func item(_ item: AutostartItem, presentation: PresentationSnapshot) -> InstrumentListItem<String> {
        InstrumentListItem(id: item.id, content: row(
            item, badges: presentation.badges.badges(for: item.id),
            sharesService: !presentation.autostartItems(sharingServiceWith: item).isEmpty
        ))
    }

    /// Zeile: Label, Besitzer bzw. Programm (bei gleichem Label in mehreren Plists auch die Datei, #138), Prüf-Badges,
    /// „alter Stand“ und aktiv bzw. deaktiviert als Zustand; Befund-Punkt bei einem Prüfhinweis.
    static func row(_ item: AutostartItem, badges: [RecordBadge], sharesService: Bool = false) -> InstrumentRowContent {
        var detail = [item.owner?.displayName ?? item.program]
        if sharesService, let plistPath = item.plistPath {
            detail.append(URL(fileURLWithPath: plistPath).lastPathComponent)
        }
        let statuses = item.statusBadges
        return InstrumentRowContent(
            symbol: item.kind.systemImage, title: item.label, detail: detail.compactMap(\.self).joined(separator: " · "),
            badges: badges.map(\.instrumentBadge) + statuses.filter { $0 == .outdated }.map(\.instrumentBadge),
            status: statuses.first.map(\.statusItem),
            finding: badges.contains { if case .review = $0 { true } else { false } }
        )
    }

    // MARK: - Detail

    /// Kennung der Gruppe „Programm“; ihr Zubehör sind Hinweis zum Befehl und „Befehl kopieren“.
    static let programGroupID = "programm"

    /// Detail (`RecordDetailPanel`): Kopf mit Art und Bereich, Badges und allen Zuständen; Gruppen „Hinweise“ (alter
    /// Stand, Befunde, Aufräumen; Spec §11.2 c), „Programm“ (Besitzer, Pfad, Vorhandensein, Signatur, Befehl) und „Ort“
    /// (Plist, gleiches Label, Session-Typen). Den Grund des Schreibschutzes zeigt die Ansicht vor der Knopfzeile.
    static func detail(_ item: AutostartItem, presentation: PresentationSnapshot, now: Date) -> RecordDetailContent {
        var notes = item.verificationNote(now: now).map { [DetailNoteContent($0, kind: .finding)] } ?? []
        notes += presentation.findings(for: item.id).map {
            DetailNoteContent($0.message, kind: RecordBadge.review($0.severity).noteKind)
        }
        if let cleanup = presentation.cleanupHint(for: item.id) {
            notes.append(DetailNoteContent(cleanup.message, kind: .info))
        }
        let sharing = presentation.autostartItems(sharingServiceWith: item).compactMap(\.plistPath)
        let place = place(of: item, sharing: sharing)
        let groups = [
            notes.isEmpty ? nil
                : DetailGroupContent(id: "hinweise", title: String(localized: "Hinweise"), count: notes.count,
                                     notes: notes),
            DetailGroupContent(id: programGroupID, title: String(localized: "Programm"), facts: program(of: item)),
            place.isEmpty ? nil : DetailGroupContent(
                id: "ort", title: String(localized: "Ort"), facts: place,
                notes: sharing.isEmpty ? [] : [DetailNoteContent(String(localized:
                    "launchd führt je Label nur einen Dienst; Aktivieren/Deaktivieren ist dann gesperrt."), kind: .info)]
            ),
        ]
        return RecordDetailContent(
            symbol: item.kind.systemImage, title: item.label,
            subtitle: "\(item.kind.displayName) · \(item.domain.displayName)",
            items: presentation.badges.badges(for: item.id).map(\.statusItem) + item.statusBadges.map(\.statusItem),
            finding: presentation.highestSeverity(for: item.id) != nil,
            groups: groups.compactMap(\.self)
        )
    }

    private static func program(of item: AutostartItem) -> [DetailFactContent] {
        let owner = item.owner.map { owner in owner.bundleID.map { "\(owner.displayName) (\($0))" } ?? owner.displayName }
        var facts = [
            DetailFactContent(String(localized: "Besitzer-App"), value: owner ?? String(localized: "unbekannt")),
            DetailFactContent(String(localized: "Programm"), value: item.program ?? String(localized: "Unbekannt"),
                              isCode: item.program != nil),
        ]
        if item.program != nil, item.programPresence != .present {
            facts.append(DetailFactContent(String(localized: "Programm auf dem Mac"),
                                           value: item.programPresence.displayName))
        }
        if let signing = item.programSigning {
            facts.append(DetailFactContent(String(localized: "Signatur"), value: signing.fullText,
                                           tone: signing.tone.statusTone))
        }
        if let commandLine = item.displayedCommandLine {
            facts.append(DetailFactContent(String(localized: "Befehl"), value: commandLine, isCode: true))
        }
        return facts
    }

    private static func place(of item: AutostartItem, sharing: [String]) -> [DetailFactContent] {
        var facts = item.plistPath.map { [DetailFactContent(String(localized: "Plist"), value: $0, isCode: true)] } ?? []
        facts += sharing.map { DetailFactContent(String(localized: "Gleiches Label auch in"), value: $0, isCode: true) }
        if let sessionTypes = item.sessionTypes, !sessionTypes.isEmpty {
            facts.append(DetailFactContent(String(localized: "Session-Typen"),
                                           value: sessionTypes.joined(separator: ", ")))
        }
        return facts
    }
}

extension AutostartStatus {
    /// Zustand als Chip im Detailkopf bzw. als Zustand der Zeile.
    var statusItem: StatusItem { StatusItem(title, tone: tone.statusTone) }
}
