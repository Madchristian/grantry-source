/// Eine Datenquelle, die ihren Beitrag zu einem Snapshot liefert.
/// Neue Module (Milestones v2–v5) werden als weitere Implementierungen ergänzt.
public protocol InventorySource: Sendable {
    var id: SourceID { get }
    func collect() async throws -> InventoryContribution
    /// Der `ScanCoordinator` hat `contribution` (aus `collect()` dieser Quelle) in den Snapshot übernommen – rechtzeitig
    /// und ohne Abbruch. Erst jetzt darf die Quelle Zustand festschreiben, der auf diesem Beitrag beruht (etwa den Erfolg
    /// einer Helper-Messung, #142); verwirft der Coordinator ihn, bleibt der Zustand wie vor `collect()`.
    func accept(_ contribution: InventoryContribution)
    /// Ergänzt die eigenen Einträge um Bezüge auf Einträge anderer Quellen desselben Scans (etwa die zugehörige App einer
    /// Erweiterung). Der `ScanCoordinator` ruft das nach dem Zusammenführen und Fortschreiben auf, nur für Quellen, die in
    /// diesem Scan geliefert haben.
    func linkingRecords(in snapshot: Snapshot) async -> Snapshot
}

extension InventorySource {
    /// Standard: Die Quelle hält keinen Zustand, der von der Übernahme abhängt.
    public func accept(_ contribution: InventoryContribution) {}

    /// Standard: keine Bezüge auf andere Quellen.
    public func linkingRecords(in snapshot: Snapshot) async -> Snapshot { snapshot }
}
