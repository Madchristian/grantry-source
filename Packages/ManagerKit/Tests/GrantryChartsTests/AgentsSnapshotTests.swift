import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich Agenten im Lagebild (LB-2.4, #541) in hell, dunkel und „Kontrast erhöhen“: Server gewählt mit Befund, Freigabe
/// gewählt, nichts gewählt, noch kein Scan, unvollständige Abdeckung. Native Knöpfe zeichnet `ImageRenderer` nicht; Knöpfe,
/// laufende Aktion und Fehlerbanner zeigt die Galerie (offscreen im Demo-Target).
@MainActor
@Suite struct AgentsSnapshotTests {
    @Test(arguments: SnapshotGallery.AgentsScene.allCases, ChartAppearance.allCases)
    func agents(_ scene: SnapshotGallery.AgentsScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.agents(scene), named: "agenten-\(scene.rawValue)",
                                 size: SnapshotGallery.agentsSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.agentsSize
        let light = try #require(ChartImage(SnapshotGallery.agents(.server), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.agents(.server), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver im Detail eines Eintrags liest (`RecordDetailPanel`): Gruppen als Überschrift, Angaben mit Schlüssel und
/// Wert, Hinweise mit Art – nie nur ein Titel (#563).
@MainActor
@Suite(.serialized) struct RecordDetailAccessibilityTests {
    @Test func detailReadsGroupsFactsAndNotes() async throws {
        let nodes = try await AccessibilityTree.nodes(of: RecordDetailPanel(content: SnapshotGallery.fileServerDetail),
                                                      size: CGSize(width: 700, height: 900))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Befehl",
                                                      value: "npx -y @example/server-files ~")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "EXAMPLE_TOKEN",
                                                      value: "Wert im Klartext in der Datei")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Fehler",
                                                      value: "Darf den ganzen Benutzerordner lesen und schreiben.")),
                "\(nodes)")
        #expect(nodes.contains { $0.label.hasPrefix("Umgebung") || $0.value.hasPrefix("Umgebung") }, "\(nodes)")
    }

    /// Hinweise ohne Gruppe stehen direkt unter dem Kopf (Spec §11.2 c).
    @Test func looseNotesAreRead() async throws {
        let nodes = try await AccessibilityTree.nodes(of: RecordDetailPanel(content: SnapshotGallery.approvalDetail),
                                                      size: CGSize(width: 700, height: 700))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "auffällig",
                                                      value: "Der Assistent führt Befehle aus, ohne vorher zu fragen.")),
                "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Einstellung",
                                                      value: "autoApprove = true")), "\(nodes)")
    }
}
