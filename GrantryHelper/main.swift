import Foundation
import HelperCore
import GrantryShared
import os

// Root-Helper: wird per SMAppService.daemon registriert (Plan 3) und bedient nur die signierte App, und auch
// diese nur, wenn sie von einem Administrator ausgeführt wird (Standard-Prädikat des Delegates).
//
// Einzige Quelle des Helper-Einstiegs: Nur das Xcode-Target `GrantryHelper` (Grantry.xcodeproj) baut diese
// Datei; die Logik liegt in den Package-Produkten `HelperCore` und `GrantryShared` (Packages/ManagerKit).
//
// Nach `IdleMonitor.defaultTimeout` (5 min) ohne offene Verbindung und ohne laufende Operation beendet sich der
// Helper; launchd startet ihn bei der nächsten Anfrage an den Mach-Service neu.
let idleMonitor = IdleMonitor(clock: ContinuousClock()) {
    Logger(subsystem: GrantryIdentity.logSubsystem, category: "helper").notice("Leerlauf – Helper beendet sich")
    exit(0)
}
let delegate = HelperListenerDelegate(
    service: HelperService(idleMonitor: idleMonitor),
    isAuthorized: AdminMembership.isAdministrator,
    idleMonitor: idleMonitor
)
let listener = NSXPCListener(machServiceName: GrantryIdentity.helperMachServiceName)
// Release-Helper akzeptieren keine App mit `get-task-allow` (per task_for_pid übernehmbar, siehe
// `GrantryIdentity.releaseAppRequirement`); nur Debug-Helper erlauben Entwicklungs-Builds der App.
#if DEBUG
listener.setConnectionCodeSigningRequirement(GrantryIdentity.appRequirement)
#else
listener.setConnectionCodeSigningRequirement(GrantryIdentity.releaseAppRequirement)
#endif
listener.delegate = delegate
listener.resume()
idleMonitor.start()
dispatchMain()
