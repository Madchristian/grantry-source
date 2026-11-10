import Foundation

/// Mitteilung zu einem schweren Befund (TM-12.8, Spec 2026-11-08 §5.1): Dauerlast seit mindestens 10 min (CPU gesamt
/// oder ein Prozess), thermischer Zustand ab „ernst“ oder kritischer Speicherdruck – jeweils nur, solange der Befund
/// läuft. Der Text ist der Grund des Befunds: Programme anderer Benutzer bleiben darin ohne Namen, Befehlszeilen kommen
/// nie vor (`WatchbookSubject`). Ein Klick führt ins Wachbuch an den Beginn des Befunds.
public struct SevereFindingAlert: Hashable, Sendable {
    /// Art der Mitteilung; je Art höchstens eine je Stunde (`SevereFindingNotifier`).
    public enum Category: Hashable, Sendable {
        case sustainedLoad, thermal, memory
    }

    /// Ab dieser Dauer ist Dauerlast schwer.
    public static let sustainedLoadDuration: TimeInterval = 600
    /// Stufe „ernst“ im Wachbuch (`ProcessInfo.ThermalState.serious`).
    static let seriousThermalLevel = 2.0

    public let category: Category
    /// Kritischer Ton zuerst innerhalb einer Art.
    let isCritical: Bool
    public let title: String
    public let body: String
    public let identifier: String
    public let destination: NotificationDestination

    /// `nil`, wenn `finding` zu `now` kein schwerer Befund ist.
    public init?(_ finding: SystemFinding, at now: Date) {
        guard finding.isOngoing else { return nil }
        switch finding.kind {
        case .systemLoad, .processLoad:
            let duration = now.timeIntervalSince(finding.start)
            guard duration >= Self.sustainedLoadDuration else { return nil }
            category = .sustainedLoad
            title = "Dauerlast seit \(AppUsagePresentation.durationText(duration))"
        case .thermalState:
            guard finding.evidence.peak >= Self.seriousThermalLevel else { return nil }
            category = .thermal
            title = finding.tone == .critical ? "Thermischer Zustand kritisch" : "Thermischer Zustand ernst"
        case .memoryPressure:
            guard finding.tone == .critical else { return nil }
            category = .memory
            title = "Kritischer Speicherdruck"
        default:
            // Alle anderen Arten (auch künftige) melden sich nicht als schwerer Befund.
            return nil
        }
        isCritical = finding.tone == .critical
        body = finding.reason
        identifier = "severeFinding-\(finding.id.uuidString)"
        destination = .watchbook(finding.start)
    }
}

/// Einstellung „Bei schweren Befunden benachrichtigen“ in einem `SettingsStore` (Entscheidung O7: Vorgabe an).
public struct SevereFindingAlertPreferences {
    /// Schlüssel im `SettingsStore`; die Einstellungen binden ihn per `@AppStorage`.
    public static let enabledKey = "severeFindingAlerts"

    private let store: any SettingsStore

    public init(store: any SettingsStore = UserDefaults.standard) {
        self.store = store
    }

    public var isEnabled: Bool {
        get { store.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: Self.enabledKey) }
    }
}

/// Meldet schwere Befunde, ohne zu nerven: jeden Befund höchstens einmal und je Art (`SevereFindingAlert.Category`)
/// höchstens eine Mitteilung je `interval`. Die Zeit kommt vom Aufrufer (Zeit des Messpunkts, #214); die Sperre gilt
/// in beide Richtungen, eine zurückgestellte Uhr hält sie also nicht fest. Abgeschaltet wird nichts gemeldet und nichts
/// vorgemerkt. Lebt im Zustand des `WatchbookRecorder` und wird nach jedem 10-s-Punkt geprüft.
public struct SevereFindingAlerts: Sendable {
    private let notifier: any UserNotifying
    private let isEnabled: @Sendable () -> Bool
    private let interval: TimeInterval
    private var lastPost: [SevereFindingAlert.Category: Date] = [:]
    /// Bereits gemeldete Befunde (`SystemFinding.id`); beendete fallen bei der nächsten Prüfung heraus.
    private var notified: Set<UUID> = []

    /// - Parameter isEnabled: wird je Prüfung gelesen, damit eine geänderte Einstellung sofort gilt.
    public init(notifier: any UserNotifying, isEnabled: @escaping @Sendable () -> Bool,
                interval: TimeInterval = 3_600) {
        self.notifier = notifier
        self.isEnabled = isEnabled
        self.interval = interval
    }

    /// Prüft die laufenden Befunde zur Zeit `now` und stellt fällige Mitteilungen zu, ohne darauf zu warten.
    mutating func review(_ findings: [SystemFinding], at now: Date) {
        for alert in due(findings, at: now) {
            Task { [notifier] in
                await notifier.post(title: alert.title, body: alert.body, identifier: alert.identifier,
                                    destination: alert.destination)
            }
        }
    }

    /// Fällige Mitteilungen zur Zeit `now`: je Art die des schwersten Befunds, sofern die Art frei ist; merkt sie vor.
    mutating func due(_ findings: [SystemFinding], at now: Date) -> [SevereFindingAlert] {
        notified.formIntersection(findings.filter(\.isOngoing).map(\.id))
        guard isEnabled() else { return [] }
        let candidates = findings
            .filter { !notified.contains($0.id) }
            .compactMap { finding in SevereFindingAlert(finding, at: now).map { (finding, $0) } }
            .sorted { first, second in
                (first.1.isCritical ? 0 : 1, first.0.start) < (second.1.isCritical ? 0 : 1, second.0.start)
            }
        var due: [SevereFindingAlert] = []
        for (finding, alert) in candidates where !due.contains(where: { $0.category == alert.category }) {
            if let last = lastPost[alert.category], abs(now.timeIntervalSince(last)) < interval { continue }
            lastPost[alert.category] = now
            notified.insert(finding.id)
            due.append(alert)
        }
        return due
    }
}
