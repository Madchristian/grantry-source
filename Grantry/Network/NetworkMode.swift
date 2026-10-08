import Foundation

/// Ansicht im Bereich „Netzwerk“: lauschende Dienste oder Live-Aktivität; die Auswahl bleibt über Neustarts erhalten.
enum NetworkMode: String, CaseIterable, Identifiable {
    case services, activity

    static let storageKey = "network.mode"

    var id: Self { self }

    var title: String {
        switch self {
        case .services: String(localized: "Dienste")
        case .activity: String(localized: "Aktivität")
        }
    }

    /// Zuletzt gewählte Ansicht; ohne gespeicherte Wahl „Dienste“.
    static func restored(from defaults: UserDefaults = .standard) -> NetworkMode {
        defaults.string(forKey: storageKey).flatMap(NetworkMode.init(rawValue:)) ?? .services
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
