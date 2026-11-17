import SwiftUI
import Testing
@testable import GrantryCharts

/// Aufräumen › Speicher im Lagebild (LB-4.3, #549) in hell, dunkel und „Kontrast erhöhen“: Ergebnis, vor dem Scan ohne
/// Festplattenvollzugriff, Scan läuft, Aufräumen läuft (Häkchen gesperrt und blass) und Teilerfolg mit Details. Native
/// Knöpfe zeichnet `ImageRenderer` nicht; Knöpfe und laufende Aktion zeigt die Galerie (offscreen).
@MainActor
@Suite struct StorageSnapshotTests {
    @Test(arguments: SnapshotGallery.StorageScene.allCases, ChartAppearance.allCases)
    func storage(_ scene: SnapshotGallery.StorageScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.storage(scene), named: "speicher-\(scene.rawValue)",
                                 size: SnapshotGallery.storageSize, appearance: appearance)
    }

    /// Risiko je Eintrag (#611): VoiceOver liest den Chip im Wert der Häkchenzeile mit.
    @Test func entryReadsItsRisk() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SnapshotGallery.storage(.result),
                                                      size: SnapshotGallery.storageSize)
        #expect(nodes.contains { $0.label == "Archives" && $0.value.hasPrefix("nicht ausgewählt, Risiko mittel") },
                "\(nodes)")
    }
}
