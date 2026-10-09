import Foundation
import Observation

/// Persistente Dock-Einstellung, unabhängig von Fenstern und der laufenden Überwachung.
/// Die App übersetzt den Wert in eine AppKit-Aktivierungsrichtlinie.
@MainActor
@Observable
public final class DockVisibilityModel {
    public static let storageKey = "showsDockIcon"
    public private(set) var showsDockIcon: Bool
    private let defaults: any SettingsStore
    private let applyVisibility: @MainActor (Bool) -> Bool

    public init(
        defaults: any SettingsStore = UserDefaults.standard,
        applyVisibility: @escaping @MainActor (Bool) -> Bool
    ) {
        self.defaults = defaults
        self.applyVisibility = applyVisibility
        showsDockIcon = defaults.object(forKey: Self.storageKey) as? Bool ?? true
    }

    /// Beim App-Start anwenden, auch wenn noch kein Einstellungsfenster existiert.
    @discardableResult
    public func applyCurrentVisibility() -> Bool {
        applyVisibility(showsDockIcon)
    }

    public func setShowsDockIcon(_ visible: Bool) {
        guard visible != showsDockIcon, applyVisibility(visible) else { return }
        showsDockIcon = visible
        defaults.set(visible, forKey: Self.storageKey)
    }
}
