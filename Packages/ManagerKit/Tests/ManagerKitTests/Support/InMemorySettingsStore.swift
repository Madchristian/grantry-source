import ManagerKit

/// `SettingsStore` im Arbeitsspeicher: anders als `UserDefaults(suiteName:)` bleibt keine Datei in
/// `~/Library/Preferences` zurück.
final class InMemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }
}
