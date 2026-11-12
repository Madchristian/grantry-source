import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich Autostart im Lagebild (LB-2.3, #540) in hell, dunkel und „Kontrast erhöhen“: gewählt mit Befund, nichts
/// gewählt, schreibgeschützt, noch kein Scan, unvollständige Abdeckung, keine Treffer. Native Knöpfe zeichnet
/// `ImageRenderer` nicht; Knöpfe, laufende Aktion und Fehlerbanner zeigt die Galerie (offscreen im Demo-Target).
@MainActor
@Suite struct AutostartSnapshotTests {
    @Test(arguments: SnapshotGallery.AutostartScene.allCases, ChartAppearance.allCases)
    func autostart(_ scene: SnapshotGallery.AutostartScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.autostart(scene), named: "autostart-\(scene.rawValue)",
                                 size: SnapshotGallery.autostartSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.autostartSize
        let light = try #require(ChartImage(SnapshotGallery.autostart(.selected), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.autostart(.selected), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver im Detail eines Autostart-Eintrags (`RecordDetailPanel`) liest: Angaben mit Schlüssel und Wert, auch
/// den Befehl, Hinweise mit Art, Gruppen als Überschrift – nie nur ein Titel (#563).
@MainActor
@Suite(.serialized) struct AutostartDetailAccessibilityTests {
    @Test func detailReadsFactsCommandAndNotes() async throws {
        let nodes = try await AccessibilityTree.nodes(of: RecordDetailPanel(content: SnapshotGallery.updaterDetail),
                                                      size: CGSize(width: 700, height: 700))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Signatur",
                                                      value: "nicht signiert")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Befehl",
                                                      value: "/bin/sh run.sh --quiet --token ****")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "auffällig",
                                                      value: "Startet ein Skript aus dem Benutzerordner bei jeder "
                                                          + "Anmeldung.")), "\(nodes)")
        #expect(nodes.contains { $0.label.hasPrefix("Hinweise") }, "\(nodes)")
    }
}
