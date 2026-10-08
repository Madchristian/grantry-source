import Foundation

/// Auswertung der Ausgabe von `spctl --status` – die einzige Stelle dafür. App (Anzeige des Zustands) und Helper
/// (Vorab-Abfrage vor dem Setzen) bewerten damit denselben Text gleich.
public enum GatekeeperStatusOutput {
    /// `true` bei „assessments enabled“, `false` bei „assessments disabled“ (Leerraum drumherum zählt nicht); jede
    /// andere Ausgabe ist unbekannt (`nil`) – nie eine Vermutung.
    public static func isEnabled(in output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "assessments enabled": true
        case "assessments disabled": false
        default: nil
        }
    }
}
