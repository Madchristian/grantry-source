import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich Apps im Lagebild (LB-2.5, #542) in hell, dunkel und „Kontrast erhöhen“: gewählt mit Befund, nichts gewählt,
/// akzeptiertes Risiko mit Fehler beim Speichern, Sortierung nach Größe (eine Gruppe), noch kein Scan, unvollständige
/// Abdeckung. Native Knöpfe zeichnet `ImageRenderer` nicht; Knöpfe und laufende Aktion zeigt die Galerie (offscreen).
@MainActor
@Suite struct AppsSnapshotTests {
    @Test(arguments: SnapshotGallery.AppsScene.allCases, ChartAppearance.allCases)
    func apps(_ scene: SnapshotGallery.AppsScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.apps(scene), named: "apps-\(scene.rawValue)",
                                 size: SnapshotGallery.appsSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.appsSize
        let light = try #require(ChartImage(SnapshotGallery.apps(.selected), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.apps(.selected), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver im Detail einer App liest: Angaben mit Schlüssel und Wert, Hinweise mit Art, Sprungzeilen als Knopf mit
/// Name, Zustand und Ziel, laufende Aktion mit Text – nie nur ein Titel (#563).
@MainActor
@Suite(.serialized) struct AppDetailAccessibilityTests {
    @Test func detailReadsFactsNotesLinksAndRunningAction() async throws {
        let nodes = try await AccessibilityTree.nodes(of: AppDetailSampleView(sample: SnapshotGallery.remoteHelpDetail, showsRunning: true),
                                                      size: CGSize(width: 700, height: 1000))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Version", value: "3.2 (412)")),
                "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Pfad",
                                                      value: "/Applications/Fernhilfe.app")), "\(nodes)")
        #expect(nodes.contains { $0.value == "Nicht notarisiert und darf andere Apps steuern." && !$0.label.isEmpty },
                "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXButton", label: "Bedienungshilfen",
                                                      value: "auffällig, erlaubt, prüfen, mittlerer Schweregrad. "
                                                          + "Benutzer")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "läuft", value: "Wird entfernt …")),
                "\(nodes)")
    }

    /// Bei akzeptiertem Risiko stehen die Prüfhinweise unter eigener Überschrift, der Fehler beim Speichern bleibt lesbar.
    @Test func acceptedDetailReadsAcceptedNotesAndError() async throws {
        let nodes = try await AccessibilityTree.nodes(of: AppDetailSampleView(sample: SnapshotGallery.acceptedCaptureDetail),
                                                      size: CGSize(width: 700, height: 900))
        #expect(nodes.contains { $0.label.hasPrefix("Akzeptierte Prüfhinweise") }, "\(nodes)")
        #expect(nodes.contains { $0.value == "Darf den Bildschirm aufnehmen." }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Eigene Einschätzung" && $0.value == "Risiko akzeptiert" }, "\(nodes)")
        #expect(nodes.contains { $0.value == "Entscheidung nicht gespeichert: Die Datei ist schreibgeschützt." },
                "\(nodes)")
        #expect(!nodes.contains { $0.label == "Hinweise" }, "\(nodes)")
    }
}
