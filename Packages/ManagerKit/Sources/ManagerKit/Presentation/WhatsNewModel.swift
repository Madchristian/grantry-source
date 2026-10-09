import Foundation
import Observation

/// Einmalige Ankündigung je Marketing-Version, unabhängig von Buildnummer und Update-Netzwerkzugriff.
@MainActor
@Observable
public final class WhatsNewModel {
    public private(set) var isPresented = false
    public let version: String
    private let defaults: any SettingsStore
    public static let lastSeenVersionKey = "whatsNewLastSeenVersion"

    public init(version: String, hasCompletedOnboarding: Bool, defaults: any SettingsStore = UserDefaults.standard) {
        self.version = version
        self.defaults = defaults
        // Neuinstallation: nur die Einrichtung. Beim ersten Upgrade von einer älteren Grantry ohne diesen
        // Schlüssel gilt ein erledigtes Onboarding als vorhandene Installation.
        if !hasCompletedOnboarding && defaults.object(forKey: Self.lastSeenVersionKey) == nil {
            defaults.set(version, forKey: Self.lastSeenVersionKey)
        }
    }

    @discardableResult
    public func presentIfNeeded(canPresent: Bool) -> Bool {
        guard canPresent, !isPresented,
              defaults.object(forKey: Self.lastSeenVersionKey) as? String != version else { return false }
        present()
        return true
    }

    public func present() { isPresented = true }

    public func dismiss() {
        defaults.set(version, forKey: Self.lastSeenVersionKey)
        isPresented = false
    }
}
