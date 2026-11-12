import SwiftUI
import Testing
@testable import GrantryCharts

/// Blatt „App entfernen“ im Lagebild (LB-4.5, #551) in hell, dunkel und „Kontrast erhöhen“: die Zustände des
/// abgenommenen Entwurfs LB-4.1 (#547). Native Knöpfe zeichnet `ImageRenderer` nicht; Knöpfe zeigt die Galerie (offscreen).
@MainActor
@Suite struct RemovalSheetSnapshotTests {
    @Test(arguments: SnapshotGallery.RemovalScene.allCases, ChartAppearance.allCases)
    func removal(_ scene: SnapshotGallery.RemovalScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.removal(scene), named: "app-entfernen-\(scene.rawValue)",
                                 size: SnapshotGallery.removalSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.removalSize
        let light = try #require(ChartImage(SnapshotGallery.removal(.selection), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.removal(.selection), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Schritte der Selbstdeinstallation: Titel als Beschriftung, Zustand als Wert (#563).
@MainActor
@Suite struct ProcedureStepTests {
    @Test func stepReadsStateAsValue() {
        let step = ProcedureStep(id: "trash", title: "In den Papierkorb legen",
                                 state: StatusItem("Läuft …", tone: .info), isRunning: true)
        #expect(step.spokenValue == "Läuft …")
        #expect(step.id == "trash")
    }
}

/// Was VoiceOver im Blatt liest: Titel und Ort (auswählbarer Text, daher als Wert), Gruppen, Häkchenzeilen, Hinweise,
/// Umfang und Schritte – jedes Element mit Beschriftung und Wert (Spec § 7).
@MainActor
@Suite(.serialized) struct RemovalSheetAccessibilityTests {
    @Test func selectionReadsHeadGroupsRowsNotesAndScope() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SnapshotGallery.removal(.selection),
                                                      size: SnapshotGallery.removalSize)
        #expect(nodes.contains { $0.value == "„Alter Scanner“ entfernen" }, "\(nodes)")
        #expect(nodes.contains { $0.value == "/Applications/Alter Scanner.app" }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Caches" && $0.value == "1 Eintrag, Summe 1,4 GB" }, "\(nodes)")
        #expect(nodes.contains { $0.label == "~/Library/Application Support/Beispiel GmbH"
            && $0.value.hasPrefix("nicht ausgewählt, Zuordnung unsicher") }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Hinweis" && $0.value.hasPrefix("Bringt eine Systemerweiterung mit") },
                "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Umfang",
                                                      value: SnapshotGallery.removalScope)), "\(nodes)")
    }

    @Test func progressReadsEachStepWithState() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SnapshotGallery.removal(.uninstallRunning),
                                                      size: SnapshotGallery.removalSize)
        #expect(nodes.contains { $0.value == "Grantry wird deinstalliert …" }, "\(nodes)")
        #expect(nodes.contains { $0.label == "In den Papierkorb legen" && $0.value == "Läuft …" }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Finder-Automation zurücksetzen" && $0.value == "Ausstehend" }, "\(nodes)")
    }
}
