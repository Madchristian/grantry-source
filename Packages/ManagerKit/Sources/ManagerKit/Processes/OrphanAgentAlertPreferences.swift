import Foundation

/// Einstellungen des Hinweises auf verwaiste Agenten-Bäume (#224) in einem `SettingsStore`: an oder aus (Vorgabe an)
/// und ob der nächste Hinweis fällig werden darf (Entprellung des `OrphanAgentAlerter`, überdauert Neustarts).
public struct OrphanAgentAlertPreferences {
    /// Schlüssel im `SettingsStore`; die Einstellungen binden ihn per `@AppStorage`.
    public static let enabledKey = "orphanAgentAlerts"
    static let armedKey = "orphanAgentAlertArmed"

    private let store: any SettingsStore

    public init(store: any SettingsStore = UserDefaults.standard) {
        self.store = store
    }

    public var isEnabled: Bool {
        get { store.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: Self.enabledKey) }
    }

    /// `false` nach einem Hinweis, bis die Lage sich entspannt hat (`OrphanAgentAlertThreshold.isCleared`).
    var isArmed: Bool {
        get { store.object(forKey: Self.armedKey) as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: Self.armedKey) }
    }
}
