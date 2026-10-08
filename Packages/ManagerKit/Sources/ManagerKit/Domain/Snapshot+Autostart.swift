import Foundation

extension Snapshot {
    /// Übernimmt aus `previous` die Autostart-Einträge, deren Plist in `paths` liegt – als Datei genannt oder in einem
    /// genannten Verzeichnis – und deren `id` in diesem Snapshot fehlt (#139): Eine nicht auswertbare Plist oder ein
    /// nicht lesbares Verzeichnis (`InventoryContribution.incompletePlistPaths`) belegt kein Entfernen. Die übernommenen
    /// Einträge tragen den Zeitpunkt ihres letzten tatsächlichen Lesens (`AutostartItem.lastVerifiedAt`). Einträge aus
    /// gelesenen Verzeichnissen, deren Plist fehlt, gelten weiter als entfernt. Idempotent.
    func carryingForwardAutostartItems(inIncompletePlistPaths paths: [String], from previous: Snapshot?) -> Snapshot {
        guard let previous, !paths.isEmpty else { return self }
        let present = Set(autostartItems.map(\.id))
        let files = Set(paths)
        let directories = paths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var result = self
        result.autostartItems += previous.autostartItems
            .filter { item in
                guard !present.contains(item.id), let plist = item.plistPath else { return false }
                return files.contains(plist) || directories.contains(where: plist.hasPrefix)
            }
            .map { $0.carriedForward(scannedAt: previous.takenAt) }
        return result
    }
}
