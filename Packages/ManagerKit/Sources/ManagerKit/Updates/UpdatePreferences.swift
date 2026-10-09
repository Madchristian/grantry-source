import Foundation

/// Zustimmung zur täglichen Update-Prüfung (Onboarding, Einstellungen).
public enum UpdateConsent: String, Sendable {
    case undecided, enabled, disabled
}

/// Einstellungen der Update-Prüfung in einem `SettingsStore`: Zustimmung, letzte erfolgreiche Prüfung und zuletzt
/// gemeldeter Build, dazu Fälligkeit und „jede Version einmal melden“.
public struct UpdatePreferences {
    static let consentKey = "updateCheckConsent"
    static let lastCheckKey = "updateLastCheck"
    static let lastNotifiedBuildKey = "updateLastNotifiedBuild"

    /// Abstand der automatischen Prüfungen.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    private let store: any SettingsStore

    public init(store: any SettingsStore = UserDefaults.standard) {
        self.store = store
    }

    public var consent: UpdateConsent {
        get { (store.object(forKey: Self.consentKey) as? String).flatMap(UpdateConsent.init(rawValue:)) ?? .undecided }
        nonmutating set { store.set(newValue.rawValue, forKey: Self.consentKey) }
    }

    /// Zeitpunkt der letzten erfolgreichen Prüfung; gescheiterte Prüfungen ändern ihn nicht.
    public var lastSuccessfulCheck: Date? {
        get { store.object(forKey: Self.lastCheckKey) as? Date }
        nonmutating set { store.set(newValue, forKey: Self.lastCheckKey) }
    }

    public var lastNotifiedBuild: Int? {
        get { store.object(forKey: Self.lastNotifiedBuildKey) as? Int }
        nonmutating set { store.set(newValue, forKey: Self.lastNotifiedBuildKey) }
    }

    /// Nur mit Zustimmung und wenn die letzte erfolgreiche Prüfung fehlt, `checkInterval` zurückliegt oder in der
    /// Zukunft liegt (die Uhr ging falsch).
    public func isCheckDue(now: Date) -> Bool {
        guard consent == .enabled else { return false }
        guard let last = lastSuccessfulCheck else { return true }
        return last > now || now.timeIntervalSince(last) >= Self.checkInterval
    }

    /// Erwartet das höchste passende Update des aktuellen Feeds (`UpdateChecker.check()`). Ein höherer Merkstand
    /// wird darauf zurückgesetzt, damit ein früher vergifteter Feed spätere Meldungen nicht dauerhaft unterdrückt.
    /// Das Zurücksetzen meldet die ältere Version nicht erneut; ein danach höherer Build wird wieder einmal gemeldet.
    public func claimNotification(for item: AppcastItem) -> Bool {
        if let previous = lastNotifiedBuild, previous > item.build {
            lastNotifiedBuild = item.build
            return false
        }
        guard item.build > (lastNotifiedBuild ?? 0) else { return false }
        lastNotifiedBuild = item.build
        return true
    }
}
