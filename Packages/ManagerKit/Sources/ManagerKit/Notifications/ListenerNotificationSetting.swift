import Foundation

/// Welche neuen Netzwerkdienste gemeldet werden (Einstellungen; Vorgabe: nur von außen erreichbare).
public enum ListenerNotificationSetting: String, Sendable, CaseIterable {
    case exposedOnly, all, off

    public var displayName: String {
        switch self {
        case .exposedOnly: "Nur von außen erreichbare"
        case .all: "Alle neuen"
        case .off: "Aus"
        }
    }
}

/// Speichert die Einstellung in einem `SettingsStore`.
public struct ListenerNotificationPreferences {
    /// Schlüssel im `SettingsStore`; die Einstellungen binden ihn per `@AppStorage`.
    public static let storageKey = "listenerNotifications"
    private let store: any SettingsStore

    public init(store: any SettingsStore = UserDefaults.standard) {
        self.store = store
    }

    public var setting: ListenerNotificationSetting {
        get { (store.object(forKey: Self.storageKey) as? String).flatMap(ListenerNotificationSetting.init(rawValue:)) ?? .exposedOnly }
        nonmutating set { store.set(newValue.rawValue, forKey: Self.storageKey) }
    }
}
