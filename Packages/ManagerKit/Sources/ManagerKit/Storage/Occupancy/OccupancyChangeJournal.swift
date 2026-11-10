import CoreServices
import Foundation

/// Stand des Änderungsprotokolls eines Volumes zu Beginn eines Scans.
struct OccupancyChangeMark: Hashable, Sendable {
    /// Kennung des Ereignisstroms (`FSEventsCopyUUIDForDevice`): Ändert sie sich, gilt das Protokoll nicht mehr.
    let journal: String
    let eventID: UInt64
}

/// Seit einer Marke geänderte Ordner. FSEvents meldet ohne Datei-Ereignisse den Ordner, in dem sich etwas geändert hat –
/// neue, entfernte oder umbenannte Einträge ebenso wie geänderte Dateiinhalte.
struct OccupancyChanges: Equatable, Sendable {
    /// Ordner, deren Einträge neu zu lesen sind.
    var folders: Set<String>
    /// Ordner, unter denen alles neu zu lesen ist (`MustScanSubDirs`).
    var subtrees: Set<String>

    init(folders: Set<String> = [], subtrees: Set<String> = []) {
        self.folders = folders
        self.subtrees = subtrees
    }

    /// Ereignisse, nach denen das Protokoll nichts Verlässliches mehr sagt: verlorene Ereignisse, übergelaufene
    /// Ereignis-IDs, eine verschobene Wurzel, ein- oder ausgehängte Volumes.
    private static let requiresFullScan = UInt32(
        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
    )

    /// Aus FSEvents-Ereignissen (Pfade mit oder ohne abschließenden Schrägstrich); nur Ordner an oder unter `root` zählen.
    /// `nil`, wenn ein Ereignis einen vollen Scan verlangt.
    init?(events: [(path: String, flags: UInt32)], root: String) {
        self.init()
        for event in events {
            guard event.flags & Self.requiresFullScan == 0 else { return nil }
            guard event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) == 0 else { continue }
            let path = event.path.count > 1 && event.path.hasSuffix("/") ? String(event.path.dropLast()) : event.path
            let isSubtree = event.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            if RawPath.isPath(path, atOrBelow: root) {
                if isSubtree { subtrees.insert(path) } else { folders.insert(path) }
            } else if isSubtree, RawPath.isPath(root, atOrBelow: path) {
                subtrees.insert(root)
            }
        }
    }
}

/// Änderungsprotokoll für den erneuten Scan – hinter einem Protokoll, damit Tests Änderungen vorgeben.
protocol OccupancyChangeJournal: Sendable {
    /// Aktueller Stand für das Volume `device`; `nil`, wenn es kein Protokoll führt.
    func mark(forDevice device: Int32) -> OccupancyChangeMark?
    /// Geänderte Ordner unter `root` seit `mark`; `nil`, wenn das Protokoll es nicht sicher sagen kann (voller Scan).
    func changes(since mark: OccupancyChangeMark, under root: String, device: Int32) async -> OccupancyChanges?
}

/// Abfragen gegen `OccupancyChanges` für den erneuten Scan. Schreibweisen werden vorsichtig gleich behandelt
/// (Groß-/Kleinschreibung, Unicode-Normalform): Im Zweifel wird ein Ordner mehr gelesen, nie einer zu wenig.
struct OccupancyRescanPlan: Sendable {
    private let folders: Set<String>
    private let subtrees: Set<String>
    /// Jeder geänderte Pfad samt allen Vorfahren.
    private let ancestors: Set<String>

    init(_ changes: OccupancyChanges) {
        folders = Set(changes.folders.map(Self.key))
        subtrees = Set(changes.subtrees.map(Self.key))
        var ancestors: Set<String> = ["/"]
        for path in folders.union(subtrees) {
            var prefix = ""
            for component in path.split(separator: "/") {
                prefix += "/" + component
                ancestors.insert(prefix)
            }
        }
        self.ancestors = ancestors
    }

    /// Die Einträge des Ordners haben sich geändert.
    func isListingChanged(_ path: String) -> Bool {
        folders.contains(Self.key(path))
    }

    /// Unter dem Ordner ist alles neu zu lesen.
    func isSubtreeChanged(_ path: String) -> Bool {
        subtrees.contains(Self.key(path))
    }

    /// Am Ordner oder darunter hat sich etwas geändert.
    func hasChanges(atOrBelow path: String) -> Bool {
        ancestors.contains(Self.key(path))
    }

    private static func key(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
        return normalized.count > 1 && normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }
}
