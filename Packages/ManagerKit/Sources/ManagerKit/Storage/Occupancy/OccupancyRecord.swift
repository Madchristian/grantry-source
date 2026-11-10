/// Datei mit mehreren Namen (Hardlink): Sie zählt im Baum genau einmal (`OccupancyTree`).
struct OccupancyLinkedFile: Sendable {
    let identity: FileIdentity
    let allocatedBytes: Int64
}

/// Was direkt in einem Ordner liegt: Summen, Hardlinks und die größten Dateien – keine Liste aller Dateien.
struct OccupancyDirectFiles: Sendable {
    private(set) var count = 0
    /// Dateien mit genau einem Namen.
    private(set) var exclusiveBytes: Int64 = 0
    private(set) var linked: [OccupancyLinkedFile] = []
    /// Die größten Dateien, absteigend, bei Gleichstand nach Name.
    private(set) var largest: [OccupancyFile] = []
    /// Jüngste Änderung des Ordners selbst und seiner Einträge.
    private(set) var newestModification: OccupancyTimestamp?

    /// Alle Dateien dieses Ordners, Hardlinks je Name gezählt (Fortschritt).
    var allocatedBytes: Int64 { exclusiveBytes + linked.reduce(0) { $0 + $1.allocatedBytes } }

    mutating func add(name: String, identity: FileIdentity, allocatedBytes: Int64, linkCount: Int, limit: Int) {
        count += 1
        if linkCount > 1 {
            linked.append(OccupancyLinkedFile(identity: identity, allocatedBytes: allocatedBytes))
        } else {
            exclusiveBytes += allocatedBytes
        }
        let file = OccupancyFile(name: name, allocatedBytes: allocatedBytes)
        if largest.count == limit, let last = largest.last, !Self.precedes(file, last) { return }
        largest.insert(file, at: Self.insertionIndex(of: file, in: largest))
        if largest.count > limit { largest.removeLast() }
    }

    mutating func noteModification(_ modification: OccupancyTimestamp) {
        newestModification = max(newestModification ?? modification, modification)
    }

    /// Ohne Reserve aus dem Wachsen der Listen: Ein Ordner hält sie, solange das Ergebnis lebt.
    func compacted() -> OccupancyDirectFiles {
        var files = self
        if files.largest.capacity > files.largest.count { files.largest = files.largest.withUnsafeBufferPointer(Array.init) }
        if files.linked.capacity > files.linked.count { files.linked = files.linked.withUnsafeBufferPointer(Array.init) }
        return files
    }

    private static func precedes(_ first: OccupancyFile, _ second: OccupancyFile) -> Bool {
        first.allocatedBytes != second.allocatedBytes ? first.allocatedBytes > second.allocatedBytes : first.name < second.name
    }

    private static func insertionIndex(of file: OccupancyFile, in files: [OccupancyFile]) -> Int {
        var low = 0, high = files.count
        while low < high {
            let middle = (low + high) / 2
            if precedes(files[middle], file) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Ein Ordner samt Unterbaum, wie ihn ein Scan gelesen hat. Unveränderlich – ein erneuter Scan übernimmt unveränderte
/// Unterbäume als dieselben Objekte. Größen mit Hardlink-Abgleich berechnet erst `OccupancyTree`, weil sie vom ganzen
/// Baum abhängen; alles andere fasst der Datensatz für seinen Unterbaum zusammen.
final class OccupancyRecord: Sendable {
    let name: String
    /// Identität beim Lesen des Elternordners; `nil` bei Einhängepunkten aus der Mount-Tabelle.
    let identity: FileIdentity?
    let modification: OccupancyTimestamp?
    let state: OccupancyFolderState
    let files: OccupancyDirectFiles
    /// Unterordner nach Name sortiert (`<`).
    let children: [OccupancyRecord]
    /// Dateien im Unterbaum, jeder Name zählt.
    let fileCount: Int
    /// Ordner im Unterbaum samt diesem.
    let folderCount: Int
    /// Nicht erfassbare Ordner im Unterbaum samt diesem.
    let uncapturedCount: Int
    /// Jüngste Änderung im erfassten Unterbaum.
    let newestModification: OccupancyTimestamp?

    init(name: String, identity: FileIdentity?, modification: OccupancyTimestamp?, state: OccupancyFolderState,
         files: OccupancyDirectFiles = OccupancyDirectFiles(), children: [OccupancyRecord] = []) {
        self.name = name
        self.identity = identity
        self.modification = modification
        self.state = state
        self.files = files.compacted()
        self.children = children.capacity > children.count ? children.withUnsafeBufferPointer(Array.init) : children
        var fileCount = files.count, folderCount = 1, uncapturedCount = state.isUncaptured ? 1 : 0
        var newest = files.newestModification ?? modification
        for child in children {
            fileCount += child.fileCount
            folderCount += child.folderCount
            uncapturedCount += child.uncapturedCount
            if let childNewest = child.newestModification { newest = max(newest ?? childNewest, childNewest) }
        }
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.uncapturedCount = uncapturedCount
        newestModification = newest
    }

    /// Unterordner mit genau diesem Namen (binäre Suche).
    func child(named name: String) -> OccupancyRecord? {
        childIndex(named: name).map { children[$0] }
    }

    /// Position des Unterordners mit genau diesem Namen in `children`.
    func childIndex(named name: String) -> Int? {
        var low = 0, high = children.count
        while low < high {
            let middle = (low + high) / 2
            if children[middle].name < name { low = middle + 1 } else { high = middle }
        }
        return low < children.count && children[low].name == name ? low : nil
    }
}
