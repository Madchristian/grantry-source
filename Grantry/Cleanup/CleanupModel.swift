import Foundation
import ManagerKit
import Observation

/// Zustand des Bereichs „Aufräumen“ (Spec v3 §3): Suche nach Resten gelöschter Apps auf Knopfdruck, Anzeige-Daten und
/// Auswahl. Lebt im `AppModel`, damit das Ergebnis den Wechsel des Bereichs übersteht.
@MainActor
@Observable
final class CleanupModel {
    /// Danach gilt ein Ergebnis als veraltet (Review I1): Reste-Orte und Apps ändern sich auch ohne neuen Scan.
    static let maximumAge: Duration = .seconds(10 * 60)

    let search = CancellableSearch()
    private(set) var presentation: CleanupPresentation?
    var selection = RemovalSelection(preselected: [])
    /// Das Ergebnis ist älter als `maximumAge`.
    private(set) var isExpired = false

    @ObservationIgnored private let scanner: OrphanScanner
    /// Unverändertes Ergebnis der Suche – Quelle des Plans (Kandidaten werden nie neu erzeugt).
    @ObservationIgnored private var result: OrphanScanResult?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init(scanner: OrphanScanner) {
        self.scanner = scanner
    }

    /// Sucht (nur lesend) gegen `snapshot`; das bisherige Ergebnis entfällt sofort.
    func startSearch(in snapshot: Snapshot) {
        let scanner = scanner
        presentation = nil
        result = nil
        expiry?.cancel()
        isExpired = false
        search.start({ await scanner.scan(snapshot) }) { [weak self] result in
            let presentation = CleanupPresentation(result: result)
            self?.result = result
            self?.selection = presentation.initialSelection
            self?.presentation = presentation
            self?.startExpiry()
        }
    }

    /// Ob das Ergebnis nicht mehr zum Stand passt: installierte Apps in `snapshot` haben sich seit der Suche geändert
    /// (oder es liegt keiner vor) oder es ist älter als `maximumAge`. Dann ist der Papierkorb gesperrt.
    func isOutdated(comparedTo snapshot: Snapshot?) -> Bool {
        guard let result else { return false }
        guard let snapshot else { return true }
        return isExpired || result.isOutdated(comparedTo: snapshot)
    }

    private func startExpiry() {
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumAge)
            guard !Task.isCancelled else { return }
            self?.isExpired = true
        }
    }

    /// Plan aus Suchergebnis und Auswahl; `nil` ohne abgeschlossene Suche.
    var plan: RemovalPlan? {
        result.map { RemovalPlanning.plan(cleanup: $0, selection: selection.selected) }
    }
}
