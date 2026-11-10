import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Ansicht „Belegung“ (TM-15.4, #403) in hell, dunkel und „Kontrast erhöhen“: vor dem Scan, während, fertig und mit
/// nicht erfassten Orten, dazu gescheitert und ganzer Datenträger (TM-15.6, #405). Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`; `GRANTRY_GALLERY_DIR=<Ordner>` schreibt
/// zusätzlich die Galerie (alle Lagen im Raster) für `docs/design/galerie`.
@MainActor
@Suite struct OccupancySnapshotTests {
    nonisolated static let cases = SnapshotGallery.OccupancyScene.allCases.flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: cases)
    func occupancy(_ scene: SnapshotGallery.OccupancyScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.occupancy(scene), named: "occupancy-\(scene.rawValue)",
                                 size: SnapshotGallery.occupancySize, appearance: appearance)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"] != nil),
          arguments: ChartAppearance.allCases)
    func gallery(_ appearance: ChartAppearance) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"])
        let size = CGSize(width: SnapshotGallery.occupancySize.width * 2 + 48,
                          height: SnapshotGallery.occupancySize.height * 2 + 48)
        let image = try #require(ChartImage(SnapshotGallery.occupancyGallery, size: size, appearance: appearance))
        let name = ["light": "hell", "dark": "dunkel", "contrast": "kontrast"][appearance.rawValue] ?? appearance.rawValue
        try #require(image.png).write(to: URL(filePath: directory).appending(path: "belegung-\(name).png"))
    }
}
