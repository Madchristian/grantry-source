/// Vergleicht zwei Snapshots und liefert die Änderungen. Reine Funktion ohne Seiteneffekte.
///
/// Baseline pro Quelle: `.added` entsteht nur für Einträge, deren Quelle in `previous.baselineSources` enthalten
/// ist. Liefert eine Quelle zum ersten Mal (z. B. BTM nach Helper-Genehmigung), sind ihre Einträge Baseline.
/// `.removed` entfällt für in `current` fehlgeschlagene Quellen; `.modified` meldet signifikante Änderungen
/// (`InventoryRecord.reportsChange(to:)`).
public struct SnapshotDiffer: Sendable {
    public init() {}

    /// - Parameter previous: `nil` beim ersten Scan (Baseline) → keine Events.
    public func diff(from previous: Snapshot?, to current: Snapshot) -> [ChangeEvent] {
        guard let previous else { return [] }
        let rules = Rules(failed: current.failedSources, baseline: previous.baselineSources)
        return diffRecords(previous.grants, current.grants, rules: rules, at: current, wrap: ChangeSubject.grant)
            + diffRecords(previous.autostartItems, current.autostartItems, rules: rules, at: current, wrap: ChangeSubject.autostartItem)
            + diffRecords(previous.securityChecks, current.securityChecks, rules: rules, at: current, wrap: ChangeSubject.securityCheck)
            + diffRecords(previous.installedApps, current.installedApps, rules: rules, at: current, wrap: ChangeSubject.installedApp)
            + diffRecords(previous.networkListeners, current.networkListeners, rules: rules, at: current, wrap: ChangeSubject.networkListener)
            + diffRecords(previous.mcpServers, current.mcpServers, rules: rules, at: current, wrap: ChangeSubject.mcpServer)
            + diffRecords(previous.agentAutoApprovals, current.agentAutoApprovals, rules: rules, at: current, wrap: ChangeSubject.agentAutoApproval)
    }

    /// Quellenbezogene Regeln eines Vergleichs.
    private struct Rules {
        /// In `current` fehlgeschlagene Quellen: keine `.removed`-Events.
        let failed: Set<SourceID>
        /// Quellen mit Baseline in `previous`: nur sie erzeugen `.added`-Events.
        let baseline: Set<SourceID>
    }

    private func diffRecords<Record: InventoryRecord>(
        _ old: [Record],
        _ new: [Record],
        rules: Rules,
        at current: Snapshot,
        wrap: (Record) -> ChangeSubject
    ) -> [ChangeEvent] {
        let oldByID = old.firstByID()
        let newByID = new.firstByID()
        let allIDs = Set(oldByID.keys).union(newByID.keys).sorted()

        return allIDs.compactMap { id in
            switch (oldByID[id], newByID[id]) {
            case (nil, let added?) where rules.baseline.contains(added.source):
                return ChangeEvent(kind: .added, before: nil, after: wrap(added), detectedAt: current.takenAt)
            case (let removed?, nil) where !rules.failed.contains(removed.source):
                return ChangeEvent(kind: .removed, before: wrap(removed), after: nil, detectedAt: current.takenAt)
            case (let before?, let after?) where before.reportsChange(to: after):
                return ChangeEvent(kind: .modified, before: wrap(before), after: wrap(after), detectedAt: current.takenAt)
            default:
                return nil
            }
        }
    }
}
