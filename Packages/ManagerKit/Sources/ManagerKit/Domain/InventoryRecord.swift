/// Ein Eintrag, den `SnapshotDiffer` über Snapshots hinweg vergleichen kann.
public protocol InventoryRecord: Identifiable, Hashable, Sendable where ID == String {
    /// Quelle, die den Eintrag geliefert hat (für den Schutz vor Schein-Löschungen).
    var source: SourceID { get }
    /// `true`, wenn sich der Eintrag in einer für den Nutzer relevanten Weise geändert hat.
    func hasSignificantChanges(comparedTo other: Self) -> Bool
    /// `true`, wenn der Wechsel zu `other` als `.modified` in den Verlauf gehört. Standard: `hasSignificantChanges`.
    /// Kann enger sein, aber nie weiter – `Snapshot.isEquivalent` (Speichern) richtet sich weiter nach
    /// `hasSignificantChanges`.
    func reportsChange(to other: Self) -> Bool
}

extension InventoryRecord {
    public func reportsChange(to other: Self) -> Bool { hasSignificantChanges(comparedTo: other) }
}
