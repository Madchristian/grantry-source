import Foundation

/// Eine Datei unter den größten eines Ordners (Belegung, Spec 2026-11-08 § 5.4).
public struct OccupancyFile: Hashable, Sendable {
    public let name: String
    /// Allozierte Größe (belegte Blöcke), nicht die logische Länge.
    public let allocatedBytes: Int64

    public init(name: String, allocatedBytes: Int64) {
        self.name = name
        self.allocatedBytes = allocatedBytes
    }
}

/// Warum ein Ordner nicht (vollständig) erfasst ist.
public enum OccupancyGap: Hashable, Sendable {
    /// Rechte fehlen (etwa ohne Festplattenvollzugriff).
    case permissionDenied
    /// Einzelne Einträge ließen sich nicht lesen; die Summe enthält das Lesbare.
    case incomplete
    /// Während des Scans ersetzt (anderes Objekt, Symlink im Pfad).
    case changed
    /// Vom Aufrufer ausgenommen, nicht betreten.
    case excluded
    /// Sonstiger Fehler (etwa ein zu langer Pfad).
    case failed
}

/// Zustand eines Ordners im Belegungsbaum.
public enum OccupancyFolderState: Hashable, Sendable {
    /// Vollständig gelesen.
    case complete
    /// Nicht erfassbar: Die Summe enthält nur das Lesbare (wie „nicht erfassbar“ in Speicher).
    case uncaptured(OccupancyGap)
    /// Einhängepunkt eines anderen Volumes – nicht betreten; Netzlaufwerke heißen `isLocal == false`.
    case otherVolume(isLocal: Bool)
    /// Inhalt nur in der Cloud (iCloud-Platzhalter): lokal nichts belegt, nicht nachgeladen.
    case cloudOnly

    var isUncaptured: Bool {
        if case .uncaptured = self { true } else { false }
    }
}

/// Zwischenstand eines laufenden Scans: gelesene Ordner, Dateien und deren allozierte Bytes (Hardlinks je Name).
public struct OccupancyProgress: Hashable, Sendable {
    public var folders: Int
    public var files: Int
    public var allocatedBytes: Int64

    public init(folders: Int = 0, files: Int = 0, allocatedBytes: Int64 = 0) {
        self.folders = folders
        self.files = files
        self.allocatedBytes = allocatedBytes
    }
}

/// Ein Scan, der gar nicht erst beginnt.
public enum OccupancyScanError: Error, Hashable, Sendable {
    /// Die Wurzel liegt auf einem Netzlaufwerk.
    case networkVolume
    /// Die Wurzel fehlt, ist kein Ordner oder wurde ersetzt.
    case unavailable
    /// Es läuft bereits ein Scan (`OccupancyStore`).
    case busy
}
