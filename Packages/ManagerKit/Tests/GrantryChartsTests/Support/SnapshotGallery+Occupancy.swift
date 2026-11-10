import SwiftUI
@testable import GrantryCharts

/// Ansicht „Belegung“ (TM-15.4, #403) mit festen Beispieldaten in vier Lagen: vor dem Scan, während, fertig und mit nicht
/// erfassten Orten (ohne Festplattenvollzugriff). Dazu zwei Sonderzustände (TM-15.6, #405): Scan gescheitert bei
/// unvollständig gelesenen Datenträgern, und der ganze Datenträger mit ausgelassenem Volume und Netzlaufwerk, SMART-Fehler
/// und nichts gewählt. Texte wie aus `OccupancyPresentation` (ManagerKit).
@MainActor
extension SnapshotGallery {
    enum OccupancyScene: String, CaseIterable, Sendable {
        case idle = "vorher"
        case scanning = "scan"
        case done = "fertig"
        case uncaptured = "nicht-erfasst"
        case failed = "gescheitert"
        case volume = "ganzer-datentraeger"
    }

    static let occupancySize = CGSize(width: 900, height: 700)

    static func occupancy(_ scene: OccupancyScene) -> some View {
        OccupancyBoard(content: OccupancySample.content(scene), scope: .constant(scene == .volume ? .volume : .home),
                       actions: .none)
    }

    /// Die ersten vier Lagen im Raster für die Galerie (`docs/design/galerie/belegung-*.jpg`).
    static var occupancyGallery: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                occupancy(.idle).frame(width: occupancySize.width, height: occupancySize.height)
                occupancy(.scanning).frame(width: occupancySize.width, height: occupancySize.height)
            }
            GridRow {
                occupancy(.done).frame(width: occupancySize.width, height: occupancySize.height)
                occupancy(.uncaptured).frame(width: occupancySize.width, height: occupancySize.height)
            }
        }
        .padding(16)
    }
}

private enum OccupancySample {
    typealias Scene = SnapshotGallery.OccupancyScene

    static func content(_ scene: Scene) -> OccupancyBoardContent {
        OccupancyBoardContent(
            verdict: scene == .volume ? "68 GB frei von 994 GB" : "248 GB frei von 994 GB", finding: false,
            items: items(scene), facts: facts(scene),
            volumes: volumes(scene), devices: devices(scene), ladder: ladder(scene), detail: detail(scene),
            bar: bar(scene))
    }

    static func facts(_ scene: Scene) -> String {
        switch scene {
        case .idle, .scanning, .failed: "macOS kann 31 GB zusätzlich freigeben"
        case .done, .uncaptured: "macOS kann 31 GB zusätzlich freigeben · gescannt 10:41"
        case .volume: "macOS kann 12 GB zusätzlich freigeben · gescannt 10:52"
        }
    }

    static func items(_ scene: Scene) -> [StatusItem] {
        switch scene {
        case .idle: [StatusItem("Noch nicht gescannt", tone: .neutral)]
        case .scanning: [StatusItem("Scan läuft", tone: .info)]
        case .done: [StatusItem("51 GB über Speicher aufräumbar", tone: .info)]
        case .uncaptured: [StatusItem("44 GB über Speicher aufräumbar", tone: .info),
                           StatusItem("11 Orte nicht erfasst", tone: .neutral)]
        case .failed: [StatusItem("Scan gescheitert", tone: .neutral)]
        case .volume: [StatusItem("38 GB über Speicher aufräumbar", tone: .info),
                       StatusItem("3 Orte nicht erfasst", tone: .neutral)]
        }
    }

    static func part(_ id: String, _ title: String, _ gigabytes: Int, of total: Int = 994, level: Int)
        -> ShareBand.Part {
        ShareBand.Part(id: id, title: title, value: "\(gigabytes) GB", fraction: Double(gigabytes) / Double(total),
                       level: level)
    }

    static func volumes(_ scene: Scene) -> [OccupancyVolumeContent] {
        let parts: [ShareBand.Part] = switch scene {
        case .idle, .scanning, .failed:
            [part("system", "System", 27, level: 0), part("data", "Daten, nicht aufgeteilt", 688, level: 1),
             part("purgeable", "bereinigbar", 31, level: 4)]
        case .volume:
            [part("system", "System", 186, level: 0), part("apps", "Apps", 142, level: 1),
             part("users", "Benutzer (erfasst)", 548, level: 2), part("cleanable", "über Speicher aufräumbar", 38, level: 3),
             part("purgeable", "bereinigbar", 12, level: 4)]
        case .done:
            [part("rest", "System und weitere", 324, level: 0), part("home", "Benutzerordner", 340, level: 2),
             part("cleanable", "über Speicher aufräumbar", 51, level: 3), part("purgeable", "bereinigbar", 31, level: 4)]
        case .uncaptured:
            [part("rest", "System und weitere", 392, level: 0), part("home", "Benutzerordner (erfasst)", 279, level: 2),
             part("cleanable", "über Speicher aufräumbar", 44, level: 3), part("purgeable", "bereinigbar", 31, level: 4)]
        }
        let full = scene == .volume
        let startup = OccupancyVolumeContent(
            id: "disk3", title: "Macintosh HD", detail: "APFS · intern · verschlüsselt", value: full ? "93 % belegt" : "75 % belegt",
            fraction: full ? 0.93 : 0.75, parts: parts, free: ("frei", full ? "68 GB" : "248 GB"))
        guard scene == .done else { return [startup] }
        let archive = OccupancyVolumeContent(
            id: "disk5", title: "Archiv", detail: "APFS · USB · nicht verschlüsselt", value: "45 % belegt", fraction: 0.45,
            parts: [part("data", "Daten, nicht aufgeteilt", 902, of: 2_000, level: 1)], free: ("frei", "1,1 TB"))
        return [startup, archive]
    }

    static func devices(_ scene: Scene) -> OccupancyDevicesContent {
        let builtIn = OccupancyDevicesContent.Device(
            id: "disk0", symbol: "internaldrive", title: "APPLE SSD AP1024Z", detail: "Apple Fabric · SSD · 1 TB",
            smart: scene == .volume ? StatusItem("SMART Fehler", tone: .critical) : StatusItem("SMART verifiziert", tone: .positive),
            facts: [PanelFact("Container", "disk3, 6 Volumes"),
                    PanelFact("Lokale Snapshots", scene == .volume ? "5, ältester 12.10." : "3, ältester 06.11.")])
        if scene == .failed {
            return OccupancyDevicesContent(detail: "1 intern", devices: [builtIn],
                                           note: "Einige Angaben fehlen – eine Abfrage scheiterte oder dauerte zu lange.")
        }
        guard scene == .done else { return OccupancyDevicesContent(detail: "1 intern", devices: [builtIn]) }
        let external = OccupancyDevicesContent.Device(
            id: "disk4", symbol: "externaldrive", title: "Samsung PSSD T7", detail: "USB · SSD · 2 TB",
            smart: StatusItem("SMART nicht unterstützt", tone: .neutral), facts: [PanelFact("Container", "disk5, 1 Volume")])
        return OccupancyDevicesContent(detail: "1 intern · 1 extern", devices: [builtIn, external])
    }

    static func row(_ id: Int, _ name: String, _ value: String, _ fraction: Double?, chip: StatusItem? = nil,
                    symbol: String = "folder", descendable: Bool = true, muted: Bool = false) -> LadderRow.Content {
        LadderRow.Content(id: id, symbol: symbol, name: name, value: value, fraction: fraction, chip: chip,
                          isDescendable: descendable, isMuted: muted,
                          accessibilityLabel: [name, value, chip?.text].compactMap(\.self).joined(separator: ", "))
    }

    static func ladder(_ scene: Scene) -> OccupancyLadderContent {
        switch scene {
        case .idle:
            OccupancyLadderContent(
                detail: "Benutzerordner", value: "", steps: [], notes: [], offersFullDiskAccess: false,
                state: .placeholder(title: "Noch nicht gescannt", description: """
                    Grantry liest auf Abruf, wie viel Platz deine Ordner belegen – nur lesend. Aufgeräumt wird über \
                    Speicher, nach deiner Bestätigung.
                    """, symbol: "folder.badge.questionmark"))
        case .scanning:
            OccupancyLadderContent(
                detail: "Benutzerordner · Scan läuft", value: "", steps: [], notes: [], offersFullDiskAccess: false,
                state: .placeholder(title: "Scan läuft", description: """
                    182 340 Dateien in 21 870 Ordnern, 96,4 GB gelesen. Gedrosselt, damit der Mac flüssig bleibt.
                    """, symbol: "hourglass"))
        case .done:
            OccupancyLadderContent(
                detail: "Benutzerordner · 1,24 Mio. Dateien · 412 330 Ordner", value: "391 GB",
                steps: [PathSteps.Step(id: 0, title: "Benutzerordner"), PathSteps.Step(id: 1, title: "Library"),
                        PathSteps.Step(id: 2, title: "Caches")],
                notes: [], offersFullDiskAccess: false,
                state: .rows([
                    row(1, "Homebrew", "6,2 GB", 0.34, chip: StatusItem("Homebrew aufräumen", tone: .info)),
                    row(2, "com.spotify.client", "3,1 GB", 0.17),
                    row(3, "pip", "2,4 GB", 0.13),
                    row(4, "com.apple.Safari", "1,9 GB", 0.10),
                    row(5, "llama.cpp", "1,6 GB", 0.09, chip: StatusItem("LLM-Modelle", tone: .neutral)),
                    row(6, "Google", "1,2 GB", 0.07, chip: StatusItem("bleibt", tone: .neutral)),
                    row(7, "CloudKit", "0,9 GB", 0.05, chip: StatusItem("bleibt", tone: .neutral)),
                    row(8, "com.microsoft.VSCode.ShipIt", "0,6 GB", 0.03),
                    row(9, "Dateien direkt in Caches", "0,1 GB", 0.01, symbol: "doc", descendable: false),
                ], selection: nil))
        case .uncaptured:
            OccupancyLadderContent(
                detail: "Benutzerordner · 1,02 Mio. Dateien · 11 Orte nicht erfasst", value: "≥ 323 GB",
                steps: [PathSteps.Step(id: 0, title: "Benutzerordner")],
                notes: ["""
                    Ohne Festplattenvollzugriff liest Grantry 11 geschützte Orte nicht (Schreibtisch, Dokumente, \
                    Downloads, iCloud Drive …), damit macOS nicht nachfragt. Größen darüber sind Untergrenzen.
                    """],
                offersFullDiskAccess: true,
                state: .rows([
                    row(1, "Library", "≥ 196 GB", 0.61, chip: StatusItem("teils nicht erfasst", tone: .neutral)),
                    row(2, "Developer", "88,1 GB", 0.27),
                    row(3, "Movies", "21,0 GB", 0.07),
                    row(4, "Music", "12,3 GB", 0.04),
                    row(5, "Pictures", "≥ 2,2 GB", 0.01, chip: StatusItem("teils nicht erfasst", tone: .neutral)),
                    row(6, ".Trash", "2,1 GB", 0.01, chip: StatusItem("Papierkorb", tone: .neutral)),
                    row(7, "Desktop", "–", nil, chip: StatusItem("nicht erfasst", tone: .neutral), descendable: false,
                        muted: true),
                    row(8, "Documents", "–", nil, chip: StatusItem("nicht erfasst", tone: .neutral), descendable: false,
                        muted: true),
                    row(9, "Downloads", "–", nil, chip: StatusItem("nicht erfasst", tone: .neutral), descendable: false,
                        muted: true),
                    row(10, "Dateien direkt im Benutzerordner", "0,4 GB", 0.001, symbol: "doc", descendable: false),
                ], selection: 8))
        case .failed:
            OccupancyLadderContent(
                detail: "Benutzerordner", value: "", steps: [], notes: [], offersFullDiskAccess: false,
                state: .placeholder(title: "Scan nicht möglich", description: "Der Ordner ist nicht verfügbar.",
                                    symbol: "exclamationmark.triangle"))
        case .volume:
            OccupancyLadderContent(
                detail: "Ganzer Datenträger · 2,1 Mio. Dateien · 3 Orte nicht erfasst", value: "≥ 690 GB",
                steps: [PathSteps.Step(id: 0, title: "Macintosh HD")],
                notes: ["Netzlaufwerke liest Grantry nicht; sie bleiben ausgelassen."], offersFullDiskAccess: false,
                state: .rows([
                    row(1, "Users", "≥ 548 GB", 0.79, chip: StatusItem("teils nicht erfasst", tone: .neutral)),
                    row(2, "Applications", "96,4 GB", 0.14),
                    row(3, "Library", "31,2 GB", 0.05),
                    row(4, "opt", "11,8 GB", 0.02),
                    row(5, "private", "≥ 2,6 GB", 0.004, chip: StatusItem("teils nicht erfasst", tone: .neutral)),
                    row(6, "Archiv", "–", nil, chip: StatusItem("anderes Volume", tone: .neutral), symbol: "externaldrive",
                        descendable: false, muted: true),
                    row(7, "Team", "–", nil, chip: StatusItem("Netzlaufwerk, ausgelassen", tone: .neutral),
                        symbol: "network", descendable: false, muted: true),
                ], selection: nil))
        }
    }

    static func detail(_ scene: Scene) -> OccupancyDetailContent? {
        switch scene {
        case .idle, .scanning, .failed: nil
        case .volume:
            OccupancyDetailContent(
                title: "Macintosh HD", detail: "Ordner · teils nicht erfasst", value: "≥ 690 GB", path: "/",
                fields: [("Dateien", "2 104 331"), ("Unterordner", "598 112"), ("Letzte Änderung", "heute 10:51"),
                         ("davon aufräumbar", "38,0 GB")],
                hints: [
                    .init(title: "Erfassung", status: StatusItem("teils nicht erfasst", tone: .neutral),
                          text: "Ohne Festplattenvollzugriff liest Grantry 3 geschützte Orte darunter nicht."),
                ],
                largestFiles: [], canShowInFinder: true, cleanupTitle: nil)
        case .done:
            OccupancyDetailContent(
                title: "Caches", detail: "Ordner · 4 % des Benutzerordners", value: "18,4 GB", path: "~/Library/Caches",
                fields: [("Dateien", "214 806"), ("Unterordner", "9 412"), ("Letzte Änderung", "heute 10:38"),
                         ("davon aufräumbar", "15,7 GB")],
                hints: [
                    .init(title: "Kategorie", status: StatusItem("Caches", tone: .info),
                          text: "Risiko gering – Apps bauen ihre Zwischenspeicher neu auf. Einige Ordner bleiben (Google, CloudKit)."),
                    .init(title: "Time Machine", status: StatusItem("wird gesichert", tone: .neutral),
                          text: "Vorschlag: aus Time Machine ausnehmen, der Inhalt entsteht von selbst neu."),
                ],
                largestFiles: [], canShowInFinder: true, cleanupTitle: "In Speicher aufräumen")
        case .uncaptured:
            OccupancyDetailContent(
                title: "Documents", detail: "Ordner · nicht erfasst", value: "–", path: "~/Documents",
                fields: [("Dateien", "–"), ("Unterordner", "–"), ("Letzte Änderung", "–")],
                hints: [
                    .init(title: "Erfassung", status: StatusItem("nicht erfasst", tone: .neutral),
                          text: "Ohne Festplattenvollzugriff liest Grantry diesen Ort nicht, damit macOS nicht nachfragt."),
                ],
                largestFiles: [], canShowInFinder: true, cleanupTitle: nil)
        }
    }

    static func bar(_ scene: Scene) -> OccupancyBarContent {
        switch scene {
        case .idle:
            OccupancyBarContent(status: "Nur lesend, gedrosselt", isScanning: false, scanTitle: "Scannen", canScan: true)
        case .scanning:
            OccupancyBarContent(status: "182 340 Dateien · 96,4 GB gelesen", isScanning: true, scanTitle: "Scannen",
                                canScan: false)
        case .done, .uncaptured:
            OccupancyBarContent(status: "Gescannt heute 10:41 in 58 s", isScanning: false, scanTitle: "Erneut scannen",
                                canScan: true)
        case .failed:
            OccupancyBarContent(status: "Der Ordner ist nicht verfügbar.", isScanning: false, scanTitle: "Scannen",
                                canScan: true)
        case .volume:
            OccupancyBarContent(status: "Gescannt heute 10:52 in 3 min 12 s", isScanning: false,
                                scanTitle: "Erneut scannen", canScan: true)
        }
    }
}
