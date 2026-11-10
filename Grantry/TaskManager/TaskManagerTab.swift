import ManagerKit

/// Tabs des Bereichs „Task-Manager“ (Spec 2026-11-06 §2, „Wachbuch“ nach Spec 2026-11-08 § 5.1); die Wahl bleibt über
/// Neustarts erhalten.
enum TaskManagerTab: String, CaseIterable, Identifiable, StoredSelection {
    case overview, processes, performance, chip, details, energy, appHistory, watchbook, users, services

    static let storageKey = "taskManager.tab"
    static let fallback = TaskManagerTab.overview

    var id: Self { self }

    /// Tabs dieses Macs: „Chip“ nur im Apple-Silicon-Kompilat (Intel-Macs haben keine Leistungsstufen).
    static var available: [TaskManagerTab] {
        #if arch(arm64)
        allCases
        #else
        allCases.filter { $0 != .chip }
        #endif
    }

    /// Zeigt das Urteil selbst statt der gemeinsamen Zustandszeile: die Übersicht als Lagezeile, das Wachbuch über seinen
    /// Zeitraum.
    var showsOwnVerdict: Bool { self == .overview || self == .watchbook }

    var title: String {
        switch self {
        case .overview: String(localized: "Übersicht")
        case .processes: String(localized: "Prozesse")
        case .performance: String(localized: "Leistung")
        case .chip: String(localized: "Chip")
        case .details: String(localized: "Details")
        case .energy: String(localized: "Energie")
        case .appHistory: String(localized: "App-Verlauf")
        case .watchbook: String(localized: "Wachbuch")
        case .users: String(localized: "Benutzer")
        case .services: String(localized: "Dienste")
        }
    }
}

extension TaskManagerInterval {
    var title: String {
        switch self {
        case .halfSecond: String(localized: "0,5 s")
        case .oneSecond: String(localized: "1 s")
        case .twoSeconds: String(localized: "2 s")
        case .fiveSeconds: String(localized: "5 s")
        }
    }
}
