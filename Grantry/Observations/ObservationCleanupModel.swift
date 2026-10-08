import ManagerKit
import Observation

/// Aufräumen aus einer beendeten Beobachtung (#127): Angebot gegen den **aktuellen** Snapshot, Auswahl und – für
/// gewählte Apps – die Reste-Suche, aus der der Plan entsteht. Ausgeführt wird über den `ActionRunner`.
@MainActor
@Observable
final class ObservationCleanupModel {
    let observation: InstallationObservation
    let balance: ObservationBalance
    let attribution: ObservationAttribution
    private(set) var offer: ObservationCleanupOffer?
    var selection = RemovalSelection(preselected: [])
    /// Die Reste-Suche für gewählte Apps läuft.
    private(set) var isPreparing = false

    init?(observation: InstallationObservation) {
        guard let balance = observation.balance else { return nil }
        self.observation = observation
        self.balance = balance
        attribution = ObservationAttribution(observationName: observation.name, newApps: balance.newApps)
    }

    /// Gleicht das Angebot mit dem aktuellen Snapshot ab. Die Auswahl bleibt für weiterhin angebotene Einträge erhalten;
    /// beim ersten Abgleich gilt die Vorauswahl.
    func refresh(current: Snapshot?) {
        guard let current else { return offer = nil }
        let isFirst = offer == nil
        let updated = ObservationCleanupOffer(balance: balance, attribution: attribution, current: current)
        let offered = Set(updated.candidates.map(\.id))
        selection = isFirst ? updated.initialSelection : RemovalSelection(preselected: selection.selected.intersection(offered))
        offer = updated
    }

    /// Plan aus der Auswahl beim Aufruf (Änderungen während der Suche zählen nicht – die Schalter sind dann ohnehin
    /// gesperrt); sucht vorher für gewählte Apps nach dem App-Bundle samt Identität (nur lesend). `nil` ohne Angebot oder
    /// Snapshot.
    func preparePlan(scanner: LeftoverScanner, snapshot: Snapshot?) async -> ObservationCleanupPlan? {
        guard let offer, let snapshot, !isPreparing else { return nil }
        let selection = selection
        isPreparing = true
        defer { isPreparing = false }
        var leftovers: [String: LeftoverScanResult] = [:]
        for case .installedApp(let app) in offer.candidates.filter({ selection.contains($0.id) }).map(\.subject) {
            leftovers[app.id] = await scanner.scan(for: app, installedApps: snapshot.installedApps)
        }
        return ObservationCleanupPlanning.plan(
            observationID: observation.id, offer: offer, selection: selection, leftovers: leftovers, snapshot: snapshot
        )
    }

    var hasSelection: Bool {
        offer?.candidates.contains { selection.contains($0.id) && $0.unavailableReason == nil } == true
    }
}
