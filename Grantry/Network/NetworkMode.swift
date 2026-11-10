import Foundation

/// Ansicht im Bereich „Netzwerk“: offene Verbindungen, lauschende Dienste oder Live-Aktivität; die Auswahl bleibt über
/// Neustarts erhalten. Seit „Verbindungen“ (2026-11-07) gilt ein neuer Schlüssel, damit die neue Ansicht einmal für alle
/// zuerst erscheint.
enum NetworkMode: String, CaseIterable, Identifiable, StoredSelection {
    case connections, services, activity

    static let storageKey = "network.view"
    static let fallback = NetworkMode.connections

    var id: Self { self }

    var title: String {
        switch self {
        case .connections: String(localized: "Verbindungen")
        case .services: String(localized: "Dienste")
        case .activity: String(localized: "Aktivität")
        }
    }
}
