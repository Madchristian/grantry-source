import Observation

/// Schließt verändernde Aktionen und die Wartung des Helpers (Installieren, Neu installieren) gegenseitig aus:
/// Eine Aktion während der Neuinstallation träfe auf keinen oder einen halb registrierten Helper, und eine
/// Neuinstallation während einer Aktion könnte deren XPC-Aufruf abbrechen.
@MainActor
@Observable
public final class HelperActivityLock {
    public enum Activity: Hashable, Sendable {
        case action, helperMaintenance
    }

    /// Ob die Wartung des Helpers beginnen darf (`maintenanceAccess(helperState:)`).
    public enum MaintenanceAccess: Hashable, Sendable {
        /// Nichts läuft.
        case free
        /// Eine Aktion läuft, der Helper ist aber nicht erreichbar: erst die Aktion abbrechen
        /// (`ActionRunner.abandonRunningAction()`), dann warten.
        case afterAbandoningAction
        /// Gesperrt, bis die laufende Tätigkeit endet.
        case blocked
    }

    /// Laufende Tätigkeit; `nil`, wenn keine läuft.
    public private(set) var current: Activity?

    public init() {}

    /// Ob gerade nichts läuft und eine Tätigkeit beginnen darf.
    public var isIdle: Bool { current == nil }

    /// Ob „Installieren“/„Neu installieren“ jetzt möglich ist. Eine laufende Aktion sperrt die Wartung – außer, der
    /// Helper ist nicht erreichbar (`.unreachable`, etwa weil launchd ihn nach dem Austausch des App-Bundles nicht
    /// startet): Dann kommt die Aktion ohnehin nicht voran, und die Reparatur darf sie abbrechen.
    public func maintenanceAccess(helperState: HelperState?) -> MaintenanceAccess {
        switch (current, helperState) {
        case (nil, _): .free
        case (.action?, .unreachable?): .afterAbandoningAction
        default: .blocked
        }
    }

    /// Beginnt `activity`, sofern nichts läuft; `false` sonst.
    public func begin(_ activity: Activity) -> Bool {
        guard current == nil else { return false }
        current = activity
        return true
    }

    /// Beendet `activity`; eine andere laufende Tätigkeit bleibt bestehen.
    public func end(_ activity: Activity) {
        if current == activity { current = nil }
    }

    /// Führt `operation` als `activity` aus; `nil`, ohne sie auszuführen, wenn schon etwas läuft.
    public func perform<T>(_ activity: Activity, _ operation: () async -> T) async -> T? {
        guard begin(activity) else { return nil }
        defer { end(activity) }
        return await operation()
    }
}
