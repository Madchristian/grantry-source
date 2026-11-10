/// Hinweise zu einem Ordner der Belegung (TM-15.3, #402; Spec 2026-11-08 § 5.4): die Kategorie des Speicher-Aufräumens,
/// zu der er gehört, und Grantrys Time-Machine-Vorschlag, der ihn umfasst. Nur Hinweise – kein Löschweg (Entscheidung
/// O4): Aufgeräumt wird ausschließlich über die Kategorie in Aufräumen › Speicher.
public struct OccupancyFolderHint: Hashable, Sendable {
    public static let empty = OccupancyFolderHint(category: nil, timeMachineCandidate: nil)

    /// Innerste Kategorie, die den Ordner umfasst, mit ihrem Risiko; ihre `id` ist das Sprungziel in Speicher. `nil`: keine.
    public let category: StorageCategory?
    /// Vorschlag, den Ordner oder einen übergeordneten aus Time Machine auszunehmen (#227); `nil`: keiner.
    public let timeMachineCandidate: TimeMachineCandidate?

    public init(category: StorageCategory?, timeMachineCandidate: TimeMachineCandidate?) {
        self.category = category
        self.timeMachineCandidate = timeMachineCandidate
    }

    /// „Über Speicher aufräumbar“: Die Kategorie räumt selbst auf, statt nur zu berichten.
    public var isCleanable: Bool { category.map { $0.risk != .reportOnly } ?? false }
}

/// Ordnet Ordner der Belegung den Kategorien und Time-Machine-Vorschlägen des `StorageCatalog` zu. Verschachtelte Orte
/// (Homebrew und llama.cpp in den Caches): Der innerste gewinnt. Einträge, die eine Kategorie bewusst auslässt
/// (`StorageCategoryLocation.includesEntry`), gehören zur nächsten äußeren, die sie umfasst. Build-Ordner alter Projekte
/// hängen am Alter des Projekts und werden nicht zugeordnet.
///
/// Der Aufbau liest die Orte der Nur-Bericht-Kategorien (wenige Ordnerlisten) und gehört daher außerhalb des
/// Hauptthreads; die Abfrage je Ordner ist reine Rechnung (je übergeordnetem Ordner ein Wörterbuchzugriff), ohne E/A.
public struct OccupancyHints: Sendable {
    private struct Claim: Sendable {
        let category: StorageCategory
        let location: StorageCategoryLocation
    }

    /// Je Ort die Kategorien in Katalogreihenfolge.
    private let claims: [String: [Claim]]
    private let candidates: [String: TimeMachineCandidate]

    /// Mit den Kategorien und Vorschlägen der App.
    public init(configuration: StorageCatalog.Configuration) {
        self.init(providers: StorageCatalog.providers(configuration),
                  timeMachineCandidates: StorageCatalog.timeMachineCandidates(configuration))
    }

    init(providers: [any StorageCategoryProvider], timeMachineCandidates: [TimeMachineCandidate]) {
        var claims: [String: [Claim]] = [:]
        for provider in providers {
            let category = provider.category
            for location in provider.locations {
                claims[location.path, default: []].append(Claim(category: category, location: location))
            }
        }
        self.claims = claims
        candidates = Dictionary(timeMachineCandidates.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Hinweise zu `path` (absolut, wie im `OccupancyTree`; auch in der Schreibweise des Datenvolumes).
    public func hint(forPath path: String) -> OccupancyFolderHint {
        guard let components = RawPath.components(of: MountedVolume.firmlinkedPath(path)) else { return .empty }
        // `prefixes[index]` ist der übergeordnete Ordner von `components[index]`; der letzte ist der Ordner selbst.
        let prefixes = RawPath.prefixes(of: components)
        var category: StorageCategory?, candidate: TimeMachineCandidate?
        for index in prefixes.indices.reversed() where category == nil || candidate == nil {
            let folder = prefixes[index], entry = index < components.count ? components[index] : nil
            if category == nil {
                category = claims[folder]?.first { claim in entry.map(claim.location.includesEntry) ?? true }?.category
            }
            if candidate == nil { candidate = candidates[folder] }
        }
        return OccupancyFolderHint(category: category, timeMachineCandidate: candidate)
    }
}

extension OccupancyHints {
    /// Über Speicher aufräumbarer Platz im Baum (Zustandszeile, Belegungsband, Detail der Belegung, TM-15.4): die Orte
    /// aufräumender Kategorien ohne die Einträge, die sie bewusst auslassen; Dateien direkt im Ort zählen mit. Ein Ort
    /// innerhalb eines anderen, der ihn umfasst, zählt nur dort. Reine Rechnung über den Baum, ohne E/A.
    public func cleanable(in tree: OccupancyTree) -> OccupancyCleanable {
        var located: [(folder: OccupancyFolder, location: StorageCategoryLocation)] = []
        for (path, claims) in claims {
            guard let folder = tree.folder(atPath: path) ?? tree.folder(atPath: MountedVolume.dataVolumePrefix + path),
                  let claim = claims.first(where: { $0.category.risk != .reportOnly }) else { continue }
            located.append((folder, claim.location))
        }
        let locations = Dictionary(located.map { ($0.folder.id, $0.location) }, uniquingKeysWith: { first, _ in first })
        var bytesByFolder: [Int: Int64] = [:]
        for (folder, location) in located where OccupancyCleanable.enclosingLocation(of: folder, in: tree,
                                                                                         locations: locations) == nil {
            let subfolders = tree.subfolders(of: folder)
            let files = folder.allocatedBytes - subfolders.reduce(0) { $0 + $1.allocatedBytes }
            let bytes = subfolders.filter { location.includesEntry($0.name) }.reduce(max(0, files)) { $0 + $1.allocatedBytes }
            var current: OccupancyFolder? = folder
            while let ancestor = current {
                bytesByFolder[ancestor.id, default: 0] += bytes
                current = tree.parent(of: ancestor)
            }
        }
        return OccupancyCleanable(bytesByFolder: bytesByFolder, locations: locations)
    }
}

/// Aufräumbarer Platz je Ordner eines Belegungsbaums (`OccupancyHints.cleanable(in:)`); gilt nur für diesen Baum.
public struct OccupancyCleanable: Sendable {
    /// Orte und alle Ordner darüber mit der Summe darunter.
    let bytesByFolder: [Int: Int64]
    /// Aufräumende Orte nach Ordner-`id`.
    let locations: [Int: StorageCategoryLocation]

    /// Aufräumbar im ganzen Baum.
    public var total: Int64 { bytesByFolder[0] ?? 0 }

    /// Aufräumbar in `folder`: über einem Ort die Summe der Orte darunter, in einem Ort der ganze Ordner, sofern sein
    /// Eintrag im Ort dazugehört.
    public func bytes(in folder: OccupancyFolder, of tree: OccupancyTree) -> Int64 {
        if let bytes = bytesByFolder[folder.id] { return bytes }
        return Self.enclosingLocation(of: folder, in: tree, locations: locations) != nil ? folder.allocatedBytes : 0
    }

    /// Der nächste Ort über `folder`, zu dem der Eintrag auf dem Weg dorthin gehört; `nil`, wenn keiner ihn umfasst.
    static func enclosingLocation(of folder: OccupancyFolder, in tree: OccupancyTree,
                                  locations: [Int: StorageCategoryLocation]) -> Int? {
        var entry = folder
        while let parent = tree.parent(of: entry) {
            if let location = locations[parent.id], location.includesEntry(entry.name) { return parent.id }
            entry = parent
        }
        return nil
    }
}
