import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Tab „Leistung“ mit langem Leistungsverlauf aus dem Wachbuch (TM-14.5, #398) in hell, dunkel und „Kontrast erhöhen“:
/// 1 h gesamt, 24 h je Block mit Lücken, 7 Tage gesamt und Wachbuch aus. Neu aufzeichnen mit
/// `GRANTRY_RECORD_SNAPSHOTS=1`; `GRANTRY_GALLERY_DIR=<Ordner>` schreibt zusätzlich die Galerie für `docs/design/galerie`.
@MainActor
@Suite struct PowerHistorySnapshotTests {
    nonisolated static let cases = SnapshotGallery.PowerScene.allCases.flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: cases)
    func powerHistory(_ scene: SnapshotGallery.PowerScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.powerHistory(scene), named: "power-history-\(scene.rawValue)",
                                 size: SnapshotGallery.powerHistorySize, appearance: appearance)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"] != nil),
          arguments: ChartAppearance.allCases)
    func gallery(_ appearance: ChartAppearance) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"])
        let size = CGSize(width: SnapshotGallery.powerHistorySize.width * 2 + 48,
                          height: SnapshotGallery.powerHistorySize.height * 2 + 48)
        let image = try #require(ChartImage(SnapshotGallery.powerHistoryGallery, size: size, appearance: appearance))
        let name = ["light": "hell", "dark": "dunkel", "contrast": "kontrast"][appearance.rawValue] ?? appearance.rawValue
        try #require(image.png).write(to: URL(filePath: directory).appending(path: "leistungsverlauf-\(name).png"))
    }
}
