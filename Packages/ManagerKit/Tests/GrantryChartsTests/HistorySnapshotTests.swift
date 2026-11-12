import SwiftUI
import Testing
@testable import GrantryCharts

/// Verlauf im Lagebild (LB-3.3, #545) in hell, dunkel und „Kontrast erhöhen“: ungelesene Änderungen mit
/// „Wiederherstellbar“ und angesprungenem Eintrag, Wiederherstellen läuft, aktiver Filter, nicht lesbar, keine
/// Änderungen bei fehlender Quelle. Native Knöpfe zeichnet `ImageRenderer` nicht; Knöpfe zeigt die Galerie (offscreen).
@MainActor
@Suite struct HistorySnapshotTests {
    @Test(arguments: SnapshotGallery.HistoryScene.allCases, ChartAppearance.allCases)
    func history(_ scene: SnapshotGallery.HistoryScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.history(scene), named: "verlauf-\(scene.rawValue)",
                                 size: SnapshotGallery.historySize, appearance: appearance)
    }

    @Test func increasedContrastChangesTheDrawing() throws {
        let size = SnapshotGallery.historySize
        let light = try #require(ChartImage(SnapshotGallery.history(.unread), size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.history(.unread), size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }
}

/// Was VoiceOver im Verlauf liest: je Zeile Name als Beschriftung und Zustand, Detail und Zeit als Wert (#563), die
/// Knöpfe eigen; die Filterzeile mit „Filter“ und der Auswahl.
@MainActor
@Suite(.serialized) struct HistoryAccessibilityTests {
    @Test func rowReadsNameWithStateAndTimeAndKeepsItsButton() async throws {
        let entry = HistoryEntry(id: "1", content: InstrumentRowContent(symbol: "minus", title: "com.example.agent",
                                                                        detail: "Autostart · LaunchAgent",
                                                                        status: StatusItem("entfernt", tone: .neutral)),
                                 time: "11:02", isUnread: true,
                                 restore: .available(help: "Gesicherte Plist zurücklegen", isEnabled: true))
        let nodes = try await AccessibilityTree.nodes(of: HistoryRow(entry, isFocused: false) {} copy: { _ in })
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "com.example.agent",
                                                      value: "ungelesen, entfernt. Autostart · LaunchAgent, 11:02")),
                "\(nodes)")
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Wiederherstellen …" }, "\(nodes)")
    }

    @Test func runningRestoreIsSpoken() async throws {
        let entry = HistoryEntry(id: "1", content: InstrumentRowContent(symbol: "archivebox", title: "com.example.agent",
                                                                        detail: "Autostart entfernt · Benutzer"),
                                 time: "vor 3 Tagen", restore: .running)
        let nodes = try await AccessibilityTree.nodes(of: HistoryRow(entry, isFocused: false) {} copy: { _ in })
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "läuft",
                                                      value: "Wird wiederhergestellt …")), "\(nodes)")
    }

    @Test func activeFilterReadsSelectionAndReset() async throws {
        let nodes = try await AccessibilityTree.nodes(of: ActiveFilterLine("Autostart · Letzte 7 Tage") {})
        #expect(nodes == [AccessibilityTree.Node(role: "AXStaticText", label: "Filter", value: "Autostart · Letzte 7 Tage"),
                          AccessibilityTree.Node(role: "AXLink", label: "Filter zurücksetzen", value: "")],
                "\(nodes)")
    }
}

/// Kontrast im Verlauf (Standard § 4): sekundärer Text auf den Flächen, die nur hier zusammenkommen – ungelesene Zeile
/// (leichter Grund im Panel) und Befehl auf der Mulde in der angesprungenen Zeile – ≥ 4,5 : 1.
@Suite struct HistoryContrastTests {
    @Test(arguments: [false, true])
    func secondaryTextOnUnreadRowAndWellInFocusedRow(dark: Bool) {
        let ink = dark ? Contrast.white : Contrast.black
        let panel = dark ? InstrumentSurface.panelDark : InstrumentSurface.panelLight
        let grounds = [Contrast.mix(ink, opacity: InstrumentOpacity.subtle, over: panel),
                       Contrast.mix(ink, opacity: InstrumentOpacity.well,
                                    over: InstrumentSurface.selectionRGB(dark: dark))]
        for ground in grounds {
            let text = Contrast.mix(ink, opacity: InstrumentOpacity.secondaryText, over: ground)
            #expect(Contrast.ratio(text, ground) >= 4.5, "\(dark ? "dunkel" : "hell"): \(Contrast.ratio(text, ground))")
        }
    }
}
