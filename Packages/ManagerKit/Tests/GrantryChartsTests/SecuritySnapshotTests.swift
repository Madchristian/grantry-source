import AppKit
import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich „Sicherheit“ im Lagebild (TM-16.2, #407; TM-16.3, #408; TM-16.5, #410): Lagezeile, Steckbrief mit
/// Sprungzeilen und Panel „Schutz“ in hell, dunkel und „Kontrast erhöhen“ für alles in Ordnung, einen offenen Punkt,
/// kritisch, ohne Helper und einen leeren Steckbrief.
/// Referenzen unter `__Snapshots__`; die Seriennummer ist darin immer verdeckt.
@MainActor
@Suite struct SecuritySnapshotTests {
    @Test(arguments: SnapshotGallery.SecurityScene.allCases, ChartAppearance.allCases)
    func security(_ scene: SnapshotGallery.SecurityScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.security(scene), named: "security-\(scene.rawValue)",
                                 size: SnapshotGallery.securitySize, appearance: appearance)
    }

    /// VoiceOver liest die Zeile als einen Knopf: Name, Zustand, Grund.
    @Test func checkRowReadsNameStateAndReason() {
        let item = CheckItem(id: "firewall", symbol: "firewall", title: "Firewall",
                             reason: "Die Firewall ist ausgeschaltet.", status: StatusItem("Kritisch", tone: .critical))
        #expect(item.accessibilityLabel == "Firewall: Kritisch. Die Firewall ist ausgeschaltet.")
    }

    /// VoiceOver liest die Sprungzeile als einen Knopf: Titel, Zustand, Satz; ohne Zustand Titel und Satz.
    @Test func linkRowReadsTitleStateAndSummary() {
        let storage = MacLinkContent(id: "storage", symbol: "internaldrive", title: "Datenträger",
                                     summary: "248 GB frei von 1 TB", status: StatusItem("SMART Fehler", tone: .critical))
        #expect(storage.accessibilityLabel == "Datenträger: SMART Fehler. 248 GB frei von 1 TB")
        let network = MacLinkContent(id: "network", symbol: "network", title: "Netz", summary: "WLAN (en0)")
        #expect(network.accessibilityLabel == "Netz: WLAN (en0)")
    }

    /// Keine Referenz zeigt eine Seriennummer: Jede Lage der Galerie zeichnet das Feld verdeckt.
    @Test func galleryNeverRevealsSerialNumber() {
        #expect(!SnapshotGallery.securitySerial.isRevealed)
        #expect(SnapshotGallery.securitySerial.text.allSatisfy { $0 == "•" })
    }

    /// Galerie für `docs/design/galerie` (`GRANTRY_DESIGN_GALLERY=<Ordner>`): je Erscheinungsbild alle vier Lagen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANTRY_DESIGN_GALLERY"] != nil))
    func gallery() throws {
        let directory = URL(filePath: try #require(ProcessInfo.processInfo.environment["GRANTRY_DESIGN_GALLERY"]))
        let size = SnapshotGallery.securitySize
        let grid = Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach([[SnapshotGallery.SecurityScene.protected, .oneOpen], [.critical, .withoutHelper]], id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { scene in
                        SnapshotGallery.security(scene).frame(width: size.width, height: size.height)
                    }
                }
            }
        }
        for (appearance, name) in [(ChartAppearance.light, "hell"), (.dark, "dunkel"), (.contrast, "kontrast")] {
            let image = try #require(ChartImage(grid, size: CGSize(width: size.width * 2, height: size.height * 2),
                                                appearance: appearance))
            try #require(image.png).write(to: directory.appending(path: "sicherheit-\(name).png"))
        }
    }
}
