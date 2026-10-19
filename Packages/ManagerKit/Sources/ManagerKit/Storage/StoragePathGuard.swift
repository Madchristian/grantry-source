import Foundation

/// Letzte Prüfung eines Speicher-Eintrags unmittelbar vor Papierkorb oder Löschen (Spec Speicher §2.4): Der Pfad liegt
/// unterhalb einer Wurzel seiner Kategorie (am Objekt erkannt, nie die Wurzel selbst), ist kein Symlink und hat keinen
/// im Pfad, ist kein Einhängepunkt, berührt keinen Sperrort (`LibraryLayout.blockedPaths`) und ist noch dasselbe Objekt
/// wie beim Scan. Anders als `RemovalGuard` sind versteckte Einträge wie `.build` erlaubt.
struct StoragePathGuard: Sendable {
    let layout: LibraryLayout

    init(layout: LibraryLayout = .standard) {
        self.layout = layout
    }

    func check(_ path: String, identity: FileIdentity?, roots: [String]) -> RemovalVerdict {
        guard let identity else { return .blocked("Kein Scan-Beleg") }
        guard let components = RawPath.components(of: path) else { return .blocked("Ungültiger Pfad") }
        guard let entry = FileIdentity.of(path) else { return .blocked("Nicht vorhanden") }
        if entry.type == .symbolicLink { return .blocked("Symbolischer Link") }
        let parentPath = RawPath.path(of: components.dropLast())
        // Wie `RemovalGuard.inspect` ohne Groß-/Kleinschreibung: `realpath` liefert auf APFS die Schreibweise auf der
        // Platte (`~/Code` gegen `~/code`). Die Wurzeln werden weiter am Objekt erkannt.
        guard let resolvedParent = RemovalGuard.resolvedPath(parentPath), resolvedParent.lowercased() == parentPath.lowercased() else {
            return .blocked("Symbolischer Link im Pfad")
        }
        guard entry == identity else { return .blocked("Geändert seit Scan") }
        // `/` und jeder Elternordner bis einschließlich `parentPath`.
        let ancestors = RawPath.prefixes(of: Array(components.dropLast())).compactMap(FileIdentity.of)
        guard ancestors.count == components.count, let parent = ancestors.last else { return .blocked("Nicht vorhanden") }
        let blocked = layout.blockedPaths.compactMap(FileIdentity.of)
        if (ancestors + [entry]).contains(where: blocked.contains) { return .blocked("Geschützter Ort") }
        if RemovalGuard.isMountPoint(entry, below: parent) { return .blocked("Einhängepunkt") }
        let allowedRoots = roots.compactMap(FileIdentity.of)
        guard ancestors.contains(where: allowedRoots.contains) else { return .blocked("Außerhalb der erlaubten Orte") }
        return .allowed
    }
}
