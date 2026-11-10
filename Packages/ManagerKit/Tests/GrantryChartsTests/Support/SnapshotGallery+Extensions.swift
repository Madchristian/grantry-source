import SwiftUI
@testable import GrantryCharts

/// Bereich „Erweiterungen“ im Lagebild mit festen Beispieldaten (TM-13.5, #391): Zustandszeile und `ExtensionBoard` wie in
/// der App. Erfundene Hersteller und Team-IDs; die Texte folgen der Darstellung in ManagerKit (`ExtensionPresentation`).
/// Sechs Lagen: Befund im Kern gewählt, akzeptierte Netzwerkerweiterung gewählt, Video-Plug-in gewählt (Papierkorb), ohne
/// fremde Erweiterungen (ruhiges Urteil), nichts gewählt und unvollständig geprüft (keine Entwarnung, TM-13.7).
@MainActor
extension SnapshotGallery {
    enum ExtensionScene: String, CaseIterable, Sendable {
        case finding = "befund"
        case accepted = "akzeptiert"
        case plugin = "plugin"
        case calm = "leer"
        case noSelection = "ohne-auswahl"
        case incomplete = "unvollstaendig"
    }

    static let extensionsSize = CGSize(width: 1240, height: 860)

    static func extensions(_ scene: ExtensionScene) -> some View {
        ExtensionBoardSample(scene: scene)
    }

    /// Zeilen der Galerie: je zwei Lagen nebeneinander.
    static let extensionsGalleryRows: [[ExtensionScene]] = [[.finding, .accepted], [.plugin, .calm],
                                                            [.noSelection, .incomplete]]

    /// Alle Lagen im Raster für `docs/design/galerie`.
    static var extensionsGallery: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(extensionsGalleryRows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { scene in
                        extensions(scene).frame(width: extensionsSize.width, height: extensionsSize.height)
                    }
                }
            }
        }
        .padding(16)
    }
}

private enum SampleFilter: Hashable {
    case all, findings, kernel, privileged, drivers, plugins

    static let options: [(value: SampleFilter, label: String)] = [
        (.all, "Alle"), (.findings, "Auffällig"), (.kernel, "Im Kern"), (.privileged, "Sonderrechte"),
        (.drivers, "Treiber"), (.plugins, "Plug-ins"),
    ]
}

private struct ExtensionBoardSample: View {
    let scene: SnapshotGallery.ExtensionScene

    var body: some View {
        let line = ExtensionSamples.statusLine(scene)
        VStack(spacing: 0) {
            StatusLine(verdict: line.verdict, finding: line.finding, items: line.items, facts: line.facts)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            ExtensionBoard(content: ExtensionSamples.content(scene), query: .constant(""),
                           filter: .constant(SampleFilter.all), filters: SampleFilter.options,
                           selection: .constant(ExtensionSamples.selection(scene))) {
                ExtensionSamples.detail(scene)
            } empty: {
                if scene == .incomplete {
                    // Wie `ExtensionsEmptyState` der App: eine leere Liste ist ohne vollständige Prüfung keine Entwarnung.
                    ContentUnavailableView {
                        Label("Nicht vollständig geprüft", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text(verbatim: ExtensionSamples.incompleteNotice)
                    }
                }
            }
        }
        .instrumentBackground()
    }
}

private enum ExtensionSamples {
    static let active = StatusItem("aktiv", tone: .positive)
    static let installed = StatusItem("installiert", tone: .neutral)
    static let notice = StatusItem("Hinweis", tone: .info)
    static let finding = StatusItem("auffällig", tone: .finding)
    static let accepted = StatusItem("akzeptiert", tone: .neutral)

    static let storageBridge = ExtensionRowContent(
        id: "kernel|com.brightline.storagebridge", symbol: "cpu", title: "StorageBridge", kind: "Kernel-Erweiterung",
        vendor: "Brightline Labs", vendorDetail: "BRT4L8QX2M", version: "3.4.1",
        state: StatusItem("geladen", tone: .positive), rating: finding, radarLabel: "StorageBridge")
    static let filterwerk = ExtensionRowContent(
        id: "system|N7DL2KX9QA|de.nordlicht.filterwerk", symbol: "network", title: "Filterwerk",
        kind: "Netzwerkerweiterung", vendor: "Nordlicht Software", vendorDetail: "N7DL2KX9QA", version: "5.8",
        state: active, rating: notice, radarLabel: "Filterwerk")
    static let wachposten = ExtensionRowContent(
        id: "system|N7DL2KX9QA|de.nordlicht.wachposten", symbol: "eye", title: "Wachposten", kind: "Endpoint Security",
        vendor: "Nordlicht Software", vendorDetail: "N7DL2KX9QA", version: "2.1.3", state: active, rating: notice,
        radarLabel: "Wachposten")
    static let fernweg = ExtensionRowContent(
        id: "system|F3RW9G2B7C|se.fernweg.tunnel", symbol: "network", title: "Fernweg VPN", kind: "Netzwerkerweiterung",
        vendor: "Fernweg AB", vendorDetail: "F3RW9G2B7C", version: "1.12", state: active, rating: accepted,
        radarLabel: "Fernweg")
    static let studiokamera = ExtensionRowContent(
        id: "system|H4FB1D8K3Z|de.hafenbild.kamera", symbol: "video", title: "Studiokamera", kind: "Kameraerweiterung",
        vendor: "Hafenbild", vendorDetail: "H4FB1D8K3Z", version: "2.0",
        state: StatusItem("wartet auf Freigabe", tone: .info), rating: nil, radarLabel: "Studiokamera")
    static let dockhub = ExtensionRowContent(
        id: "system|BRT4L8QX2M|com.brightline.dockhub", symbol: "cable.connector", title: "Dockhub", kind: "Treiber",
        vendor: "Brightline Labs", vendorDetail: "BRT4L8QX2M", version: "1.6.2", state: active, rating: nil,
        radarLabel: "Dockhub")
    static let klangweiche = ExtensionRowContent(
        id: "plugin|/Library/Audio/Plug-Ins/HAL/Klangweiche.driver", symbol: "speaker.wave.2", title: "Klangweiche",
        kind: "Audio-Plug-in", vendor: "Klangwerk Audio", vendorDetail: "K9W3A7U2DL", version: "4.2.0",
        state: installed, rating: nil, radarLabel: "Klangweiche")
    static let bildbruecke = ExtensionRowContent(
        id: "plugin|/Library/CoreMediaIO/Plug-Ins/DAL/Bildbruecke.plugin", symbol: "web.camera", title: "Bildbrücke",
        kind: "Video-Plug-in (DAL)", vendor: "Hafenbild", vendorDetail: "H4FB1D8K3Z", version: "1.3",
        state: installed, rating: notice, radarLabel: "Bildbrücke")

    static let incompleteNotice = "Teilweise geprüft: Systemerweiterungen nicht lesbar (systemextensionsctl fehlt)"

    static func layers(calm: Bool) -> [ExtensionLayerContent] {
        [
            ExtensionLayerContent(
                id: "kernel", title: "Im Kern", ringTitle: "im Kern",
                explanation: "Kernel-Erweiterungen: voller Zugriff auf Speicher, Geräte und alle Prozesse.",
                rows: calm ? [] : [storageBridge]),
            ExtensionLayerContent(
                id: "systemExtension", title: "Systemerweiterung mit Sonderrechten", ringTitle: "Sonderrechte",
                explanation: "Netzwerk, Endpoint Security und Kamera: außerhalb des Kerns, mit Blick auf alle Apps.",
                rows: calm ? [] : [filterwerk, wachposten, fernweg, studiokamera]),
            ExtensionLayerContent(
                id: "driver", title: "Treiber", ringTitle: "Treiber",
                explanation: "DriverKit-Treiber sprechen direkt mit einem Gerät.", rows: calm ? [] : [dockhub]),
            ExtensionLayerContent(
                id: "servicePlugin", title: "Plug-in in einem Systemdienst", ringTitle: "Plug-ins",
                explanation: "Audio- und Video-Plug-ins, die ein Dienst von macOS lädt.",
                rows: calm ? [] : [klangweiche, bildbruecke], note: "3 Plug-ins von Apple ausgeblendet"),
        ]
    }

    static func content(_ scene: SnapshotGallery.ExtensionScene) -> ExtensionBoardContent {
        let calm = scene == .calm
        let empty = calm || scene == .incomplete
        let layers = layers(calm: empty)
        return ExtensionBoardContent(
            layers: layers, sections: layers.filter { !$0.rows.isEmpty }, radarValue: empty ? "0" : "8",
            shownText: empty ? "0 von 0" : "8 von 8", notice: scene == .incomplete ? incompleteNotice : nil,
            calm: calm ? ExtensionCalmContent(
                title: "Kein fremder Code mit Sonderrechten",
                reason: "Grantry hat keine Kernel-Erweiterung, keine Systemerweiterung, keinen Treiber und kein Plug-in "
                    + "anderer Hersteller gefunden.",
                checks: ["Kernel-Erweiterungen: keine geladen, keine installiert",
                         "Systemerweiterungen: keine aktiv, keine wartet auf Freigabe",
                         "Treiber: keine",
                         "Audio- und Video-Plug-ins: nur von Apple"],
                note: "Erweiterungen und Plug-ins von Apple gehören zu macOS; Grantry blendet sie aus.") : nil)
    }

    static func statusLine(_ scene: SnapshotGallery.ExtensionScene)
        -> (verdict: String, finding: Bool, items: [StatusItem], facts: String) {
        let facts = "3 Plug-ins von Apple ausgeblendet · geprüft vor 2 min"
        switch scene {
        case .calm: return ("Keine fremden Erweiterungen", false, [StatusItem("Kern frei", tone: .positive)], facts)
        case .incomplete: return ("Nicht vollständig geprüft", false, [], "geprüft vor 2 min")
        default: break
        }
        return ("8 Erweiterungen, 1 auffällig", true,
                [StatusItem("1 im Kern", tone: .finding), StatusItem("1 wartet auf Freigabe", tone: .info),
                 StatusItem("1 akzeptiert", tone: .neutral)], facts)
    }

    static func selection(_ scene: SnapshotGallery.ExtensionScene) -> String? {
        switch scene {
        case .finding: storageBridge.id
        case .accepted: fernweg.id
        case .plugin: bildbruecke.id
        case .calm, .noSelection, .incomplete: nil
        }
    }

    @ViewBuilder
    static func detail(_ scene: SnapshotGallery.ExtensionScene) -> some View {
        switch scene {
        case .finding:
            ExtensionDetailPanel(content: kernelDetail) {
                Button("Risiko akzeptieren") {}
            } actions: {
                Button("In den Systemeinstellungen öffnen") {}
                Button("Zugehörige App zeigen") {}
                Button("Im Finder zeigen") {}
            }
        case .accepted:
            ExtensionDetailPanel(content: acceptedDetail) {
                Button("Akzeptanz aufheben") {}
            } actions: {
                Button("In den Systemeinstellungen öffnen") {}
            }
        case .plugin:
            ExtensionDetailPanel(content: pluginDetail) {
                EmptyView()
            } actions: {
                Button("Zugehörige App zeigen") {}
                Button("Im Finder zeigen") {}
                Button("In den Papierkorb …") {}
            }
        case .calm, .noSelection, .incomplete:
            ExtensionNoSelection()
        }
    }

    static let kernelDetail = ExtensionDetailContent(
        id: storageBridge.id, symbol: "cpu", title: "StorageBridge",
        subtitle: "Kernel-Erweiterung · gehört zu Brightline Storage", state: storageBridge.state, rating: finding,
        permission: "Läuft im Kern von macOS mit uneingeschränktem Zugriff auf Speicher, Geräte und alle Prozesse; ein "
            + "Fehler kann den ganzen Mac abstürzen lassen.",
        findings: [StatusItem("StorageBridge läuft im Kern – auf Apple Silicon nur mit reduzierter Sicherheit.",
                              tone: .finding)],
        acceptance: "Vertraust du ihr, blendet „Risiko akzeptieren“ den Befund aus; bei einem anderen Team warnt "
            + "Grantry erneut.",
        facts: [
            .init(title: "Hersteller", value: "Brightline Labs"),
            .init(title: "Team-ID", value: "BRT4L8QX2M", isCode: true),
            .init(title: "Bundle-ID", value: "com.brightline.storagebridge", isCode: true),
            .init(title: "Version", value: "3.4.1 (341)"),
            .init(title: "Signatur", value: "Developer ID, notarisiert"),
            .init(title: "Zugehörige App", value: "Brightline Storage"),
            .init(title: "Erstmals gesehen", value: "3. Nov. 2026"),
            .init(title: "Pfad", value: "/Library/Extensions/StorageBridge.kext", isCode: true),
        ])

    static let acceptedDetail = ExtensionDetailContent(
        id: fernweg.id, symbol: "network", title: "Fernweg VPN", subtitle: "Netzwerkerweiterung · Systemerweiterung",
        state: active, rating: accepted,
        permission: "Darf Netzwerkverkehr filtern, umleiten oder als VPN tunneln und kann dabei die Verbindungen aller "
            + "Apps sehen.",
        findings: [StatusItem("Fernweg VPN (Netzwerkerweiterung) kann den Netzwerkverkehr sehen – die zugehörige App "
                              + "fehlt.", tone: .neutral)],
        acceptance: "Akzeptiert: Der Befund fehlt in Zustandszeile und Wachbuch; bei einem anderen Team warnt Grantry "
            + "erneut.",
        facts: [
            .init(title: "Hersteller", value: "Fernweg AB"),
            .init(title: "Team-ID", value: "F3RW9G2B7C", isCode: true),
            .init(title: "Bundle-ID", value: "se.fernweg.tunnel", isCode: true),
            .init(title: "Version", value: "1.12 (412)"),
            .init(title: "Signatur", value: "prüft macOS bei der Aktivierung"),
            .init(title: "Zugehörige App", value: "fehlt"),
            .init(title: "Erstmals gesehen", value: "12. Okt. 2026"),
        ])

    static let pluginDetail = ExtensionDetailContent(
        id: bildbruecke.id, symbol: "web.camera", title: "Bildbrücke", subtitle: "Video-Plug-in (DAL) · gehört zu Hafenbild Studio",
        state: installed, rating: notice,
        permission: "Wird von jeder App mit Kamerazugriff geladen und läuft dort mit deren Rechten; veraltete Technik "
            + "(DAL).",
        findings: [StatusItem("Bildbrücke ist ein Video-Plug-in in veralteter Technik (DAL).", tone: .info)],
        acceptance: nil,
        facts: [
            .init(title: "Hersteller", value: "Hafenbild"),
            .init(title: "Team-ID", value: "H4FB1D8K3Z", isCode: true),
            .init(title: "Bundle-ID", value: "de.hafenbild.dal", isCode: true),
            .init(title: "Version", value: "1.3"),
            .init(title: "Signatur", value: "Developer ID, notarisiert"),
            .init(title: "Zugehörige App", value: "Hafenbild Studio"),
            .init(title: "Erstmals gesehen", value: "28. Sep. 2026"),
            .init(title: "Pfad", value: "/Library/CoreMediaIO/Plug-Ins/DAL/Bildbruecke.plugin", isCode: true),
        ])
}
