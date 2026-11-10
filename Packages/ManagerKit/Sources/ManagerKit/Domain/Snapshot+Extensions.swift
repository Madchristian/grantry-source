import Foundation

extension Snapshot {
    /// Nimmt die Erweiterungen eines Scans auf und schreibt fort (TM-13.3):
    /// - Einträge aus Listen, die nicht oder nur teilweise gelesen wurden (`ExtensionContribution.incompleteGroups`), und
    ///   an oder unter nicht auswertbaren Pfaden (`incompletePaths`) fehlen nicht, sondern zeigen den letzten bekannten
    ///   Stand – ein unlesbares Bundle belegt kein Entfernen,
    /// - wieder gesehene Einträge behalten ihr früheres `firstSeenAt` und ihre App, bis die nächste Zuordnung sie ersetzt
    ///   (`assigningExtensionOwners`).
    ///
    /// Idempotent: Erneutes Anwenden mit demselben Vorgänger ändert nichts.
    func addingExtensions(_ contribution: ExtensionContribution, carryingForwardFrom previous: Snapshot?) -> Snapshot {
        var result = self
        result.extensions += contribution.records
        guard let previous else { return result }
        let previousByID = previous.extensions.firstByID()
        result.extensions = result.extensions.map { record in
            guard let earlier = previousByID[record.id] else { return record }
            var record = record
            record.firstSeenAt = min(record.firstSeenAt, earlier.firstSeenAt)
            record.owner = record.owner ?? earlier.owner
            return record
        }
        let present = Set(result.extensions.map(\.id))
        let prefixes = contribution.incompletePaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        result.extensions += previous.extensions.filter { record in
            guard !present.contains(record.id) else { return false }
            if contribution.incompleteGroups.contains(record.kind.group) { return true }
            guard let path = record.path else { return false }
            return contribution.incompletePaths.contains(path) || prefixes.contains(where: path.hasPrefix)
        }
        return result
    }

    /// Ordnet jede Erweiterung ihrer App im Inventar zu (`AppExtensionIndex`). Hat das App-Inventar nur eingeschränkt
    /// geliefert (nicht lesbarer Ordner, Signatur nicht geprüft), ist „App fehlt“ nicht belegt und gilt als unklar.
    func assigningExtensionOwners(_ index: AppExtensionIndex) -> Snapshot {
        let isAppInventoryLimited = sourceLimitations.contains { $0.source == .apps }
        var result = self
        result.extensions = extensions.map { record in
            var record = record
            let owner = index.owner(bundleID: record.bundleID, teamID: record.teamID)
            record.owner = owner == .missing && isAppInventoryLimited ? .unclear(candidates: []) : owner
            return record
        }
        return result
    }
}
