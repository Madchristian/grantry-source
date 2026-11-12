import AppKit
import SwiftUI
import Testing
@testable import GrantryCharts

/// Zentrale Bausteine der Liste-Detail-Ansichten (LB-1.2, #536) in hell, dunkel und „Kontrast erhöhen“: Liste mit
/// Befund und gewählter Zeile samt Detail, nichts gewählt, Banner und Hinweise, Häkchenzeilen mit Fortschritt.
/// Referenzen unter `__Snapshots__`. Native Knöpfe zeichnet `ImageRenderer` nicht; die Galerie mit Knöpfen entsteht
/// offscreen im Demo-Target (`DemoSnapshots`).
@MainActor
@Suite struct LagebildSnapshotTests {
    @Test(arguments: SnapshotGallery.LagebildScene.allCases, ChartAppearance.allCases)
    func lagebild(_ scene: SnapshotGallery.LagebildScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.lagebild(scene), named: "lagebild-\(scene.rawValue)",
                                 size: SnapshotGallery.lagebildSize, appearance: appearance)
    }

    /// „Kontrast erhöhen“ zeichnet sichtbar anders als hell (Ränder, Häkchen-Rand).
    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.lagebildSize
        let light = try #require(ChartImage(SnapshotGallery.lagebild(.listDetail), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.lagebild(.listDetail), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}
