import ManagerKit
import SwiftUI

/// Wählt zur Art die Kachel (Spec 2026-11-09-uebersicht-baukasten § 8). Die einzige Stelle, die alle Kacheltypen kennt;
/// eine Kachel ändert nur ihre eigene Datei unter `Tiles/`, nicht diese.
struct OverviewTileContent: View {
    let kind: OverviewTileKind
    let span: OverviewTileSpan
    let source: OverviewTileSource
    let open: () -> Void

    var body: some View {
        switch kind {
        case .cpu: tile(OverviewCPUTile.self)
        case .cores: tile(OverviewCoresTile.self)
        case .processes: tile(OverviewProcessesTile.self)
        case .gpu: tile(OverviewGPUTile.self)
        case .memory: tile(OverviewMemoryTile.self)
        case .disk: tile(OverviewDiskTile.self)
        case .network: tile(OverviewNetworkTile.self)
        case .thermal: tile(OverviewThermalTile.self)
        case .battery: tile(OverviewBatteryTile.self)
        case .loadAverage: tile(OverviewLoadAverageTile.self)
        case .uptime: tile(OverviewUptimeTile.self)
        }
    }

    @ViewBuilder
    private func tile<Tile: OverviewTile>(_: Tile.Type) -> some View {
        if let value = Tile.value(from: source) {
            Tile(value: value, span: span, open: open)
        } else {
            OverviewTileUnmeasured(kind: kind, open: open)
        }
    }
}
