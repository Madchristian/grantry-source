import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Tab „Wachbuch“ (TM-12.5, #383) in hell, dunkel und „Kontrast erhöhen“: eine Stunde mit Zeitmarke, 24 Stunden,
/// 7 Tage, „aus“ und „noch keine Aufzeichnung“. Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`;
/// `GRANTRY_GALLERY_DIR=<Ordner>` schreibt zusätzlich die Galerie (alle Lagen im Raster) für `docs/design/galerie`.
@MainActor
@Suite struct WatchbookSnapshotTests {
    nonisolated static let cases = SnapshotGallery.WatchbookScene.allCases.flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: cases)
    func watchbook(_ scene: SnapshotGallery.WatchbookScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.watchbook(scene), named: "watchbook-\(scene.rawValue)",
                                 size: SnapshotGallery.watchbookSize, appearance: appearance)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"] != nil),
          arguments: ChartAppearance.allCases)
    func gallery(_ appearance: ChartAppearance) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"])
        let size = CGSize(width: SnapshotGallery.watchbookSize.width * 2 + 48,
                          height: SnapshotGallery.watchbookSize.height * 3 + 64)
        let image = try #require(ChartImage(SnapshotGallery.watchbookGallery, size: size, appearance: appearance))
        let name = ["light": "hell", "dark": "dunkel", "contrast": "kontrast"][appearance.rawValue] ?? appearance.rawValue
        try #require(image.png).write(to: URL(filePath: directory).appending(path: "wachbuch-\(name).png"))
    }
}
