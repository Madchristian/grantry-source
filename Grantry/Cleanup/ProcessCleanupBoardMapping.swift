import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung des Segments „Prozesse“ (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-4.4, #550): Zustandszeile,
// Stand des Scans, Umfang und Ausgänge an einer Stelle. Texte und Regeln stehen in `ProcessCleanupPresentation` und
// `ProcessCleanupVerdict`.

@MainActor
enum ProcessCleanupBoardMapping {
    /// Zustandszeile; vor dem ersten Ergebnis offene Schildform ohne Chips (Korrektur 3).
    static func head(_ model: ProcessCleanupModel) -> InventoryHead {
        let verdict = ProcessCleanupVerdict(overview: model.overview, isScanning: model.phase == .scanning,
                                            scanError: model.scanError,
                                            survivorCount: model.forceOffer.map(\.survivors.count).reduce(0, +))
        return InventoryHead(verdict: verdict.title, shield: verdict.shield.shieldForm,
                             items: verdict.items.map(\.statusItem), facts: verdict.facts)
    }

    /// Spur neben dem Umschalter: laufender Scan, sonst Stand des letzten Ergebnisses; vor dem ersten Scan keine.
    static func progress(_ model: ProcessCleanupModel) -> CleanupProgress? {
        if let current = model.scanProgress.current { return .scanning(current) }
        guard let overview = model.overview else { return nil }
        let state = ProcessCleanupPresentation.scanState(overview)
        return CleanupProgress(title: state.title, detail: state.detail, fraction: 1,
                               tone: state.isComplete ? .positive : .finding)
    }

    /// Ergebnis-Banner der letzten Aktion; `nil` ohne Aktion.
    static func result(_ outcomes: [ProcessCleanupOutcome]) -> (title: String, message: String, tone: StatusTone)? {
        guard !outcomes.isEmpty else { return nil }
        return (ProcessCleanupPresentation.summary(outcomes), ProcessCleanupPresentation.resultMessage(outcomes),
                ProcessCleanupPresentation.resultTone(outcomes).statusTone)
    }

    /// Ausgang je Posten als Zeile mit Zustandschip (§ 11.4 d).
    static func outcomeStatus(_ outcome: ProcessCleanupOutcome) -> StatusItem {
        ProcessCleanupPresentation.outcomeStatus(outcome).statusItem
    }
}
