/// Eine Datenquelle, die ihren Beitrag zu einem Snapshot liefert.
/// Neue Module (Milestones v2–v5) werden als weitere Implementierungen ergänzt.
public protocol InventorySource: Sendable {
    var id: SourceID { get }
    func collect() async throws -> InventoryContribution
    /// Der `ScanCoordinator` hat `contribution` (aus `collect()` dieser Quelle) in den Snapshot übernommen – rechtzeitig
    /// und ohne Abbruch. Erst jetzt darf die Quelle Zustand festschreiben, der auf diesem Beitrag beruht (etwa den Erfolg
    /// einer Helper-Messung, #142); verwirft der Coordinator ihn, bleibt der Zustand wie vor `collect()`.
    func accept(_ contribution: InventoryContribution)
}

extension InventorySource {
    /// Standard: Die Quelle hält keinen Zustand, der von der Übernahme abhängt.
    public func accept(_ contribution: InventoryContribution) {}
}
