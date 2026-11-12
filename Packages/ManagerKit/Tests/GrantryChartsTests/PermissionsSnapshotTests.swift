import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich Berechtigungen im Lagebild (LB-2.2, #539) in hell, dunkel und „Kontrast erhöhen“: nach App gewählt mit Befund
/// und laufender Aktion, nichts gewählt, nach Berechtigung, noch kein Scan, unvollständige Abdeckung. Native Knöpfe
/// zeichnet `ImageRenderer` nicht; Knöpfe und Fehlerbanner zeigt die Galerie (offscreen im Demo-Target).
@MainActor
@Suite struct PermissionsSnapshotTests {
    @Test(arguments: SnapshotGallery.PermissionsScene.allCases, ChartAppearance.allCases)
    func permissions(_ scene: SnapshotGallery.PermissionsScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.permissions(scene), named: "berechtigungen-\(scene.rawValue)",
                                 size: SnapshotGallery.permissionsSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.permissionsSize
        let light = try #require(ChartImage(SnapshotGallery.permissions(.byApp), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.permissions(.byApp), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver im Detail einer Berechtigungsgruppe liest: Kopf als Überschrift, Angaben mit Schlüssel und Wert, je
/// Berechtigung Name mit Zustand und Hinweis mit Art – nie nur ein Titel (#563).
@MainActor
@Suite(.serialized) struct GrantDetailAccessibilityTests {
    @Test func detailReadsFactsGrantsAndNotes() async throws {
        let nodes = try await AccessibilityTree.nodes(of: GrantDetailPanel(content: SnapshotGallery.recorderDetail),
                                                      size: CGSize(width: 700, height: 700))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Signatur",
                                                      value: "Developer ID · Beispiel GmbH (A1B2C3D4E5)")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Bedienungshilfen",
                                                      value: "auffällig, erlaubt, prüfen, mittlerer Schweregrad. "
                                                          + "Benutzer · geändert am 8. Nov. 2026")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "auffällig",
                                                      value: "Steuert andere Apps – nur erlauben, wenn du die App "
                                                          + "dafür brauchst.")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "läuft",
                                                      value: "Wird zurückgesetzt …")), "\(nodes)")
    }

    /// Ohne Einträge sagt das Detail das, statt eine leere Gruppe zu zeigen.
    @Test func emptyGrantsSayso() async throws {
        let content = GrantDetailContent(symbol: "note.text", title: "Notizblock", subtitle: "com.example.notes",
                                         grantsTitle: "Berechtigungen", emptyGrantsText: "Keine Berechtigungen",
                                         grants: [])
        let nodes = try await AccessibilityTree.nodes(of: GrantDetailPanel(content: content))
        #expect(nodes.contains { $0.label == "Keine Berechtigungen" || $0.value == "Keine Berechtigungen" }, "\(nodes)")
    }
}
