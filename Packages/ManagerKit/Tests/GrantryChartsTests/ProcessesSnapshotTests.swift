import SwiftUI
import Testing
@testable import GrantryCharts

/// Aufräumen › Prozesse im Lagebild (LB-4.4, #550) in hell, dunkel und „Kontrast erhöhen“: Ergebnis mit aufgeklapptem
/// Agenten-Baum, vor dem Scan, Scan läuft, Beenden läuft, Teilerfolg, Fehler beim Lesen, nichts gefunden. Native Knöpfe
/// zeichnet `ImageRenderer` nicht; die Leiste zeigt die Galerie (offscreen). Neu aufzeichnen mit
/// `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct ProcessesSnapshotTests {
    @Test(arguments: SnapshotGallery.ProcessesScene.allCases, ChartAppearance.allCases)
    func processes(_ scene: SnapshotGallery.ProcessesScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.processes(scene), named: "processes-\(scene.rawValue)",
                                 size: SnapshotGallery.processesSize, appearance: appearance)
    }

    @Test func memberRowReadsLabelAndValue() {
        #expect(DisclosureMemberRow.spokenValue("PID 48211 · 512 MB") == "PID 48211 · 512 MB")
    }
}

/// Was VoiceOver liest: Agenten-Baum als Häkchenzeile und Aufklapp-Knopf, Prozess mit PID und Speicher, Hinweis,
/// Umfang und Ausgang je Posten – jedes Element mit Beschriftung und Wert (Spec § 7, #563).
@MainActor
@Suite(.serialized) struct ProcessesAccessibilityTests {
    @Test func resultReadsTreeMembersAndScope() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SnapshotGallery.processes(.result),
                                                      size: SnapshotGallery.processesSize)
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "node" && $0.value == "812 MB, aufgeklappt" },
                "\(nodes)")
        #expect(nodes.contains { $0.label == "node" && $0.value.hasPrefix("ausgewählt") }, "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "node server.js",
                                                      value: "PID 48211 · 512 MB")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Umfang",
                                                      value: "Ausgewählt: 2 Agenten-Bäume · 7 Prozesse · 1,3 GB")),
                "\(nodes)")
    }

    @Test func partialReadsOutcomes() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SnapshotGallery.processes(.partial),
                                                      size: SnapshotGallery.processesSize)
        #expect(nodes.contains { $0.label == "node" && $0.value == "läuft weiter, 1 Prozess läuft noch." }, "\(nodes)")
        #expect(nodes.contains { $0.label == "1 beendet (470 MB Arbeitsspeicher), 1 läuft noch" }, "\(nodes)")
    }
}
