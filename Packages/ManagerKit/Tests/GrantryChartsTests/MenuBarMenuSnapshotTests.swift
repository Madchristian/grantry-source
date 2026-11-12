import SwiftUI
import Testing
@testable import GrantryCharts

/// Menüleisten-Menü im Lagebild (LB-5.4, #555) in hell, dunkel und „Kontrast erhöhen“ für die Zustände des Entwurfs
/// LB-5.1 (#552): ruhig, mit Hinweisen, Scan und Beobachtung laufen, noch kein Scan (Schildform offen), Fehler der Ablage.
/// Native Knöpfe zeichnet `ImageRenderer` nur als Platzhalter; echt zeigt sie die Galerie (offscreen im Demo-Target).
@MainActor
@Suite struct MenuBarMenuSnapshotTests {
    @Test(arguments: SnapshotGallery.MenuBarMenuScene.allCases, ChartAppearance.allCases)
    func menu(_ scene: SnapshotGallery.MenuBarMenuScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.menuBarMenu(scene), named: "menueleiste-menue-\(scene.rawValue)",
                                 size: SnapshotGallery.menuBarMenuSize(scene), appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.menuBarMenuSize(.notices)
        let light = try #require(ChartImage(SnapshotGallery.menuBarMenu(.notices), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.menuBarMenu(.notices), size: size,
                                               appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }

    /// Ungelesen fett (Spec § 11.5 g): Die Zeile zeichnet sich dann anders als gelesen.
    @Test func unreadChangeIsDrawnDifferently() throws {
        let size = CGSize(width: 352, height: 60)
        func line(unread: Bool) -> some View {
            ChangeLine(symbol: "plus", title: "Neuer LaunchAgent", detail: "com.example.updater",
                       time: "vor 5 Minuten", isUnread: unread)
        }
        let unread = try #require(ChartImage(line(unread: true), size: size, appearance: .light))
        let read = try #require(ChartImage(line(unread: false), size: size, appearance: .light))
        #expect(unread.difference(to: read) > 0.001)
    }
}

/// Was VoiceOver im Menü liest: Änderung mit Titel als Beschriftung und „ungelesen, Zeit, Satz“ als Wert, Hinweis mit
/// Art und Text samt seinen Sprüngen als Links, Panels mit Titel, die Befehle als Knöpfe.
@MainActor
@Suite(.serialized) struct MenuBarMenuAccessibilityTests {
    @Test func changeReadsTitleAndUnreadTimeAndDetail() async throws {
        let nodes = try await AccessibilityTree.nodes(of: ChangeLine(
            symbol: "plus", title: "Neuer LaunchAgent", detail: "com.example.updater startet ein Skript.",
            time: "vor 5 Minuten", isUnread: true))
        #expect(nodes == [AccessibilityTree.Node(role: "AXStaticText", label: "Neuer LaunchAgent",
                                                 value: "ungelesen, vor 5 Minuten, com.example.updater startet ein Skript.")],
                "\(nodes)")
    }

    @Test func readChangeLeavesOutUnread() async throws {
        let nodes = try await AccessibilityTree.nodes(of: ChangeLine(
            symbol: "minus", title: "Autostart entfernt", detail: "com.example.scanner.agent", time: "gestern",
            isUnread: false))
        #expect(nodes.first?.value == "gestern, com.example.scanner.agent", "\(nodes)")
    }

    @Test func noteKeepsItsLinksAsButtons() async throws {
        let nodes = try await AccessibilityTree.nodes(of: LinkedNote("Sicherheit: SIP kritisch", kind: .critical) {
            Button("Sicherheit anzeigen …") {}
        })
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Fehler",
                                                      value: "Sicherheit: SIP kritisch")), "\(nodes)")
        #expect(nodes.contains { $0.role == "AXLink" && $0.label == "Sicherheit anzeigen …" }, "\(nodes)")
    }

    @Test func commandsAreButtons() async throws {
        let nodes = try await AccessibilityTree.nodes(of: MenuBarCommandBar(
            isScanning: true, hasReleaseHighlights: true, showMainWindow: {}, scan: {}, settings: {}, whatsNew: {},
            quit: {}), size: CGSize(width: MenuBarMenuLayout.width, height: 200))
        for title in ["Hauptfenster öffnen", "Jetzt scannen", "Einstellungen …", "Was ist neu?", "Beenden"] {
            #expect(nodes.contains { $0.role == "AXButton" && $0.label == title }, "\(title): \(nodes)")
        }
    }
}
