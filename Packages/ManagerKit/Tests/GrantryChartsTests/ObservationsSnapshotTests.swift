import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich Beobachtungen im Lagebild (LB-3.4, #546; Entwurf LB-3.1, #543) in hell, dunkel und „Kontrast erhöhen“:
/// beendete Beobachtung mit Bilanz und Aufräumen, laufende Beobachtung, keine Änderungen, keine Beobachtungen und Blatt
/// „Installation beobachten“ beim Erfassen; die übrigen Zustände zeigt die Galerie offscreen.
/// Native Knöpfe und Textfelder zeichnet `ImageRenderer` nicht; sie zeigt die Galerie (offscreen).
@MainActor
@Suite struct ObservationsSnapshotTests {
    @Test(arguments: SnapshotGallery.ObservationsScene.allCases, ChartAppearance.allCases)
    func observations(_ scene: SnapshotGallery.ObservationsScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.observations(scene), named: "beobachtungen-\(scene.rawValue)",
                                 size: scene.size, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let scene = SnapshotGallery.ObservationsScene.finished
        let light = try #require(ChartImage(SnapshotGallery.observations(scene), size: scene.size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.observations(scene), size: scene.size,
                                               appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver im Detail einer Beobachtung liest: Bilanz mit Zahl als Wert, Sprungzeilen als Knopf mit Name, Zustand
/// und Ziel, Häkchenzeilen als Schalter mit Zustand, frühere Durchgänge mit Schlüssel und Wert, laufende Aktion mit Text.
@MainActor
@Suite(.serialized) struct ObservationDetailAccessibilityTests {
    @Test func finishedDetailReadsBalanceEntriesCleanupAndRecords() async throws {
        let nodes = try await AccessibilityTree.nodes(of: ObservationDetailSampleView(sample: .finished, runningText:
                                                          "Wird aufgeräumt …"),
                                                      size: CGSize(width: 760, height: 1600))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Neu", value: "3")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Entfernt", value: "0")),
                "\(nodes)")
        #expect(nodes.contains {
            $0.role == "AXButton" && $0.label == "Bildschirmaufnahme"
                && $0.value.hasPrefix("auffällig, neu, Zuordnung unsicher")
        }, "\(nodes)")
        #expect(nodes.contains {
            $0.label == "Beispiel-Editor.app" && $0.value.hasPrefix("ausgewählt, 412 MB")
        }, "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Bildschirmaufnahme",
                                                      value: "nicht zurückgesetzt: Eintrag hat sich geändert")),
                "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "läuft", value: "Wird aufgeräumt …")),
                "\(nodes)")
    }

    @Test func startFormReadsFieldsWithKeys() async throws {
        let nodes = try await AccessibilityTree.nodes(of: ObservationStartSampleView(state: .blocked),
                                                      size: CGSize(width: 480, height: 420))
        #expect(nodes.contains { $0.label.contains("Name") }, "\(nodes)")
        #expect(nodes.contains { $0.value.hasPrefix("Die Beobachtung „Beispiel-Werkzeug“ läuft bereits") },
                "\(nodes)")
    }
}
