import Foundation

/// Auswahl, die über Neustarts erhalten bleibt (Umschalter in der Symbolleiste).
protocol StoredSelection: RawRepresentable<String>, CaseIterable {
    static var storageKey: String { get }
    /// Wahl ohne gespeicherten Wert.
    static var fallback: Self { get }
}

extension StoredSelection {
    static func restored(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? fallback
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
