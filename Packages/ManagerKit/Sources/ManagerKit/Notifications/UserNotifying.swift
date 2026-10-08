import GrantryShared
import os
import UserNotifications

/// Stellt Benachrichtigungen an den Benutzer zu.
public protocol UserNotifying: Sendable {
    /// Fragt die Erlaubnis für Benachrichtigungen an; `true`, wenn sie erteilt ist.
    func requestAuthorization() async -> Bool
    /// Zeigt eine Benachrichtigung. `identifier` ersetzt eine noch sichtbare Meldung mit derselben Kennung;
    /// `destination` sagt, wohin ein Klick auf die Meldung führt.
    func post(title: String, body: String, identifier: String, destination: NotificationDestination) async
}

/// `UserNotifying` über `UNUserNotificationCenter`. Meldungen tragen die Kategorie `changes` und eine gemeinsame
/// `threadIdentifier`, damit das System sie gruppiert.
///
/// Das Center wird in jeder Methode frisch geholt: `UNUserNotificationCenter` ist nicht `Sendable`, und
/// `current()` setzt ein App-Bundle voraus – der Adapter selbst lässt sich so gefahrlos erzeugen.
public struct UNUserNotificationCenterNotifier: UserNotifying {
    public static let categoryIdentifier = "changes"
    public static let threadIdentifier = "\(GrantryIdentity.appBundleID).changes"

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "notifications")

    public init() {}

    public func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [], intentIdentifiers: [])
        ])
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Self.logger.error("Benachrichtigungen nicht erlaubt: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func post(title: String, body: String, identifier: String, destination: NotificationDestination) async {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: Self.content(title: title, body: body, destination: destination),
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("Benachrichtigung nicht zugestellt: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Inhalt einer Meldung; getrennt, damit Tests ihn ohne Notification Center prüfen können.
    static func content(title: String, body: String, destination: NotificationDestination) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = threadIdentifier
        content.userInfo = destination.userInfo
        content.sound = .default
        return content
    }
}
