import SwiftUI
import Testing
@testable import GrantryCharts

/// Einstellungen › Allgemein im Lagebild (LB-5.2, #553) in hell, dunkel und „Kontrast erhöhen“: eingerichtet, offen mit
/// aufgeklappter Zeile, Fehler mit verfügbarem Update, Prüfung läuft. Schalter gezeichnet statt nativ (`chartDrawsSwitches`),
/// damit das Bild nicht von der Bildschirm-Skalierung des Rechners abhängt; die nativen zeigt die Galerie (offscreen).
@MainActor
@Suite struct SettingsSnapshotTests {
    @Test(arguments: SnapshotGallery.SettingsScene.allCases, ChartAppearance.allCases)
    func settings(_ scene: SnapshotGallery.SettingsScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.settings(scene), named: "einstellungen-\(scene.rawValue)",
                                 size: SnapshotGallery.settingsSize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.settingsSize
        let light = try #require(ChartImage(SnapshotGallery.settings(.missing), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.settings(.missing), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver in den Einstellungen liest: Schalter mit dem Titel als Beschriftung und Wert, Knöpfe mit eigener
/// Beschriftung neben lesbarem Titel und Erklärung, Prüfzeilen als Knopf „Name: Zustand. Grund“, laufende Prüfung mit Text.
@MainActor
@Suite(.serialized) struct SettingsAccessibilityTests {
    @Test func toggleReadsTitleAndValueWithoutDuplicateTexts() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SettingsPanel("Wachbuch", detail: "Aufzeichnung an") {
            SettingToggle("Wachbuch führen", note: "Zeichnet alle 10 Sekunden auf.", isOn: .constant(true))
        })
        let toggle = try #require(nodes.first { $0.label == "Wachbuch führen" }, "\(nodes)")
        #expect(toggle.role == "AXCheckBox", "\(nodes)")
        #expect(toggle.value == "1", "\(nodes)")
        #expect(!nodes.contains { $0.role == "AXStaticText" && $0.label.contains("Zeichnet alle") }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Wachbuch" }, "\(nodes)")
    }

    @Test func rowWithOwnButtonKeepsTitleAndNoteReadable() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SettingRow("Drittanbieter-Lizenzen",
                                                                     note: "Lizenztexte anderer Anbieter.",
                                                                     labelsControl: false) {
            Button("Lizenzen anzeigen …") {}
        })
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Lizenzen anzeigen …" }, "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Drittanbieter-Lizenzen",
                                                      value: "Lizenztexte anderer Anbieter.")), "\(nodes)")
    }

    @Test func setupRowsAndRunningCheckAreReadable() async throws {
        let items = SnapshotGallery.setupItems(.failed)
        let nodes = try await AccessibilityTree.nodes(of: VStack {
            CheckRows(items: items, selection: .constant("setup.helper")) { _ in Button("Genehmigen") {} }
            SettingActionLine("Zuletzt geprüft: heute, 09:12", runningText: "Wird geprüft …") {
                Button("Jetzt prüfen") {}
            }
        }, size: CGSize(width: 560, height: 600))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label.hasPrefix("Helper: Wartet auf Genehmigung.") },
                "\(nodes)")
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Genehmigen" }, "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "läuft", value: "Wird geprüft …")),
                "\(nodes)")
    }
}
