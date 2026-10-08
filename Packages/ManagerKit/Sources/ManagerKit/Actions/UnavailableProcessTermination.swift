import Foundation

/// Vorgabe des `ActionCoordinator`: beendet nie (Tests, fehlende Anbindung). Erst die App verdrahtet den
/// `ProcessTerminator` samt dem `ListenerTerminationLedger`, das auch die Quelle liest – ein Terminator mit eigenem
/// Ledger schickte echte Signale, ohne dass der beendete Lauscher aus der Liste fiele.
public struct UnavailableProcessTermination: ProcessTerminating {
    public static let reason = "Prozess beenden ist nicht verfügbar."

    public init() {}

    /// Kein Signal; je Prozess ein Fehler mit `reason`.
    public func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationReport {
        ProcessTerminationReport(failures: request.processes.map { ProcessTerminationFailure(process: $0, message: Self.reason) })
    }
}
