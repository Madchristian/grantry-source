import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung der Beobachtungen (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-3.4, #546; Entwurf LB-3.1, #543):
// Zustandszeile, Listenzeilen, Detail, Aufräumen und frühere Durchgänge an einer Stelle. Texte der Bilanz, Hinweise,
// Vorauswahl und Bestätigungen kommen unverändert aus ManagerKit.

enum ObservationsBoardMapping {
    static let symbol = MainSection.observations.systemImage

    // MARK: - Zustandszeile

    /// Zustandszeile ohne Urteil (Schildform „offen“): ob eine Beobachtung läuft, mit ihren neuen Einträgen als Chip;
    /// rechts die Zahl der Beobachtungen.
    static func head(summaries: [ObservationSummary], liveAddedCount: Int?) -> InventoryHead {
        let isRunning = summaries.contains(where: \.isActive)
        let verdict = summaries.isEmpty ? String(localized: "Keine Beobachtung")
            : isRunning ? String(localized: "1 Beobachtung läuft") : String(localized: "Keine Beobachtung läuft")
        let items = isRunning
            ? liveAddedCount.map { [StatusItem(ObservationTexts.entries($0), tone: .info)] } ?? [] : []
        let facts = switch summaries.count {
        case 0: String(localized: "0 gespeichert")
        case 1: String(localized: "1 Beobachtung")
        default: String(localized: "\(summaries.count) Beobachtungen")
        }
        return InventoryHead(verdict: verdict, shield: .open, items: items, facts: facts)
    }

    // MARK: - Liste

    /// Gruppen „Läuft“ und „Gespeichert“; Zeile mit Start, Zahl neuer Einträge und „aufgeräumt“ wie bisher.
    static func sections(_ summaries: [ObservationSummary], liveAddedCount: Int?) -> [InstrumentListSection<UUID>] {
        let item = { (summary: ObservationSummary) in
            InstrumentListItem(id: summary.id, content: InstrumentRowContent(
                symbol: symbol, title: summary.name,
                detail: listDetail(summary, liveAddedCount: liveAddedCount),
                status: summary.isActive ? StatusItem(String(localized: "läuft"), tone: .info) : nil
            ))
        }
        let running = summaries.filter(\.isActive).map(item)
        let saved = summaries.filter { !$0.isActive }.map(item)
        return [
            running.isEmpty ? nil : InstrumentListSection(id: "laeuft", title: String(localized: "Läuft"), tone: .info,
                                                          items: running),
            saved.isEmpty ? nil : InstrumentListSection(id: "gespeichert", title: String(localized: "Gespeichert"),
                                                        items: saved),
        ].compactMap(\.self)
    }

    /// „10.11.2026, 10:12 · 5 neue Einträge · aufgeräumt“.
    static func listDetail(_ summary: ObservationSummary, liveAddedCount: Int?) -> String {
        let start = summary.startedAt.formatted(date: .abbreviated, time: .shortened)
        let count = summary.isActive ? liveAddedCount : summary.addedCount
        let entries = count.map { ObservationTexts.entries($0) }
        let cleanups = summary.cleanupCount > 0 ? String(localized: "aufgeräumt") : nil
        return [start, entries, cleanups].compactMap(\.self).joined(separator: " · ")
    }

    // MARK: - Detail

    /// Detail einer Beobachtung: Kopf mit Zeitraum und Zustand, Notiz, bei beendeten Hinweise und Bilanz, Einträge je
    /// Art (laufend gegen den jüngsten Scan) und frühere Aufräum-Durchgänge.
    static func detail(_ observation: InstallationObservation, presentation: ObservationBalancePresentation?,
                       balance: ObservationBalance?) -> ObservationDetailContent {
        let notes = balance.map(notes) ?? []
        return ObservationDetailContent(
            title: observation.name, subtitle: period(observation),
            status: observation.isActive ? StatusItem(String(localized: "läuft"), tone: .info)
                : StatusItem(String(localized: "beendet"), tone: .neutral),
            finding: notes.contains { $0.kind == .finding },
            facts: observation.note.map { [DetailFactContent(String(localized: "Notiz"), value: $0)] } ?? [],
            notes: notes,
            balance: observation.isActive ? nil : finishedBalance(presentation, balance),
            groups: presentation.map(groups) ?? [],
            records: observation.cleanups.enumerated().map(record)
        )
    }

    /// „10.11.2026, 10:12 – 10:31 (19 Min.)“, laufend „Seit 11.11.2026, 14:20“.
    static func period(_ observation: InstallationObservation) -> String {
        let start = observation.startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let end = observation.finishedAt else { return String(localized: "Seit \(start)") }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
            + " (\(ObservationTexts.duration(from: observation.startedAt, to: end)))"
    }

    /// Hinweise der Bilanz: unlesbare Quellen und Einschränkungen als Befund (Bilanz unvollständig), sonst Hinweis.
    static func notes(_ balance: ObservationBalance) -> [DetailNoteContent] {
        let names = { (sources: Set<SourceID>) in sources.sorted { $0.rawValue < $1.rawValue }.map(\.displayName) }
        let findings = [
            ObservationTexts.failedSourcesNote(names(balance.failedSources)),
            ObservationTexts.limitationsNote(balance.limitations.map { "\($0.source.displayName): \($0.message)" }),
        ].compactMap(\.self).map { DetailNoteContent($0, kind: .finding) }
        let infos = [ObservationTexts.firstDeliveredNote(names(balance.firstDeliveredSources)), ObservationTexts.userTCCNote]
            .compactMap(\.self).map { DetailNoteContent($0, kind: .info) }
        return findings + infos
    }

    private static func finishedBalance(_ presentation: ObservationBalancePresentation?,
                                        _ balance: ObservationBalance?) -> ObservationBalanceContent? {
        guard let presentation, let balance else { return nil }
        return balanceContent(presentation, balance)
    }

    /// Bilanz als Zählkacheln; eine leere Bilanz erklärt sich (Entwarnung nur bei vollständiger Abdeckung).
    static func balanceContent(_ presentation: ObservationBalancePresentation,
                               _ balance: ObservationBalance) -> ObservationBalanceContent {
        ObservationBalanceContent(
            new: balance.addedCount, modified: balance.events.count { $0.kind == .modified },
            removed: balance.events.count { $0.kind == .removed }, summary: presentation.summary,
            note: presentation.isEmpty ? DetailNoteContent(presentation.emptyMessage, kind: .info) : nil
        )
    }

    /// Einträge je Art als Sprungzeilen; die ID der Zeile ist die der Bilanz (`ObservationBalancePresentation.Row`).
    static func groups(_ presentation: ObservationBalancePresentation) -> [ObservationEntryGroup] {
        presentation.sections.map { section in
            ObservationEntryGroup(
                id: section.group.title, title: section.group.title,
                note: section.group.note.map { DetailNoteContent($0, kind: noteKind(section.group.tone)) },
                rows: section.rows.map { ObservationEntryRow(id: $0.id, content: rowContent($0),
                                                             destination: MainSection(showing: $0.event).title) }
            )
        }
    }

    private static func noteKind(_ tone: PresentationTone) -> InstrumentNote.Kind {
        switch tone {
        case .critical: .critical
        case .warning: .finding
        case .positive, .neutral: .info
        }
    }

    /// Zeile der Bilanz: Text der Änderung als Titel, darunter ihre Art, die Zuordnung als Badge (unsicher mit Befund-
    /// Punkt), die Änderung als Chip.
    static func rowContent(_ row: ObservationBalancePresentation.Row) -> InstrumentRowContent {
        let title = row.body.split(separator: "\n").first.map(String.init) ?? row.title
        let badges = row.verdict.map { [verdictBadge($0)] } ?? []
        return InstrumentRowContent(
            symbol: row.event.kind.rowSymbol, title: title, detail: row.title, badges: badges,
            status: StatusItem(row.event.kind.chipText, tone: row.event.kind == .added ? .info : .neutral),
            finding: row.verdict.map { !$0.isLikely } ?? false
        )
    }

    /// „wahrscheinlich zugehörig“ bzw. „Zuordnung unsicher“; VoiceOver liest die Begründung mit.
    static func verdictBadge(_ verdict: ObservationAttribution.Verdict) -> InstrumentBadge {
        let title = verdict.isLikely ? ObservationTexts.likelyBadge : ObservationTexts.uncertainBadge
        return InstrumentBadge(title, tone: verdict.isLikely ? .neutral : .finding, spoken: "\(title), \(verdict.reason)")
    }

    /// Früherer Durchgang: Zeitpunkt mit „2 von 3 erledigt“, danach je Eintrag sein Ausgang.
    static func record(_ index: Int, _ record: ObservationCleanupRecord) -> ObservationRecordContent {
        let head = DetailFactContent(record.performedAt.formatted(date: .abbreviated, time: .shortened),
                                     value: String(localized: "\(record.doneCount) von \(record.entries.count) erledigt"))
        let entries = record.entries.map { entry in
            DetailFactContent(entry.title,
                              value: entry.reason ?? (entry.isDone ? String(localized: "erledigt")
                                  : String(localized: "nicht erledigt")),
                              tone: entry.isDone ? .positive : .critical)
        }
        return ObservationRecordContent(id: "\(index)", facts: [head] + entries)
    }

    // MARK: - Aufräumen

    /// Erklärung unter dem Aufräumen (Text wie bisher).
    static let cleanupFootnote = String(localized: "Angeboten wird, was von den neuen Einträgen heute noch existiert. Vorausgewählt ist nur, was wahrscheinlich zum Tool gehört; geänderte Einträge setzt Grantry nicht zurück. Von Apps geht nur das Programm selbst in den Papierkorb – Reste wählst du einzeln über „Mit Resten entfernen …“.")

    /// Aufräumen gegen den aktuellen Stand; ohne Angebot (noch kein Scan) nur der Hinweis, kein Knopf.
    static func cleanup(offer: ObservationCleanupOffer?, hasSelection: Bool, canStart: Bool, isPreparing: Bool,
                        isRunning: Bool) -> ObservationCleanupContent {
        guard let offer else {
            return ObservationCleanupContent(
                rows: [], notes: [DetailNoteContent(String(localized: "Erst nach dem nächsten Scan verfügbar."), kind: .info)],
                footnote: cleanupFootnote, offersAction: false, canRemove: false, canRemoveWithLeftovers: false)
        }
        var notes: [DetailNoteContent] = []
        if offer.candidates.isEmpty {
            notes.append(DetailNoteContent(String(localized: "Keiner der neuen Einträge ist noch vorhanden."), kind: .info))
        }
        if offer.goneCount > 0 {
            notes.append(DetailNoteContent(offer.goneCount == 1
                ? String(localized: "1 neuer Eintrag ist nicht mehr (oder nicht mehr unverändert) vorhanden.")
                : String(localized: "\(offer.goneCount) neue Einträge sind nicht mehr (oder nicht mehr unverändert) vorhanden."),
                kind: .info))
        }
        let content = ObservationCleanupContent(
            rows: offer.candidates.map(cleanupRow), notes: notes, footnote: cleanupFootnote, offersAction: true,
            canRemove: hasSelection && canStart && !isPreparing, canRemoveWithLeftovers: canStart && !isPreparing,
            isLocked: isPreparing
        )
        if isPreparing { return content.running(String(localized: "Wird vorbereitet …")) }
        return isRunning ? content.running(String(localized: "Wird aufgeräumt …")) : content
    }

    /// Häkchenzeile eines noch vorhandenen neuen Eintrags; „Zuordnung unsicher“ als Chip mit Begründung im Tooltip.
    static func cleanupRow(_ candidate: ObservationCleanupCandidate) -> ObservationCleanupRow {
        let verdict = candidate.verdict
        let isApp = if case .installedApp = candidate.subject { true } else { false }
        return ObservationCleanupRow(
            id: candidate.id, title: candidate.title, detail: "\(candidate.detail()) — \(verdict.reason)", size: "–",
            hint: verdict.isLikely ? nil : StatusItem(ObservationTexts.uncertainBadge, tone: .finding),
            help: verdict.isLikely ? nil : ObservationTexts.uncertainExplanation,
            lockedReason: candidate.unavailableReason,
            offersLeftovers: isApp && candidate.unavailableReason == nil
        )
    }
}

