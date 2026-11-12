import SwiftUI
import Testing
@testable import GrantryCharts

/// Übersicht im Lagebild (LB-3.2, #544) in hell, dunkel und „Kontrast erhöhen“: auffällig, ruhig mit laufender
/// Beobachtung, unvollständig geprüft (Schildform offen), noch kein Scan. Native Knöpfe zeichnet `ImageRenderer` nicht;
/// Knöpfe und Banner zeigt die Galerie (offscreen im Demo-Target).
@MainActor
@Suite struct OverviewSnapshotTests {
    @Test(arguments: SnapshotGallery.OverviewScene.allCases, ChartAppearance.allCases)
    func overview(_ scene: SnapshotGallery.OverviewScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.overview(scene), named: "uebersicht-\(scene.rawValue)",
                                 size: SnapshotGallery.overviewSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.overviewSize
        let light = try #require(ChartImage(SnapshotGallery.overview(.findings), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.overview(.findings), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver in der Übersicht liest: Kacheln und Sprungzeilen als Knöpfe mit Beschriftung und Wert (#563).
@MainActor
@Suite(.serialized) struct OverviewAccessibilityTests {
    @Test func jumpTileIsAButtonWithTitleAndValue() async throws {
        let nodes = try await AccessibilityTree.nodes(of: JumpTile(title: "Auffällig", value: 2,
                                                                   detail: "1 hoch · 1 mittel", tone: .finding,
                                                                   destination: "Apps") {})
        #expect(nodes == [AccessibilityTree.Node(role: "AXButton", label: "Auffällig", value: "2. 1 hoch · 1 mittel")],
                "\(nodes)")
    }

    @Test func recentChangeIsAJumpButton() async throws {
        let nodes = try await AccessibilityTree.nodes(of: RecentChangesOverviewPanel(
            changes: Array(SnapshotGallery.overviewChanges.prefix(1)), emptyText: "") {} select: { _ in })
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXButton", label: "com.example.updater",
                                                      value: "neu. Neuer Autostart-Eintrag · vor 12 Minuten")),
                "\(nodes)")
    }
}
