import SwiftUI
import Testing
@testable import GrantryCharts

/// Aufräumen › App-Reste im Lagebild (LB-4.2, #548) in hell, dunkel und „Kontrast erhöhen“: Ergebnis, vor der Suche,
/// Suche läuft, veraltet, Papierkorb läuft, Teilerfolg, keine Reste. Native Knöpfe zeichnet `ImageRenderer` nicht;
/// Knöpfe und laufende Aktion zeigt die Galerie (offscreen).
@MainActor
@Suite struct CleanupSnapshotTests {
    @Test(arguments: SnapshotGallery.LeftoversScene.allCases, ChartAppearance.allCases)
    func leftovers(_ scene: SnapshotGallery.LeftoversScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.leftovers(scene), named: "aufraeumen-reste-\(scene.rawValue)",
                                 size: SnapshotGallery.leftoversSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.leftoversSize
        let light = try #require(ChartImage(SnapshotGallery.leftovers(.result), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.leftovers(.result), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}
