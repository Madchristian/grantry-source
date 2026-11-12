import Foundation

/// Texte des Speichers im Lagebild (LB-4.3, #549; Spec 2026-11-10 § 11.4): Zustandszeile, Spur je Kategorie, Umfang der
/// Auswahl in der Aktionsleiste und Ergebnis der letzten Aktion als Banner mit Ausgang je Eintrag.
extension StoragePresentation {
    /// „28,4 GB aufräumbar“ über alle Kategorien; mit unbekannten Größen „mindestens …“.
    public static func cleanableText(_ reports: [StorageCategoryReport]) -> String {
        "\(RemovalSize(sizes: reports.flatMap { $0.items.map(\.size) }).text) aufräumbar"
    }

    /// Anteil der Kategorie an der bekannten Gesamtgröße für die Spur; `nil` ohne bekannte Größe.
    public static func share(of report: StorageCategoryReport, in reports: [StorageCategoryReport]) -> Double? {
        let total = reports.reduce(Int64(0)) { $0 + $1.knownBytes }
        guard total > 0, report.knownBytes > 0 else { return nil }
        return Double(report.knownBytes) / Double(total)
    }

    /// Umfang der Auswahl: „Ausgewählt: 2 Einträge · 13,1 GB“, sonst „Nichts ausgewählt“.
    public static func selectionText(reports: [StorageCategoryReport], selection: Set<String>) -> String {
        let items = selectedItems(in: reports, selection: selection).flatMap(\.1)
        guard !items.isEmpty else { return "Nichts ausgewählt" }
        let count = items.count == 1 ? "1 Eintrag" : "\(items.count) Einträge"
        return "Ausgewählt: \(count) · \(RemovalSize(sizes: items.map(\.size)).text)"
    }

    /// „1 Kategorie“, „9 Kategorien“.
    public static func categoryCountText(_ count: Int) -> String {
        count == 1 ? "1 Kategorie" : "\(count) Kategorien"
    }

    /// Alle Kategorien gelesen, alle Ordner erfasst – sonst keine Entwarnung.
    public static func isComplete(_ reports: [StorageCategoryReport]) -> Bool {
        uncoveredPaths(reports).isEmpty && !reports.contains { report in
            switch report.status {
            case .needsFullDiskAccess, .failed: true
            case .available, .notInstalled: false
            }
        }
    }

    /// Ton des Status-Chips einer Kategorie; `nil` ohne Status.
    public static func statusTone(_ status: StorageCategoryStatus) -> PresentationTone? {
        switch status {
        case .available: nil
        case .notInstalled: .neutral
        case .needsFullDiskAccess: .warning
        case .failed: .critical
        }
    }

    /// Titel des Ergebnis-Banners: „2 Einträge aufgeräumt“, „1 von 2 Einträgen aufgeräumt“; nur Time-Machine-Änderungen
    /// „Time Machine geändert: 1 von 2“.
    public static func outcomeTitle(_ outcomes: [StorageCleanOutcome]) -> String {
        let done = outcomes.count { $0.result == .removed }
        if outcomes.allSatisfy({ isTimeMachine($0.method) }) {
            return "Time Machine geändert: \(done) von \(outcomes.count)"
        }
        if done == outcomes.count { return done == 1 ? "1 Eintrag aufgeräumt" : "\(done) Einträge aufgeräumt" }
        return "\(done) von \(outcomes.count) Einträgen aufgeräumt"
    }

    /// Ton des Ergebnis-Banners: positiv nur, wenn alles erledigt ist; Fehlschläge kritisch.
    public static func outcomeTone(_ outcomes: [StorageCleanOutcome]) -> PresentationTone {
        if outcomes.contains(where: { if case .failed = $0.result { true } else { false } }) { return .critical }
        return outcomes.allSatisfy { $0.result == .removed } ? .positive : .warning
    }

    /// Zustandschip eines Ausgangs: „aufgeräumt“, „ausgenommen“, „wieder gesichert“, „übersprungen“, „fehlgeschlagen“.
    public static func outcomeState(_ outcome: StorageCleanOutcome) -> String {
        switch outcome.result {
        case .removed where outcome.method == .timeMachineExclude: "ausgenommen"
        case .removed where outcome.method == .timeMachineInclude: "wieder gesichert"
        case .removed: "aufgeräumt"
        case .skipped: "übersprungen"
        case .failed: "fehlgeschlagen"
        }
    }

    /// Grund eines übersprungenen oder fehlgeschlagenen Eintrags.
    public static func outcomeReason(_ outcome: StorageCleanOutcome) -> String? {
        switch outcome.result {
        case .removed: nil
        case .skipped(let reason), .failed(let reason): reason
        }
    }

    /// Ton des Zustandschips eines Ausgangs.
    public static func outcomeTone(of outcome: StorageCleanOutcome) -> PresentationTone {
        switch outcome.result {
        case .removed: .positive
        case .skipped: .neutral
        case .failed: .critical
        }
    }
}
