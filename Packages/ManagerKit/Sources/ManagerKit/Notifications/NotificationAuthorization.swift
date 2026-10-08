import Foundation
import UserNotifications

/// Ob die App Benachrichtigungen zeigen darf.
public enum NotificationAuthorization: Hashable, Sendable {
    /// Der Benutzer wurde noch nicht gefragt.
    case notDetermined
    /// Abgelehnt; nur in den Systemeinstellungen änderbar.
    case denied
    /// Erlaubt (auch vorläufig).
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .denied
        }
    }

    /// Mitteilungseinstellungen der App in den Systemeinstellungen.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(GrantryIdentity.appBundleID)"
    )
}

extension UNUserNotificationCenterNotifier {
    /// Aktueller Stand der Erlaubnis für Benachrichtigungen.
    public func authorizationStatus() async -> NotificationAuthorization {
        NotificationAuthorization(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }
}
