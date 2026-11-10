import SwiftUI
import Testing
@testable import GrantryCharts

/// Snapshot-Tests der Graphen in hell, dunkel und „Kontrast erhöhen“ (Spec 2026-11-06 §4, §7, #320). Referenzen unter
/// `__Snapshots__`; neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct ChartSnapshotTests {
    @Test(arguments: ChartAppearance.allCases)
    func liveGraph(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.liveGraph, named: "live-graph", size: CGSize(width: 360, height: 160),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func mirrorGraph(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.mirrorGraph, named: "mirror-graph", size: CGSize(width: 360, height: 160),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func memory(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.memory, named: "memory", size: CGSize(width: 480, height: 170),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func coreGrid(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.coreGrid, named: "core-grid", size: CGSize(width: 720, height: 470),
                                 appearance: appearance)
    }

    /// Chip-Tab: M4 Max mit Helper, M2 Ultra ohne Helper (verschränkte Kernnummern, Hinweis, Platzhalter).
    @Test(arguments: ChartAppearance.allCases)
    func chip(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.chip, named: "chip", size: CGSize(width: 1180, height: 1240),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func chipUltra(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.chipUltra, named: "chip-ultra", size: CGSize(width: 1180, height: 1290),
                                 appearance: appearance)
    }

    /// Panel „Takt und Thermik“: mit Helper, mit Drosselung (Befund-Punkt, mehr Cluster), ohne Helper.
    @Test(arguments: ChartAppearance.allCases)
    func clockThermal(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.clockGallery(SnapshotGallery.clockPanel), named: "clock-thermal",
                                 size: CGSize(width: 1180, height: 380), appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func clockThermalThrottled(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.clockGallery(SnapshotGallery.clockPanelThrottled),
                                 named: "clock-thermal-throttled", size: CGSize(width: 1180, height: 560),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func clockThermalWithoutHelper(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.clockGallery(SnapshotGallery.clockPanelWithoutHelper),
                                 named: "clock-thermal-without-helper", size: CGSize(width: 1180, height: 260),
                                 appearance: appearance)
    }

    /// Energie beim Laden: Akku und „Netzteil und Laden“ (TM-14.4).
    @Test(arguments: ChartAppearance.allCases)
    func energyCharging(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.energyCharging, named: "energy-charging",
                                 size: CGSize(width: 380, height: 556), appearance: appearance)
    }

    /// Energie im Akkubetrieb mit kritischem Ladestand: kein Panel „Netzteil und Laden“ (TM-14.6, #399).
    @Test(arguments: ChartAppearance.allCases)
    func energyOnBattery(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.energyOnBattery, named: "energy-akkubetrieb",
                                 size: CGSize(width: 380, height: 380), appearance: appearance)
    }

    /// Energie am Netzteil mit Ladeschutz: „Lädt nicht“, Ladeleistung 0 W, im Kopf die Leistung des Netzteils und
    /// darunter, warum der Akku ruht (TM-14.6, #399; Befund 10.11.2026).
    @Test(arguments: ChartAppearance.allCases)
    func energyChargeLimit(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.energyChargeLimit, named: "energy-ladeschutz",
                                 size: CGSize(width: 380, height: 600), appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func tiles(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.tiles, named: "tiles", size: CGSize(width: 300, height: 160),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func metricCards(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.metricCards, named: "metric-cards", size: CGSize(width: 380, height: 150),
                                 appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func instrument(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.instrument, named: "instrument", size: CGSize(width: 480, height: 260),
                                 appearance: appearance)
    }

    /// Lagezeile mit Datenträger-Befund (TM-15.5).
    @Test(arguments: ChartAppearance.allCases)
    func verdictStorage(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.verdictStorage, named: "verdict-storage",
                                 size: CGSize(width: 1400, height: 110), appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func heatTable(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.heatTable, named: "heat-table", size: CGSize(width: 440, height: 120),
                                 appearance: appearance)
    }

    /// „Kontrast erhöhen“ muss tatsächlich anders zeichnen (kräftige Linien ohne Glow, kräftigeres Raster) – sonst prüften
    /// die Kontrast-Referenzen nur das helle Bild noch einmal.
    @Test func increasedContrastChangesTheDrawing() throws {
        let size = CGSize(width: 360, height: 160)
        let light = try #require(ChartImage(SnapshotGallery.liveGraph, size: size, appearance: .light))
        let contrast = try #require(ChartImage(SnapshotGallery.liveGraph, size: size, appearance: .contrast))
        #expect(light.difference(to: contrast) > 0.01)
    }

    /// Ohne Referenzbilder liefe jeder Vergleich in die Aufzeichnung; sie gehören eingecheckt dazu.
    @Test func everyReferenceIsCheckedIn() throws {
        let names = ["live-graph", "mirror-graph", "memory", "core-grid", "tiles", "metric-cards", "heat-table", "instrument",
                     "chip", "chip-ultra", "energy-charging", "energy-akkubetrieb", "energy-ladeschutz", "clock-thermal",
                     "clock-thermal-throttled", "clock-thermal-without-helper", "verdict-storage"]
        let missing = names.flatMap { name in ChartAppearance.allCases.map { "\(name)-\($0.rawValue).png" } }
            .filter { !FileManager.default.fileExists(atPath: ChartSnapshot.references.appending(path: $0).path) }
        #expect(missing.isEmpty, "fehlende Referenzen: \(missing)")
    }
}
