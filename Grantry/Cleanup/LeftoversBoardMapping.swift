import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung von Aufräumen › App-Reste (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-4.2, #548): Zustandszeile,
// Stand der Suche als Spur und Texte der Leiste an einer Stelle.

enum LeftoversBoardMapping {
    /// Zustandszeile (Spec § 11.4, Korrektur 3: vor dem ersten Ergebnis Schildform offen ohne Chips).
    static func head(_ verdict: LeftoverVerdict) -> InventoryHead {
        InventoryHead(verdict: verdict.title, shield: verdict.shield.shieldForm, items: verdict.items.map(\.statusItem),
                      facts: verdict.facts)
    }

    /// Phase der Suche für das Urteil.
    static func phase(_ phase: CancellableSearch.Phase) -> LeftoverVerdict.Phase {
        switch phase {
        case .idle: .idle
        case .searching: .searching
        case .cancelled: .cancelled
        case .finished: .finished
        }
    }

    /// Spur neben dem Umschalter: Fortschritt der laufenden Suche, sonst Stand des Ergebnisses; ohne beides keine Spur.
    /// Der Text der laufenden Suche folgt ihren Schritten (kein eigener Takt).
    static func progress(running: ScanProgress?, presentation: CleanupPresentation?,
                         isOutdated: Bool) -> CleanupProgress? {
        if let running {
            return .scanning(running, title: String(localized: "Suche läuft"))
        }
        guard let presentation else { return nil }
        let time = LeftoverSearchStand.timeText(presentation.searchedAt)
        return switch LeftoverSearchStand(presentation: presentation, isOutdated: isOutdated) {
        case .complete:
            CleanupProgress(title: String(localized: "Suche vollständig"),
                            detail: String(localized: "alle Orte gelesen") + " · " + time, fraction: 1, tone: .positive)
        case .incomplete:
            CleanupProgress(title: String(localized: "Suche unvollständig"),
                            detail: String(localized: "nicht alle Orte gelesen") + " · " + time, fraction: 1,
                            tone: .info)
        case .outdated:
            CleanupProgress(title: String(localized: "Ergebnis veraltet"),
                            detail: time + " · " + String(localized: "Apps seitdem geändert"), fraction: 1,
                            tone: .finding)
        }
    }

    /// Umfang in der Leiste; ohne Ergebnis „Nichts ausgewählt“.
    static func scope(_ presentation: CleanupPresentation?, selection: RemovalSelection) -> String {
        presentation?.summary(for: selection) ?? String(localized: "Nichts ausgewählt")
    }

    /// Eine Erweiterung ohne App als Eintrag auf der Mulde: Name, Art und Hersteller, Zustand, Befund-Punkt.
    static func extensionContent(_ leftover: ExtensionLeftover) -> InstrumentRowContent {
        InstrumentRowContent(symbol: leftover.reference.symbol, title: leftover.reference.title,
                             detail: leftover.reference.subtitle, finding: true)
    }

    /// Berechtigungen eines Dienstes: Dienst als Name, die entfernten Apps als Detail.
    static func grantContent(_ group: CleanupPresentation.GrantService) -> InstrumentRowContent {
        InstrumentRowContent(symbol: PermissionCatalog.service(for: group.service).systemImage,
                             title: group.serviceName,
                             detail: group.grants.map(\.client.displayName).joined(separator: ", "))
    }
}
