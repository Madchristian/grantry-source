import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung des Verlaufs (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-3.3, #545): Zustandszeile, aktiver
// Filter, Gruppen und Zeilen an einer Stelle. Texte und Regeln kommen aus dem Kit (`HistoryVerdict`, `HistoryDay`,
// `ChangeHeadline`), Zuordnung der Belege aus `RestoreMatching`.

enum HistoryBoardMapping {
    /// Kennung der Gruppe „Wiederherstellbar“.
    static let restorableSectionID = "wiederherstellbar"

    // MARK: - Zustandszeile

    /// Zustandszeile über die geladenen Änderungen (Spec § 11.3, Entwurf LB-3.1).
    static func head(_ verdict: HistoryVerdict) -> InventoryHead {
        InventoryHead(verdict: verdict.title, shield: verdict.shield.shieldForm, items: verdict.chips.map(\.statusItem),
                      facts: verdict.facts)
    }

    /// Text der Filterzeile (§ 11.3 f): die abweichenden Teile, etwa „Autostart · Letzte 7 Tage“; `nil` ohne Filter.
    static func filterText(_ filter: HistoryFilter) -> String? {
        guard filter.isActive else { return nil }
        let parts = [filter.category == .all ? nil : filter.category.displayName, filter.kind?.displayName,
                     filter.period == .all ? nil : filter.period.displayName]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    // MARK: - Liste

    /// Belege ohne geladenes Ereignis unter „Wiederherstellbar“, danach die Änderungen nach Tag.
    static func sections(events: [HistoryEvent], restorable: [RestorableChange], now: Date,
                         entry: (HistoryEvent) -> HistoryEntry,
                         restorableEntry: (RestorableChange) -> HistoryEntry) -> [HistorySection] {
        let head = restorable.isEmpty ? [] : [HistorySection(id: restorableSectionID,
                                                             title: String(localized: "Wiederherstellbar"), tone: .info,
                                                             entries: restorable.map(restorableEntry))]
        return head + HistoryDay.days(of: events, now: now).map { day in
            HistorySection(id: day.id.formatted(.iso8601), title: day.title, entries: day.events.map(entry))
        }
    }

    /// Zeile einer Änderung (§ 11.3 d, e): Name als Titel, darunter Bereich und Art, die Änderung als Chip, rechts die
    /// Uhrzeit; ein offener Befund des Eintrags als Chip und Befund-Punkt wie in seinem Bereich.
    static func entry(_ event: HistoryEvent, badges: [RecordBadge], restore: HistoryEntry.Restore?) -> HistoryEntry {
        let change = event.event
        let headline = ChangeHeadline(change)
        let findings = change.kind == .removed ? [] : badges.filter(\.isReview)
        return HistoryEntry(
            id: event.id.uuidString,
            content: InstrumentRowContent(symbol: change.kind.rowSymbol, title: headline.name, detail: headline.detail,
                                          badges: findings.map(\.instrumentBadge), status: change.kind.chipItem,
                                          finding: findings.contains(where: \.isFlagged)),
            time: change.detectedAt.formatted(date: .omitted, time: .shortened),
            isUnread: !event.isRead,
            restore: restore,
            command: change.commandChange.map { HistoryEntry.Command(before: $0.before, after: $0.after) },
            help: ChangeDescription(change).body
        )
    }

    /// Zeile eines Belegs ohne geladenes Ereignis: Name, was geschah und wo, rechts wann.
    static func entry(_ change: RestorableChange, restore: HistoryEntry.Restore, now: Date) -> HistoryEntry {
        HistoryEntry(id: restorableEntryID(change),
                     content: InstrumentRowContent(symbol: "archivebox", title: change.rowTitle, detail: change.rowDetail),
                     time: RelativeTime.text(for: change.changedAt, now: now), restore: restore)
    }

    /// Kennung der Zeile eines Belegs; getrennt von den Ereignissen, damit ein Beleg nie wie ein Ereignis gilt.
    static func restorableEntryID(_ change: RestorableChange) -> String {
        "beleg-\(change.id.uuidString)"
    }

    /// Knopf „Wiederherstellen …“ eines Belegs: läuft, bereit oder gesperrt, solange eine andere Aktion läuft.
    static func restore(_ change: RestorableChange, runningRecordID: String?, canStart: Bool) -> HistoryEntry.Restore {
        runningRecordID == change.id.uuidString
            ? .running : .available(help: change.restoreHelp, isEnabled: canStart)
    }
}

extension HistoryVerdict.Chip {
    /// Chip der Zustandszeile: neu im Ton `info`, Fehler kritisch, sonst ruhig.
    var statusItem: StatusItem {
        switch self {
        case .new: StatusItem(text, tone: .info)
        case .error: StatusItem(text, tone: .critical)
        case .restorable, .missingSources: StatusItem(text, tone: .neutral)
        }
    }
}

extension ChangeEvent.Kind {
    /// Änderung als Chip: neu im Ton `info`, geändert und entfernt ruhig.
    var chipItem: StatusItem {
        StatusItem(chipText, tone: self == .added ? .info : .neutral)
    }
}

extension RecordBadge {
    var isReview: Bool {
        if case .review = self { true } else { false }
    }

    /// Auffällig wie die Kachel „Auffällig“: Befund mittel oder hoch.
    var isFlagged: Bool {
        if case .review(let severity) = self { FindingFilter.flagged.includes(severity) } else { false }
    }
}
