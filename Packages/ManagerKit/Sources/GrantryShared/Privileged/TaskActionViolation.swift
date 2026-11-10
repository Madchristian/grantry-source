import Foundation
import Security

/// Ablehnungen der Task-Manager-Befehle des Helpers (TM9), die nicht schon `ProcessTerminationViolation` abdeckt; die
/// Meldung geht unverändert an die App.
public enum TaskActionViolation: LocalizedError, Equatable {
    /// Die Admin-Bestätigung hat nicht die Form einer `AuthorizationExternalForm`.
    case invalidAuthorization
    /// Der Mensch hat den Kennwortdialog abgebrochen.
    case authorizationCanceled
    /// Kennwort falsch, kein Admin oder Dialog nicht möglich (`OSStatus` von Authorization Services).
    case authorizationDenied(OSStatus)
    /// Kein Wert aus `ProcessPriority`.
    case priorityNotAllowed(Int32)
    /// Der Prozess läuft nicht mehr (Priorität: anders als beim Beenden kein Erfolg).
    case processGone(pid_t)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorization: "Admin-Bestätigung ungültig – Aktion abgebrochen"
        case .authorizationCanceled: "Admin-Bestätigung abgebrochen – nichts geändert"
        case .authorizationDenied(let status): "Admin-Bestätigung abgelehnt (\(status)) – nichts geändert"
        case .priorityNotAllowed(let value): "Priorität \(value) ist nicht erlaubt"
        case .processGone(let pid): "Prozess \(pid) läuft nicht mehr"
        }
    }

    /// Länge einer `AuthorizationExternalForm`.
    public static let authorizationLength = MemoryLayout<AuthorizationExternalForm>.size

    /// Prüft nur die Form; ob die Ref gültig ist, entscheidet Authorization Services.
    public static func validateAuthorization(_ data: Data) throws(TaskActionViolation) {
        guard data.count == authorizationLength else { throw .invalidAuthorization }
    }
}
