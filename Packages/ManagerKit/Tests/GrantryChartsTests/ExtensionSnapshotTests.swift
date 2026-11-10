import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Bereich „Erweiterungen“ (TM-13.5, #391) in hell, dunkel und „Kontrast erhöhen“: Befund im Kern, akzeptierte
/// Erweiterung, Plug-in, ohne fremde Erweiterungen, nichts gewählt und unvollständig geprüft (TM-13.7, #393). Dazu die
/// Beschriftungen für VoiceOver: Radar und Schichten auch als Liste lesbar (Spec 2026-11-08 §4.6). Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`;
/// `GRANTRY_GALLERY_DIR=<Ordner>` schreibt zusätzlich die Galerie (alle Lagen im Raster) für `docs/design/galerie`.
@MainActor
@Suite struct ExtensionSnapshotTests {
    nonisolated static let cases = SnapshotGallery.ExtensionScene.allCases.flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: cases)
    func extensions(_ scene: SnapshotGallery.ExtensionScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.extensions(scene), named: "extensions-\(scene.rawValue)",
                                 size: SnapshotGallery.extensionsSize, appearance: appearance)
    }

    // MARK: VoiceOver

    nonisolated static let kext = ExtensionRowContent(
        id: "kernel|com.brightline.storagebridge", symbol: "cpu", title: "StorageBridge", kind: "Kernel-Erweiterung",
        vendor: "Brightline Labs", vendorDetail: "BRT4L8QX2M", version: "3.4.1",
        state: StatusItem("geladen", tone: .positive), rating: StatusItem("auffällig", tone: .finding),
        radarLabel: "StorageBridge")
    nonisolated static let plugin = ExtensionRowContent(
        id: "plugin|/Library/Audio/Plug-Ins/HAL/Klangweiche.driver", symbol: "speaker.wave.2", title: "Klangweiche",
        kind: "Audio-Plug-in", vendor: "Klangwerk Audio", vendorDetail: "K9W3A7U2DL", version: "4.2.0",
        state: StatusItem("installiert", tone: .neutral), rating: nil, radarLabel: "Klangweiche")
    nonisolated static let layers = [
        ExtensionLayerContent(id: "kernel", title: "Im Kern", ringTitle: "im Kern",
                              explanation: "Voller Zugriff auf Speicher, Geräte und alle Prozesse.", rows: [kext]),
        ExtensionLayerContent(id: "servicePlugin", title: "Plug-in in einem Systemdienst", ringTitle: "Plug-ins",
                              explanation: "Plug-ins, die ein Dienst von macOS lädt.", rows: [plugin, plugin],
                              note: "3 Plug-ins von Apple ausgeblendet"),
    ]

    /// Eine Tabellenzeile ist ein Element: Name, Art, Hersteller, Zustand und Bewertung, nie nur „Taste“.
    @Test func rowReadsNameKindVendorStateAndRating() {
        #expect(Self.kext.accessibilityLabel == "StorageBridge, Kernel-Erweiterung, Brightline Labs, geladen, auffällig")
        #expect(Self.plugin.accessibilityLabel == "Klangweiche, Audio-Plug-in, Klangwerk Audio, installiert")
    }

    /// Die Schichten unter dem Radar als Liste: Name, Zahl, Befunde, Satz und Zusatz.
    @Test func layerListReadsCountFindingsAndExplanation() {
        #expect(ExtensionLayerRow.accessibilityText(Self.layers[0])
            == "Im Kern: 1 Erweiterung, 1 auffällig. Voller Zugriff auf Speicher, Geräte und alle Prozesse.")
        #expect(ExtensionLayerRow.accessibilityText(Self.layers[1])
            == "Plug-in in einem Systemdienst: 2 Erweiterungen. Plug-ins, die ein Dienst von macOS lädt. "
            + "3 Plug-ins von Apple ausgeblendet")
    }

    /// Das Radar liest jede Erweiterung als Eintrag mit Name, Ring und Bewertung; Bernstein nur für Befunde.
    @Test func radarEchoesReadNameRingAndRating() {
        let echoes = ExtensionLayerPanel.echoes(Self.layers)
        #expect(echoes.map(\.accessibilityLabel) == ["StorageBridge, im Kern, auffällig", "Klangweiche, Plug-ins",
                                                     "Klangweiche, Plug-ins"])
        #expect(echoes.map(\.ring) == [0, 1, 1])
        #expect(echoes.map(\.tone) == [.finding, nil, nil])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"] != nil),
          arguments: ChartAppearance.allCases)
    func gallery(_ appearance: ChartAppearance) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"])
        let rows = CGFloat(SnapshotGallery.extensionsGalleryRows.count)
        let size = CGSize(width: SnapshotGallery.extensionsSize.width * 2 + 48,
                          height: SnapshotGallery.extensionsSize.height * rows + 16 * (rows + 1))
        let image = try #require(ChartImage(SnapshotGallery.extensionsGallery, size: size, appearance: appearance))
        let name = ["light": "hell", "dark": "dunkel", "contrast": "kontrast"][appearance.rawValue] ?? appearance.rawValue
        try #require(image.png).write(to: URL(filePath: directory).appending(path: "erweiterungen-\(name).png"))
    }
}
