import Foundation

/// Schlüssel-Wert-Speicher für Einstellungen: in der App `UserDefaults`, in Tests ein Speicher im Arbeitsspeicher
/// (`UserDefaults(suiteName:)` hinterließe je Test eine leere Datei in `~/Library/Preferences`).
public protocol SettingsStore {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension SettingsStore {
    /// Wahrheitswert zu `key`; `false`, wenn er fehlt oder kein Wahrheitswert ist.
    public func bool(forKey key: String) -> Bool {
        object(forKey: key) as? Bool ?? false
    }
}

extension UserDefaults: SettingsStore {}
