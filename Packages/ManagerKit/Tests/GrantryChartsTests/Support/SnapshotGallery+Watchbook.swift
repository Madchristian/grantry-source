import Foundation
import SwiftUI
@testable import GrantryCharts

/// Tab „Wachbuch“ im Lagebild mit festen Beispieldaten (TM-12.5, #383): Zustandszeile und `WatchbookBoard` wie in der
/// App. Erfundene Verläufe ohne Zufall und Uhr; Texte folgen der Darstellung in ManagerKit (`WatchbookPresentation`).
/// Fünf Lagen: eine Stunde mit beendetem Befund und gesetzter Zeitmarke, 24 Stunden mit Ruhezustand in der Nacht und
/// laufendem Befund, 7 Tage mit Aufzeichnung erst seit Montag, „aus“ und „noch keine Aufzeichnung“.
@MainActor
extension SnapshotGallery {
    enum WatchbookScene: String, CaseIterable, Sendable {
        case hour = "stunde"
        case day = "tag"
        case week = "woche"
        case off = "aus"
        case empty = "leer"
    }

    static let watchbookSize = CGSize(width: 1240, height: 800)

    static func watchbook(_ scene: WatchbookScene) -> some View {
        WatchbookBoardSample(scene: scene)
    }

    /// Zeitleiste einer Lage mit Aufzeichnung, etwa für den Render-Wächter.
    static func watchbookTimeline(_ scene: WatchbookScene) -> WatchbookTimelineContent? {
        if case .recorded(let content) = WatchbookSamples.sample(scene).state { content } else { nil }
    }

    /// Panel „Zu diesem Zeitpunkt“ und Tabelle „Befunde“ einer Lage (TM-12.6), etwa für den Render-Wächter.
    static func watchbookAnalysis(_ scene: WatchbookScene) -> WatchbookAnalysis {
        WatchbookSamples.sample(scene).analysis
    }

    /// Alle Lagen im Raster für `docs/design/galerie`.
    static var watchbookGallery: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                watchbook(.hour).frame(width: watchbookSize.width, height: watchbookSize.height)
                watchbook(.day).frame(width: watchbookSize.width, height: watchbookSize.height)
            }
            GridRow {
                watchbook(.week).frame(width: watchbookSize.width, height: watchbookSize.height)
                watchbook(.off).frame(width: watchbookSize.width, height: watchbookSize.height)
            }
            GridRow {
                watchbook(.empty).frame(width: watchbookSize.width, height: watchbookSize.height)
            }
        }
        .padding(16)
    }
}

private enum SamplePeriod: Hashable {
    case hour, sixHours, day, week

    static let options: [(value: SamplePeriod, label: String)] = [
        (.hour, "1 h"), (.sixHours, "6 h"), (.day, "24 h"), (.week, "7 Tage"),
    ]
}

private struct WatchbookBoardSample: View {
    let scene: SnapshotGallery.WatchbookScene

    var body: some View {
        let sample = WatchbookSamples.sample(scene)
        WatchbookBoard(status: sample.status, state: sample.state, readout: sample.readout, detail: sample.detail,
                       period: .constant(sample.period), periods: SamplePeriod.options,
                       marker: .constant(sample.marker), analysis: sample.analysis,
                       selectedFinding: .constant(sample.selectedFinding), jump: { _ in }, enable: {})
            .instrumentBackground()
    }
}

private struct WatchbookSample {
    var status: WatchbookStatus
    var state: WatchbookBoardState
    var readout: WatchbookReadout?
    var detail: String
    var period: SamplePeriod
    var marker: Int?
    var analysis = WatchbookAnalysis(moment: nil, findings: [], findingsEmptyText: "")
    var selectedFinding: String?
}

/// Erfundene Verläufe je Lage. Spalten wie in der App: so viele, wie die Zeichenfläche Bildpunkte breit ist.
private enum WatchbookSamples {
    static let columns = 1_000
    static let gib = 1_073_741_824.0
    static let physicalMemory = 32 * gib
    static let facts = "Aufzeichnung an seit Mo. 2. Nov., 09:14"

    static func sample(_ scene: SnapshotGallery.WatchbookScene) -> WatchbookSample {
        switch scene {
        case .hour: hour
        case .day: day
        case .week: week
        case .off:
            WatchbookSample(status: WatchbookStatus(verdict: "Wachbuch ist aus", finding: false, items: [],
                                                    facts: "Aufzeichnung aus"),
                            state: .off, readout: nil, detail: "Letzte 24 Stunden · gemeinsame Zeitachse", period: .day)
        case .empty:
            WatchbookSample(status: WatchbookStatus(verdict: "Noch keine Aufzeichnung", finding: false, items: [],
                                                    facts: "Aufzeichnung an seit 15:39"),
                            state: .empty, readout: nil, detail: "Letzte Stunde · gemeinsame Zeitachse", period: .hour)
        }
    }

    // MARK: Lagen

    /// 14:40 bis 15:40: Dauerlast von 15:02 bis 15:11 mit erhöhter Thermik, zwei Änderungen; Zeitmarke um 15:06.
    static var hour: WatchbookSample {
        let load = window(0.37, 0.52)
        let content = timeline(
            cpu: { t, _ in load(t) ? 0.86 + 0.05 * sin(t * 300) : 0.11 + 0.06 * wave(t, 41) + 0.08 * spike(t, 0.8) },
            memory: { t, _ in (17.8 + 1.4 * smooth(t, 0.35, 0.55) + 0.2 * wave(t, 7)) * gib },
            received: { t, _ in 180e3 + 140e3 * wave(t, 23) + 6.5e6 * spike(t, 0.71) },
            sent: { t, _ in 40e3 + 30e3 * wave(t, 19) },
            read: { t, _ in 2e6 + 1.5e6 * wave(t, 31) + 38e6 * spike(t, 0.38) },
            written: { t, _ in 1.2e6 + 0.8e6 * wave(t, 29) + 22e6 * spike(t, 0.4) },
            spread: 0,
            thermal: { t in window(0.40, 0.55)(t) ? .finding : .neutral },
            marks: [
                .init(id: "f1", style: .finding, start: 0.37, end: 0.52,
                      text: "Befund Dauerlast, 15:02 bis 15:11: CPU insgesamt länger als 2 Minuten über 80 % ausgelastet."),
                .init(id: "f2", style: .finding, start: 0.38, end: 0.50,
                      text: "Befund Prozesslast, 15:03 bis 15:10: swift-frontend belegt mehr als 90 % eines Kerns."),
                .init(id: "c1", style: .change, start: 0.30, end: 0.30, symbol: "app.badge",
                      text: "Änderung um 14:58: App installiert: Xcode 27.1"),
                .init(id: "c2", style: .change, start: 0.705, end: 0.705, symbol: "network",
                      text: "Änderung um 15:22: Neuer Netzwerkdienst: node, TCP 3000"),
            ],
            axis: [(0.083, "14:45"), (0.333, "15:00"), (0.583, "15:15"), (0.833, "15:30"), (1, "jetzt")],
            step: 16, summary: "2 Befunde · 2 Änderungen"
        )
        let marker = 430
        return WatchbookSample(
            status: WatchbookStatus(verdict: "2 Befunde in der letzten Stunde", finding: true,
                                    items: [StatusItem("Dauerlast", tone: .finding),
                                            StatusItem("Prozesslast", tone: .finding),
                                            StatusItem("2 Änderungen", tone: .neutral)], facts: facts),
            state: .recorded(content),
            readout: WatchbookReadout(time: "So 15:06", laneValues: ["89 %", "18,9 GB", "↓ 210 KB/s · ↑ 52 KB/s",
                                                                       "↓ 3,1 MB/s · ↑ 1,9 MB/s"],
                                      thermal: "mäßig"),
            detail: "Letzte Stunde · Zeitmarke per Klick, Ziehen oder Pfeiltasten", period: .hour, marker: marker,
            analysis: WatchbookAnalysis(moment: hourMoment, findings: [
                WatchbookFindingRowContent(id: "f1", isCritical: false, start: "So 15:02", duration: "9 min",
                                           kind: "Dauerlast",
                                           reason: "CPU insgesamt länger als 2 Minuten über 80 % ausgelastet.",
                                           cause: "swift-frontend"),
                WatchbookFindingRowContent(id: "f2", isCritical: false, start: "So 15:03", duration: "7 min",
                                           kind: "Prozesslast",
                                           reason: "swift-frontend belegt mehr als 90 % eines Kerns.",
                                           cause: "swift-frontend"),
            ].reversed(), findingsEmptyText: "Keine Befunde in der letzten Stunde."),
            selectedFinding: "f1"
        )
    }

    /// Samstag 15:40 bis Sonntag 15:40: Ruhezustand von 01:10 bis 06:40, drei Befunde (einer läuft), mehrere Änderungen.
    static var day: WatchbookSample {
        let asleep = window(0.398, 0.627)
        let content = timeline(
            cpu: { t, _ in asleep(t) ? nil : 0.14 + 0.1 * wave(t, 97) + 0.62 * window(0.18, 0.205)(t).value
                + 0.5 * window(0.94, 1)(t).value + 0.12 * spike(t, 0.71) },
            memory: { t, _ in asleep(t) ? nil : (16.5 + 6.5 * smooth(t, 0.28, 0.36) - 5.5 * smooth(t, 0.37, 0.39)
                + 0.6 * wave(t, 13)) * gib },
            received: { t, _ in asleep(t) ? nil : 300e3 + 250e3 * wave(t, 61) + 24e6 * spike(t, 0.66) },
            sent: { t, _ in asleep(t) ? nil : 60e3 + 40e3 * wave(t, 53) + 7.2e6 * window(0.80, 0.84)(t).value },
            read: { t, _ in asleep(t) ? nil : 3e6 + 2.5e6 * wave(t, 71) + 90e6 * spike(t, 0.635) },
            written: { t, _ in asleep(t) ? nil : 1.5e6 + 1.2e6 * wave(t, 67) + 30e6 * spike(t, 0.20) },
            spread: 0.35,
            thermal: { t in asleep(t) ? nil : window(0.18, 0.21)(t) || window(0.95, 1)(t) ? .finding : .neutral },
            marks: [
                .init(id: "f1", style: .finding, start: 0.18, end: 0.205,
                      text: "Befund Dauerlast, 19:59 bis 20:35: CPU insgesamt länger als 2 Minuten über 80 % ausgelastet."),
                .init(id: "f2", style: .finding, start: 0.285, end: 0.36,
                      text: "Befund Speicherdruck, 22:30 bis 00:18: macOS meldet erhöhten Speicherdruck."),
                .init(id: "f3", style: .finding, start: 0.80, end: 0.84,
                      text: "Befund Upload, 10:52 bis 11:50: Der Mac sendet länger als 5 Minuten mehr als 5 MB/s."),
                .init(id: "f4", style: .finding, start: 0.945, end: 1,
                      text: "Befund Dauerlast, seit 14:21, läuft: SourceKitService belegt mehr als 90 % eines Kerns."),
                .init(id: "s1", style: .system, start: 0.398, end: 0.627, symbol: "moon.zzz",
                      text: "Ruhezustand von 01:10 bis 06:40"),
                .init(id: "s2", style: .system, start: 0.63, end: 0.63, symbol: "sun.max",
                      text: "Aufgewacht um 06:44, Grund laut macOS: Deckel geöffnet"),
                .init(id: "c1", style: .change, start: 0.12, end: 0.12, symbol: "power",
                      text: "Änderung um 18:33: Neuer Autostart-Eintrag: com.example.updater"),
                .init(id: "c2", style: .change, start: 0.655, end: 0.655, symbol: "app.badge",
                      text: "Änderung um 07:23: App aktualisiert: Safari 27.1"),
                .init(id: "c3", style: .change, start: 0.66, end: 0.66, symbol: "app.badge",
                      text: "Änderung um 07:30: App aktualisiert: Mail 27.1"),
                .init(id: "c4", style: .change, start: 0.88, end: 0.88, symbol: "sparkles",
                      text: "Änderung um 12:47: Neuer MCP-Server: „files“ in Claude"),
            ],
            axis: [(0.097, "18:00"), (0.222, "21:00"), (0.347, "So"), (0.472, "03:00"), (0.597, "06:00"),
                   (0.722, "09:00"), (0.847, "12:00"), (1, "jetzt")],
            step: 10, summary: "4 Befunde · 4 Änderungen"
        )
        return WatchbookSample(
            status: WatchbookStatus(verdict: "4 Befunde in den letzten 24 Stunden · 1 läuft", finding: true,
                                    items: [StatusItem("Dauerlast", tone: .finding),
                                            StatusItem("Speicherdruck", tone: .finding),
                                            StatusItem("Upload", tone: .finding)], facts: facts),
            state: .recorded(content),
            readout: WatchbookReadout(time: "jetzt", laneValues: ["64 %", "17,1 GB", "↓ 420 KB/s · ↑ 75 KB/s",
                                                                   "↓ 4,8 MB/s · ↑ 2,2 MB/s"],
                                      thermal: "mäßig"),
            detail: "Letzte 24 Stunden · Zeitmarke per Klick, Ziehen oder Pfeiltasten", period: .day,
            analysis: WatchbookAnalysis(moment: nil, findings: dayFindings,
                                        findingsEmptyText: "Keine Befunde in den letzten 24 Stunden.")
        )
    }

    /// 1. bis 8. November: Aufzeichnung seit Montag 09:14, Nächte im Ruhezustand, sechs Befunde (einer kritisch),
    /// gehäufte Änderungen am Mittwoch.
    static var week: WatchbookSample {
        let start = 0.106
        func asleep(_ t: Double) -> Bool {
            guard t >= start else { return true }
            let hour = (t * 168 + 15.67).truncatingRemainder(dividingBy: 24)
            return hour < 7.2 || hour > 23.6
        }
        let content = timeline(
            cpu: { t, _ in asleep(t) ? nil : 0.16 + 0.12 * wave(t, 331) + 0.55 * spike(t, 0.395)
                + 0.45 * spike(t, 0.81) },
            memory: { t, _ in asleep(t) ? nil : (17 + 4 * wave(t, 23) + 8 * spike(t, 0.53)) * gib },
            received: { t, _ in asleep(t) ? nil : 500e3 + 400e3 * wave(t, 211) + 30e6 * spike(t, 0.25) },
            sent: { t, _ in asleep(t) ? nil : 90e3 + 70e3 * wave(t, 199) + 9e6 * spike(t, 0.67) },
            read: { t, _ in asleep(t) ? nil : 4e6 + 3e6 * wave(t, 223) + 120e6 * spike(t, 0.40) },
            written: { t, _ in asleep(t) ? nil : 2e6 + 1.6e6 * wave(t, 227) + 60e6 * spike(t, 0.53) },
            spread: 1,
            thermal: { t in asleep(t) ? nil : window(0.39, 0.40)(t) ? .critical
                : window(0.805, 0.815)(t) ? .finding : .neutral },
            marks: [
                .init(id: "f1", style: .finding, start: 0.393, end: 0.398,
                      text: "Befund Dauerlast, Mi. 4. Nov., 14:10 bis 14:58."),
                .init(id: "f2", style: .critical, start: 0.389, end: 0.401,
                      text: "Befund thermischer Zustand kritisch, Mi. 4. Nov., 13:40 bis 15:10."),
                .init(id: "f3", style: .finding, start: 0.528, end: 0.534,
                      text: "Befund Speicherdruck, Do. 5. Nov., 13:30 bis 14:30."),
                .init(id: "f4", style: .finding, start: 0.668, end: 0.672,
                      text: "Befund Upload, Fr. 6. Nov., 13:00 bis 13:40."),
                .init(id: "f5", style: .finding, start: 0.808, end: 0.812,
                      text: "Befund Dauerlast, Sa. 7. Nov., 12:40 bis 13:20."),
                .init(id: "f6", style: .finding, start: 0.25, end: 0.252,
                      text: "Befund Datenträger, Di. 3. Nov., 09:30 bis 09:50."),
                .init(id: "c1", style: .change, start: 0.36, end: 0.36, symbol: "app.badge",
                      text: "Änderung Mi. 4. Nov., 09:10: App installiert: Docker 5.2"),
                .init(id: "c2", style: .change, start: 0.362, end: 0.362, symbol: "puzzlepiece.extension",
                      text: "Änderung Mi. 4. Nov., 09:12: Neue Erweiterung: vmnet (Netzwerk)"),
                .init(id: "c3", style: .change, start: 0.364, end: 0.364, symbol: "power",
                      text: "Änderung Mi. 4. Nov., 09:12: Neuer Autostart-Eintrag: com.docker.helper"),
                .init(id: "c4", style: .change, start: 0.6, end: 0.6, symbol: "network",
                      text: "Änderung Fr. 6. Nov., 00:30: Neuer Netzwerkdienst: Docker, TCP 5432"),
                .init(id: "c5", style: .change, start: 0.93, end: 0.93, symbol: "sparkles",
                      text: "Änderung So. 8. Nov., 08:00: Automatische Freigabe für einen Agenten"),
            ],
            axis: [(0.05, "Mo"), (0.193, "Di"), (0.336, "Mi"), (0.479, "Do"), (0.621, "Fr"), (0.764, "Sa"),
                   (0.907, "So"), (1, "jetzt")],
            step: 6, summary: "6 Befunde · 5 Änderungen"
        )
        return WatchbookSample(
            status: WatchbookStatus(verdict: "6 Befunde in den letzten 7 Tagen", finding: true,
                                    items: [StatusItem("1 kritisch", tone: .critical),
                                            StatusItem("Dauerlast", tone: .finding),
                                            StatusItem("5 Änderungen", tone: .neutral)], facts: facts),
            state: .recorded(content),
            readout: WatchbookReadout(time: "Mi 13:40", laneValues: ["58 %", "26,2 GB", "↓ 380 KB/s · ↑ 64 KB/s",
                                                                       "↓ 18,6 MB/s · ↑ 7,2 MB/s"],
                                      thermal: "kritisch"),
            detail: "Letzte 7 Tage · Minutenwerte · Zeitmarke per Klick, Ziehen oder Pfeiltasten", period: .week,
            marker: 392, analysis: WatchbookAnalysis(moment: weekMoment, findings: weekFindings,
                                                     findingsEmptyText: "Keine Befunde in den letzten 7 Tagen."),
            selectedFinding: "f2"
        )
    }

    // MARK: Zu diesem Zeitpunkt und Befunde

    /// Zeitmarke um 15:06 mitten in der Dauerlast: der Compiler vorn, kurz zuvor Xcode installiert.
    static var hourMoment: WatchbookMomentContent {
        WatchbookMomentContent(
            time: "So 15:06",
            values: [.init(title: "GPU", value: "12 %"), .init(title: "Speicherdruck", value: "normal"),
                     .init(title: "Swap", value: "1,2 GB"), .init(title: "Thermik", value: "mäßig"),
                     .init(title: "Akku", value: "64 % · Netzteil"), .init(title: "Leistung", value: "38,4 W")],
            cpuConsumers: [
                .init(id: "c1", name: "swift-frontend", value: "61 %", fraction: 0.61),
                .init(id: "c2", name: "SourceKitService", value: "14 %", fraction: 0.14),
                .init(id: "c3", name: "kernel_task", badge: "System", value: "4 %", fraction: 0.04),
            ],
            memoryConsumers: [
                .init(id: "m1", name: "Xcode", value: "4,1 GB", fraction: 0.13),
                .init(id: "m2", name: "swift-frontend", value: "2,7 GB", fraction: 0.08),
                .init(id: "m3", name: "Andere Konten", value: "1,1 GB", fraction: 0.03),
            ],
            findings: [
                .init(id: "f1", style: .finding, title: "Dauerlast", time: "15:02 bis 15:11",
                      detail: "CPU insgesamt länger als 2 Minuten über 80 % ausgelastet."),
                .init(id: "f2", style: .finding, title: "Prozesslast", time: "15:03 bis 15:10",
                      detail: "swift-frontend belegt mehr als 90 % eines Kerns.",
                      jump: WatchbookJumpContent(id: "process", title: "In Details zeigen",
                                                 note: "swift-frontend läuft nicht mehr.")),
            ],
            changes: [
                .init(id: "c1", style: .change, symbol: "app.badge", title: "App installiert", time: "14:58",
                      detail: "Xcode 27.1", jump: WatchbookJumpContent(id: "history", title: "Im Verlauf zeigen")),
            ]
        )
    }

    static var dayFindings: [WatchbookFindingRowContent] {
        [
            .init(id: "f4", isCritical: false, start: "So 14:21", duration: "läuft · 1 h 19 min", kind: "Prozesslast",
                  reason: "SourceKitService belegt mehr als 90 % eines Kerns.", cause: "SourceKitService"),
            .init(id: "f3", isCritical: false, start: "So 10:52", duration: "58 min", kind: "Upload",
                  reason: "Der Mac sendet länger als 5 Minuten mehr als 5 MB/s.", cause: "–"),
            .init(id: "f2", isCritical: false, start: "Sa 22:30", duration: "1 h 48 min", kind: "Speicherdruck",
                  reason: "macOS meldet erhöhten Speicherdruck.", cause: "–"),
            .init(id: "f1", isCritical: false, start: "Sa 19:59", duration: "36 min", kind: "Dauerlast",
                  reason: "CPU insgesamt länger als 2 Minuten über 80 % ausgelastet.", cause: "node"),
        ]
    }

    static var weekFindings: [WatchbookFindingRowContent] {
        [
            .init(id: "f5", isCritical: false, start: "Sa 12:40", duration: "40 min", kind: "Dauerlast",
                  reason: "CPU insgesamt länger als 2 Minuten über 80 % ausgelastet.", cause: "ffmpeg"),
            .init(id: "f4", isCritical: false, start: "Fr 13:00", duration: "40 min", kind: "Upload",
                  reason: "Der Mac sendet länger als 5 Minuten mehr als 5 MB/s.", cause: "–"),
            .init(id: "f3", isCritical: false, start: "Do 13:30", duration: "1 h", kind: "Speicherdruck",
                  reason: "macOS meldet erhöhten Speicherdruck.", cause: "–"),
            .init(id: "f2", isCritical: true, start: "Mi 13:40", duration: "1 h 30 min", kind: "Thermik",
                  reason: "Thermischer Zustand länger als 5 Minuten kritisch.", cause: "–"),
            .init(id: "f1", isCritical: false, start: "Mi 14:10", duration: "48 min", kind: "Dauerlast",
                  reason: "CPU insgesamt länger als 2 Minuten über 80 % ausgelastet.", cause: "com.docker.vmnetd"),
            .init(id: "f6", isCritical: false, start: "Di 09:30", duration: "20 min", kind: "Datenträgerlast",
                  reason: "Datenträger länger als 5 Minuten stark belastet.", cause: "mds_stores"),
        ]
    }

    /// Zeitmarke Mittwoch 13:40 am Beginn der kritischen Thermik, kurz nach Docker samt Erweiterung und Autostart.
    static var weekMoment: WatchbookMomentContent {
        WatchbookMomentContent(
            time: "Mi 13:40",
            values: [.init(title: "GPU", value: "8 %"), .init(title: "Speicherdruck", value: "erhöht"),
                     .init(title: "Swap", value: "3,4 GB"), .init(title: "Thermik", value: "kritisch")],
            cpuConsumers: [], memoryConsumers: [],
            consumersNote: "Für diesen Zeitpunkt sind keine Verbraucher aufgezeichnet.",
            findings: [
                .init(id: "f2", style: .critical, title: "Thermik, kritisch", time: "seit 13:40",
                      detail: "Thermischer Zustand länger als 5 Minuten kritisch."),
            ],
            changes: [
                .init(id: "c2", style: .change, symbol: "puzzlepiece.extension", title: "Neue Erweiterung",
                      time: "13:37", detail: "vmnet (Netzwerk)",
                      jump: WatchbookJumpContent(id: "extension", title: "In Erweiterungen zeigen")),
                .init(id: "c3", style: .change, symbol: "power", title: "Neuer Autostart-Eintrag", time: "13:38",
                      detail: "com.docker.helper", jump: WatchbookJumpContent(id: "autostart", title: "In Autostart zeigen")),
                .init(id: "c4", style: .change, symbol: "network", title: "Neuer Netzwerkdienst", time: "13:43",
                      detail: "Docker, TCP 5432", jump: WatchbookJumpContent(id: "network", title: "In Verbindungen zeigen")),
            ]
        )
    }

    // MARK: Bausteine

    typealias Curve = (Double, Int) -> Double?

    static func timeline(cpu: Curve, memory: Curve, received: Curve, sent: Curve, read: Curve, written: Curve,
                         spread: Double, thermal: (Double) -> StatusTone?, marks: [WatchbookMarkContent],
                         axis: [(Double, String)], step: Int, summary: String) -> WatchbookTimelineContent {
        let lanes = [
            WatchbookLaneContent(id: "cpu", title: "CPU", hue: .cpu,
                                 graph: .line(values: column(cpu, spread: spread, limit: 1), upperBound: 1, hue: .cpu)),
            WatchbookLaneContent(id: "memory", title: "Arbeitsspeicher", hue: .memory,
                                 graph: .line(values: column(memory, spread: spread * 0.1, limit: physicalMemory),
                                              upperBound: physicalMemory, hue: .memory)),
            WatchbookLaneContent(id: "network", title: "Netz", hue: .received,
                                 graph: .mirror(upper: column(received, spread: spread), lower: column(sent, spread: spread),
                                                upperBound: 32e6, upperHue: .received, lowerHue: .sent)),
            WatchbookLaneContent(id: "disk", title: "Datenträger", hue: .diskRead,
                                 graph: .mirror(upper: column(read, spread: spread), lower: column(written, spread: spread),
                                                upperBound: 128e6, upperHue: .diskRead, lowerHue: .diskWrite)),
        ]
        return WatchbookTimelineContent(
            lanes: lanes, marks: marks,
            thermal: (0..<columns).map { thermal(position($0)) },
            axis: axis.map { WatchbookAxisTick(position: $0.0, label: $0.1) }, markerStep: step, eventSummary: summary
        )
    }

    /// Mittel aus der Kurve, Hülle als Anteil `spread` des Mittels darum (ohne Hülle bei 10-s-Spalten).
    static func column(_ curve: Curve, spread: Double, limit: Double = .infinity) -> [TimelineValue?] {
        (0..<columns).map { index in
            guard let mean = curve(position(index), index).map({ min(max($0, 0), limit) }) else { return nil }
            let width = mean * spread * (0.4 + 0.6 * wave(position(index), 53))
            return TimelineValue(minimum: max(mean - width, 0), maximum: min(mean + width * 1.6, limit), mean: mean)
        }
    }

    static func position(_ index: Int) -> Double { (Double(index) + 0.5) / Double(columns) }

    /// Gleichmäßige Welle zwischen 0 und 1 mit `cycles` Schwingungen über den Zeitraum, leicht unregelmäßig.
    static func wave(_ t: Double, _ cycles: Double) -> Double {
        0.5 + 0.3 * sin(t * cycles * 2 * .pi) + 0.2 * sin(t * cycles * 5.3 + 1.7)
    }

    /// Kurze Spitze um `centre` (Breite etwa 1 % des Zeitraums).
    static func spike(_ t: Double, _ centre: Double) -> Double { exp(-pow((t - centre) / 0.006, 2)) }

    /// Weicher Übergang von 0 auf 1 zwischen `from` und `to`.
    static func smooth(_ t: Double, _ from: Double, _ to: Double) -> Double {
        let share = min(max((t - from) / (to - from), 0), 1)
        return share * share * (3 - 2 * share)
    }

    static func window(_ from: Double, _ to: Double) -> (Double) -> Bool { { $0 >= from && $0 < to } }
}

extension Bool {
    fileprivate var value: Double { self ? 1 : 0 }
}
