/// Zeitstempel des Dateisystems in Nanosekunden seit 1970 – genau genug, um ein geändertes Änderungsdatum sicher zu
/// erkennen (ein `Date` rundet auf rund 0,2 µs).
typealias OccupancyTimestamp = Int64

/// Eintrag eines gelesenen Ordners, ermittelt ohne Symlinks zu folgen.
enum OccupancyEntry: Equatable, Sendable {
    case file(name: String, identity: FileIdentity, allocatedBytes: Int64, linkCount: Int, modification: OccupancyTimestamp)
    /// `isDataless`: iCloud-Platzhalter, dessen Inhalt erst nachgeladen würde.
    case directory(name: String, identity: FileIdentity, modification: OccupancyTimestamp, isDataless: Bool)
    /// Einhängepunkt laut Mount-Tabelle, erkannt ohne Zugriff auf das fremde Volume.
    case mountPoint(name: String, isLocal: Bool)
    /// Symlink, FIFO, Socket, Gerät: belegt nichts Zählbares und wird nicht verfolgt.
    case other(name: String, modification: OccupancyTimestamp)
    /// `stat` scheiterte: Der Ordner gilt als unvollständig gelesen.
    case unreadable(name: String)
}

/// Aufgelöste Wurzel eines Scans: kanonischer Pfad auf einem lokalen Volume, ohne Symlinks in der Kette.
struct OccupancyRoot: Equatable, Sendable {
    let path: String
    let identity: FileIdentity
    let modification: OccupancyTimestamp
    /// Einhängepunkte unterhalb der Wurzel laut Mount-Tabelle: Pfad → lokal.
    let mountPoints: [String: Bool]
}

/// Ergebnis des Lesens eines Ordners.
enum OccupancyReadOutcome: Equatable, Sendable {
    /// Gelesen; `isComplete == false`, wenn Einträge oder das Verzeichnis selbst nicht ganz lesbar waren.
    case read(isComplete: Bool)
    case uncaptured(OccupancyGap)
    /// iCloud-Platzhalter: nicht nachgeladen.
    case cloudOnly
    /// Seit dem Lesen des Elternordners verschwunden.
    case vanished
    case cancelled
}

/// Dateisystem des Belegungsscanners – hinter einem Protokoll, damit Tests es im Speicher nachbilden.
protocol OccupancyFileSystem: Sendable {
    /// Löst `path` zur Wurzel auf: lokal, ein Ordner, ohne Symlinks in der Kette.
    func root(at path: String) throws(OccupancyScanError) -> OccupancyRoot

    /// Liest den Ordner `path`, der beim Lesen seines Elternordners `expected` war, und meldet jeden Eintrag an `visit`.
    /// Ist er inzwischen ein anderes Objekt, liefert es `.uncaptured(.changed)`; `isCancelled` wird zwischendurch
    /// abgefragt, damit auch ein riesiger Ordner den Abbruch nicht aufhält.
    func readDirectory(
        at path: String, expected: FileIdentity, in root: OccupancyRoot, isCancelled: () -> Bool,
        visit: (OccupancyEntry) -> Void
    ) -> OccupancyReadOutcome
}
