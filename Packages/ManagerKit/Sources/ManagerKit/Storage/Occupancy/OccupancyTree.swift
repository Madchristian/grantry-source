import Darwin
import Foundation

/// Ein Ordner im Belegungsbaum. `id` gilt nur innerhalb des Baums, aus dem der Ordner stammt.
public struct OccupancyFolder: Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let state: OccupancyFolderState
    /// Allozierte Bytes im Unterbaum; jeder Hardlink zählt im ganzen Baum einmal, beim zuerst erreichten Ordner
    /// (Breitensuche, Geschwister nach Name). Bei nicht erfassbaren Teilen nur das Lesbare.
    public let allocatedBytes: Int64
    /// Dateien im Unterbaum, jeder Name zählt.
    public let fileCount: Int
    public let subfolderCount: Int
    /// Nicht erfassbare Ordner im Unterbaum samt diesem; über 0 ist `allocatedBytes` eine Untergrenze.
    public let uncapturedCount: Int
    /// Änderungsdatum des Ordners selbst.
    public let modification: Date?
    /// Jüngste Änderung im erfassten Unterbaum.
    public let newestModification: Date?
    /// Die größten Dateien direkt in diesem Ordner, höchstens `OccupancyScanner.largestFileCount`.
    public let largestFiles: [OccupancyFile]

    public var isComplete: Bool { uncapturedCount == 0 }
}

/// Ergebnis eines Belegungsscans – nur im Speicher. Ordner liegen in Breitensuche-Reihenfolge in einer flachen Liste,
/// die Unterordner eines Ordners zusammenhängend; ihre Reihenfolge nach Größe steht in `sortedChildren`.
public struct OccupancyTree: Sendable {
    private struct Node: Sendable {
        let record: OccupancyRecord
        let parent: Int32
        var firstChild: Int32 = 0
        var allocatedBytes: Int64 = 0
    }

    /// Kanonischer Pfad der Wurzel.
    public let rootPath: String
    let rootRecord: OccupancyRecord
    /// Stand des Änderungsprotokolls zu Beginn dieses Scans (für den nächsten, inkrementellen).
    let mark: OccupancyChangeMark?
    private let nodes: [Node]
    /// Je Ordner die Indizes seiner Unterordner nach Größe absteigend, bei Gleichstand nach Name.
    private let sortedChildren: [Int32]

    init(rootPath: String, root: OccupancyRecord, mark: OccupancyChangeMark?) {
        self.rootPath = rootPath
        rootRecord = root
        self.mark = mark
        var nodes = [Node(record: root, parent: -1)]
        nodes.reserveCapacity(root.folderCount)
        var linked = Set<FileIdentity>()
        var index = 0
        while index < nodes.count {
            let record = nodes[index].record
            nodes[index].firstChild = Int32(nodes.count)
            for child in record.children { nodes.append(Node(record: child, parent: Int32(index))) }
            var bytes = record.files.exclusiveBytes
            for file in record.files.linked where linked.insert(file.identity).inserted { bytes += file.allocatedBytes }
            nodes[index].allocatedBytes = bytes
            index += 1
        }
        for index in nodes.indices.dropFirst().reversed() {
            nodes[Int(nodes[index].parent)].allocatedBytes += nodes[index].allocatedBytes
        }
        var sorted = (0..<Int32(nodes.count)).map { $0 }
        for node in nodes where !node.record.children.isEmpty {
            let range = Int(node.firstChild)..<Int(node.firstChild) + node.record.children.count
            sorted[range].sort { first, second in
                let (left, right) = (nodes[Int(first)], nodes[Int(second)])
                return left.allocatedBytes != right.allocatedBytes ? left.allocatedBytes > right.allocatedBytes
                    : left.record.name < right.record.name
            }
        }
        self.nodes = nodes
        sortedChildren = sorted
    }

    public var root: OccupancyFolder { folder(at: 0) }

    public var folderCount: Int { nodes.count }

    /// Unterordner nach Größe absteigend, bei Gleichstand nach Name.
    public func subfolders(of folder: OccupancyFolder) -> [OccupancyFolder] {
        childIndices(of: folder.id).map { self.folder(at: Int(sortedChildren[$0])) }
    }

    public func parent(of folder: OccupancyFolder) -> OccupancyFolder? {
        let parent = Int(nodes[folder.id].parent)
        return parent < 0 ? nil : self.folder(at: parent)
    }

    public func path(of folder: OccupancyFolder) -> String {
        var names: [String] = []
        var index = folder.id
        while index > 0 {
            names.append(nodes[index].record.name)
            index = Int(nodes[index].parent)
        }
        return names.reversed().reduce(rootPath) { $0 + "/" + $1 }
    }

    /// Ordner an `path` (genau so geschrieben wie im Baum); `nil` außerhalb der Wurzel oder wenn er fehlt.
    public func folder(atPath path: String) -> OccupancyFolder? {
        guard RawPath.isPath(path, atOrBelow: rootPath) else { return nil }
        var index = 0
        for name in path.dropFirst(rootPath.count).split(separator: "/") {
            let first = Int(nodes[index].firstChild)
            guard let child = nodes[index].record.childIndex(named: String(name)) else { return nil }
            index = first + child
        }
        return folder(at: index)
    }

    /// Alle nicht erfassbaren Ordner in Breitensuche-Reihenfolge.
    public func uncapturedFolders() -> [OccupancyFolder] {
        nodes.indices.filter { nodes[$0].record.state.isUncaptured }.map(folder(at:))
    }

    private func childIndices(of index: Int) -> Range<Int> {
        let first = Int(nodes[index].firstChild)
        return first..<first + nodes[index].record.children.count
    }

    private func folder(at index: Int) -> OccupancyFolder {
        let node = nodes[index], record = node.record
        return OccupancyFolder(
            id: index, name: record.name, state: record.state, allocatedBytes: node.allocatedBytes, fileCount: record.fileCount,
            subfolderCount: record.children.count, uncapturedCount: record.uncapturedCount,
            modification: record.modification.map(Self.date), newestModification: record.newestModification.map(Self.date),
            largestFiles: record.files.largest
        )
    }

    private static func date(_ timestamp: OccupancyTimestamp) -> Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1e9)
    }
}

extension OccupancyTree {
    /// Geschätzter Speicher des Ergebnisses: Objekte und Listen mit ihrer Kapazität, Namen über 15 Byte (darunter
    /// liegen sie im String selbst), gerundet wie `malloc` auf 16 Byte. Für die Speichergrenze der Spec (§ 4.4).
    var estimatedMemory: Int {
        func rounded(_ size: Int) -> Int { (size + 15) & ~15 }
        func heap(_ string: String) -> Int { string.utf8.count > 15 ? rounded(32 + string.utf8.count + 1) : 0 }
        func heap<Element>(_ array: [Element]) -> Int {
            array.capacity == 0 ? 0 : rounded(32 + array.capacity * MemoryLayout<Element>.stride)
        }
        var total = heap(nodes) + heap(sortedChildren)
        for node in nodes {
            let record = node.record
            total += malloc_size(Unmanaged.passUnretained(record).toOpaque())
            total += heap(record.name) + heap(record.children) + heap(record.files.linked) + heap(record.files.largest)
            total += record.files.largest.reduce(0) { $0 + heap($1.name) }
        }
        return total
    }
}
