import Foundation
import GrantryShared
import os

/// Nimmt XPC-Verbindungen an und exportiert den `HelperService`. Die Code-Signatur-Prüfung des Aufrufers erfolgt
/// bereits am Listener (`setConnectionCodeSigningRequirement`), bevor dieser Delegate gefragt wird. Sie belegt nur,
/// **welche App** sich verbindet, nicht **welcher Benutzer**; daher lässt der Delegate zusätzlich nur Verbindungen
/// zu, deren EUID `isAuthorized` erfüllt (Standard: Mitglied der Gruppe `admin`).
///
/// Jede angenommene Verbindung zählt bis zu ihrer Invalidierung als Aktivität von `idleMonitor`. (Einen
/// `interruptionHandler` gibt es nicht: Er feuert nur auf der aufbauenden Seite, angenommene Verbindungen werden
/// beim Wegfall des Clients invalidiert.)
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private static let logger = Logger(subsystem: GrantryIdentity.logSubsystem, category: "xpc")
    private let service: HelperService
    private let isAuthorized: @Sendable (uid_t) -> Bool
    private let idleMonitor: IdleMonitor?

    public init(
        service: HelperService,
        isAuthorized: @escaping @Sendable (uid_t) -> Bool = AdminMembership.isAdministrator,
        idleMonitor: IdleMonitor? = nil
    ) {
        self.service = service
        self.isAuthorized = isAuthorized
        self.idleMonitor = idleMonitor
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        let euid = connection.effectiveUserIdentifier
        guard isAuthorized(euid) else {
            Self.logger.error(
                "XPC-Verbindung abgelehnt, kein Administrator: PID \(pid, privacy: .public), EUID \(euid, privacy: .public)"
            )
            return false
        }
        connection.exportedInterface = HelperXPC.makeInterface()
        connection.exportedObject = service
        if let activity = idleMonitor?.beginActivity() {
            connection.invalidationHandler = { activity.end() }
        }
        connection.resume()
        Self.logger.notice("XPC-Verbindung angenommen: PID \(pid, privacy: .public), EUID \(euid, privacy: .public)")
        return true
    }
}
