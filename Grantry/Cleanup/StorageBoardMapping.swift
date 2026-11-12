import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung des Speichers (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-4.3, #549; Entwurf LB-4.1, #547):
// Zustandszeile, Spur neben dem Umschalter, Kopf je Kategorie, Ausgänge und Banner an einer Stelle.

enum StorageBoardMapping {
    // MARK: - Zustandszeile

    /// Vor dem ersten Ergebnis und während des Scans die offene Schildform ohne Chips (Korrektur 3); danach die
    /// aufräumbare Größe, ohne vollständige Erfassung mit Befund.
    static func head(reports: [StorageCategoryReport], timeMachine: TimeMachineReport?,
                     isScanning: Bool) -> InventoryHead {
        if isScanning {
            return InventoryHead(verdict: String(localized: "Scan läuft"), shield: .open, items: [],
                                 facts: String(localized: "\(StoragePresentation.categoryCountText(reports.count)) gelesen"))
        }
        guard !reports.isEmpty else {
            return InventoryHead(verdict: String(localized: "Noch nicht gescannt"), shield: .open, items: [],
                                 facts: String(localized: "liest nur auf Knopfdruck"))
        }
        let uncovered = StoragePresentation.uncoveredPaths(reports).count
        let unread = reports.count { StoragePresentation.statusTone($0.status).map { $0 != .neutral } ?? false }
        let suggestions = timeMachine?.suggestions.count ?? 0
        let candidates: [StatusItem?] = [
            uncovered > 0 ? StatusItem(uncovered == 1 ? String(localized: "1 Ordner nicht erfasst")
                                           : String(localized: "\(uncovered) Ordner nicht erfasst"), tone: .finding) : nil,
            unread > 0 ? StatusItem(unread == 1 ? String(localized: "1 Kategorie nicht gelesen")
                                        : String(localized: "\(unread) Kategorien nicht gelesen"), tone: .finding) : nil,
            suggestions > 0 ? StatusItem(suggestions == 1 ? String(localized: "1 Vorschlag Time Machine")
                                             : String(localized: "\(suggestions) Vorschläge Time Machine"),
                                         tone: .neutral) : nil,
        ]
        return InventoryHead(verdict: StoragePresentation.cleanableText(reports),
                             finding: !StoragePresentation.isComplete(reports), items: candidates.compactMap(\.self),
                             facts: StoragePresentation.categoryCountText(reports.count))
    }

    // MARK: - Spur neben dem Umschalter

    /// Scan-Fortschritt als Spur (ohne bekannten Anteil leere Bahn); danach der Stand des Ergebnisses; vor dem ersten
    /// Scan keine Spur.
    static func progress(_ scan: ScanProgress?, reports: [StorageCategoryReport]) -> CleanupProgress? {
        if let scan { return .scanning(scan) }
        guard !reports.isEmpty else { return nil }
        let detail = String(localized: "\(StoragePresentation.categoryCountText(reports.count)) gelesen")
        return StoragePresentation.isComplete(reports)
            ? CleanupProgress(title: String(localized: "Scan vollständig"), detail: detail, fraction: 1, tone: .positive)
            : CleanupProgress(title: String(localized: "Scan unvollständig"), detail: detail, fraction: 1, tone: .finding)
    }

    // MARK: - Kategorien

    static func risk(_ risk: StorageRisk) -> StatusItem {
        StatusItem(StoragePresentation.riskText(risk), tone: .neutral)
    }

    static func status(_ status: StorageCategoryStatus) -> StatusItem? {
        guard let text = StoragePresentation.statusText(status), let tone = StoragePresentation.statusTone(status) else {
            return nil
        }
        return StatusItem(text, tone: tone.statusTone)
    }

    /// Satz der Kategorie, bei Time-Machine-Vorschlag mit „Time Machine: …“ (#227).
    static func summary(_ report: StorageCategoryReport, timeMachineNote: String?) -> String {
        [report.category.summary, timeMachineNote].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// Ort und Zusatzzeile eines Eintrags („~/Library/… · zuletzt benutzt vor 9 Tagen“).
    static func detail(_ item: StorageItem) -> String {
        [item.path.map(abbreviated), item.detail].compactMap(\.self).joined(separator: " · ")
    }

    // MARK: - Ausgänge

    static func outcomeChip(_ outcome: StorageCleanOutcome) -> StatusItem {
        StatusItem(StoragePresentation.outcomeState(outcome), tone: StoragePresentation.outcomeTone(of: outcome).statusTone)
    }

    /// Ziel mit Weg, etwa „~/Library/Caches/x (Papierkorb)“.
    static func outcomeTarget(_ outcome: StorageCleanOutcome) -> String {
        "\(abbreviated(outcome.target)) (\(StoragePresentation.methodText(outcome.method)))"
    }

    /// Eintrag in „Zuletzt aufgeräumt“: „10.11.2026, 18:04 – ~/Downloads/x.dmg“.
    static func logTarget(_ entry: CleanupLogEntry) -> String {
        "\(entry.date.formatted(date: .abbreviated, time: .shortened)) – \(abbreviated(entry.outcome.target))"
    }

    /// Pfade mit `~` statt des Benutzerordners; Befehlszeilen bleiben unverändert.
    static func abbreviated(_ target: String) -> String { (target as NSString).abbreviatingWithTildeInPath }
}
