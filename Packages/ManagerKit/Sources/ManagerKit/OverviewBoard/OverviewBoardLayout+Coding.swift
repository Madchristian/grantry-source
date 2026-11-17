import Foundation

/// Speicherung (Spec § 6): `{"version":1,"tiles":[{"kind":"cpu","span":"4x1"}, …]}`. Unbekannte Kacheln (aus einer
/// späteren Version) und Einträge ohne Art oder Größe fallen weg, eine unbekannte Größe wird zur Standardgröße. Eine
/// fehlende oder neuere Version lässt das Lesen scheitern – der Aufrufer behält dann den Standard und überschreibt die
/// gespeicherte Anordnung erst, wenn Christian sie ändert.
extension OverviewBoardLayout: Codable {
    public static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version, tiles
    }

    private enum TileKeys: String, CodingKey {
        case kind, span
    }

    /// Eintrag der Liste, der beim Lesen nie scheitert.
    private struct StoredTile: Decodable {
        let tile: OverviewTile?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TileKeys.self)
            guard let kind = (try? container.decode(String.self, forKey: .kind)).flatMap(OverviewTileKind.init),
                  let code = try? container.decode(String.self, forKey: .span) else {
                tile = nil
                return
            }
            tile = OverviewTile(kind, OverviewTileSpan(code: code) ?? kind.defaultSpan)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                   debugDescription: "Unbekannte Version \(version)")
        }
        let stored = try container.decode([StoredTile].self, forKey: .tiles)
        self.init(tiles: stored.compactMap(\.tile))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        var list = container.nestedUnkeyedContainer(forKey: .tiles)
        for tile in tiles {
            var entry = list.nestedContainer(keyedBy: TileKeys.self)
            try entry.encode(tile.kind, forKey: .kind)
            try entry.encode(tile.span, forKey: .span)
        }
    }

    /// Übernahme aus #495: der Standard ohne die Kacheln der dort ausgeblendeten Karten.
    public init(migratingHiddenCards hidden: Set<MenuBarOverviewCard>, configured: Set<TaskManagerSource>) {
        let removed = Set(hidden.flatMap(\.tileKinds))
        self.init(tiles: Self.standard(configured: configured).tiles.filter { !removed.contains($0.kind) })
    }
}

extension MenuBarOverviewCard {
    /// Kacheln, die diese Karte aus #495 ersetzen; „Last und Laufzeit“ sind zwei.
    public var tileKinds: [OverviewTileKind] {
        switch self {
        case .cpu: [.cpu]
        case .cores: [.cores]
        case .processes: [.processes]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .disk: [.disk]
        case .network: [.network]
        case .thermal: [.thermal]
        case .battery: [.battery]
        case .summary: [.loadAverage, .uptime]
        }
    }
}
