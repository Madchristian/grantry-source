/// Hinweis, dass sich ein Eintrag gefahrlos aufräumen lässt. Anders als ein `RiskFinding` kein Risiko – daher
/// getrennt von `RiskEvaluator`.
public struct CleanupHint: Identifiable, Hashable, Sendable {
    /// `id` des betroffenen `PermissionGrant`.
    public let recordID: String
    public let message: String

    public var id: String { recordID }

    public init(recordID: String, message: String) {
        self.recordID = recordID
        self.message = message
    }
}

/// Findet Altlasten: nicht erteilte Berechtigungen von Apps, die (vermutlich) nicht mehr installiert sind.
///
/// Das Gegenstück zur `OrphanRule`, die nur erteilte Berechtigungen meldet. Unbekannte Existenz (`Presence.unknown`)
/// und Apple-Komponenten (`AppleComponent`) zählen wie dort nicht.
public enum CleanupHints {
    static let removedAppMessage = "Eintrag einer entfernten App – kann in den Systemeinstellungen gelöscht werden"

    /// Hinweise aufsteigend nach `recordID` (deterministisch für die UI).
    public static func evaluate(_ snapshot: Snapshot) -> [CleanupHint] {
        snapshot.grants
            .filter { !$0.authValue.isGranted && isRemoved($0.client.presence) && !AppleComponent.contains($0) }
            .map { CleanupHint(recordID: $0.id, message: removedAppMessage) }
            .sorted { $0.recordID < $1.recordID }
    }

    private static func isRemoved(_ presence: Presence) -> Bool {
        presence == .missing || presence == .probablyMissing
    }
}
