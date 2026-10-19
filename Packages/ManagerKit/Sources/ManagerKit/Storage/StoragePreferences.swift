import Foundation

/// Einstellungen des Speicher-Aufräumens: Code-Wurzeln der Projektsuche und Altersgrenze (Spec Speicher §2.6).
public struct StoragePreferences {
    static let codeRootsKey = "storageCodeRoots"
    static let minimumAgeDaysKey = "storageMinimumAgeDays"
    public static let defaultMinimumAgeDays = 30

    private let store: any SettingsStore
    private let home: String

    public init(store: any SettingsStore = UserDefaults.standard, home: String = NSHomeDirectory()) {
        self.store = store
        self.home = home
    }

    /// Vorgabe: vorhandene `~/Projects`, `~/Developer`, `~/Code`.
    public var codeRoots: [String] {
        get {
            store.object(forKey: Self.codeRootsKey) as? [String]
                ?? ["Projects", "Developer", "Code"].map { home + "/" + $0 }.filter { FileIdentity.of($0)?.type == .directory }
        }
        nonmutating set { store.set(newValue, forKey: Self.codeRootsKey) }
    }

    /// Mindestens ein Tag.
    public var minimumAgeDays: Int {
        get { max(1, store.object(forKey: Self.minimumAgeDaysKey) as? Int ?? Self.defaultMinimumAgeDays) }
        nonmutating set { store.set(max(1, newValue), forKey: Self.minimumAgeDaysKey) }
    }
}
