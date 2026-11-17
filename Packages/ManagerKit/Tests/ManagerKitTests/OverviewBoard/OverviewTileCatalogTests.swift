import Foundation
import Testing
@testable import ManagerKit

/// Katalog der Kacheln des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): stabile Kennungen, erlaubte
/// Größen und Bedarf an Datenquellen je Kachel.
@Suite struct OverviewTileCatalogTests {
    /// Die Kennungen stehen in den gespeicherten Anordnungen; eine Umbenennung verlöre die Kachel beim Laden.
    @Test func identifiersAreStable() {
        #expect(OverviewTileKind.allCases.map(\.rawValue) == [
            "cpu", "cores", "processes", "gpu", "memory", "disk", "network", "thermal", "battery", "loadAverage",
            "uptime",
        ])
    }

    @Test func everyKindAllowsItsDefaultSpanAndOnlyGridSpans() {
        for kind in OverviewTileKind.allCases {
            #expect(kind.allowedSpans.contains(kind.defaultSpan), "\(kind)")
            #expect(kind.allowedSpans.allSatisfy { OverviewTileSpan.all.contains($0) }, "\(kind)")
            #expect(kind.allowedSpans == kind.allowedSpans.sorted(), "aufsteigend: \(kind)")
            #expect(!kind.title.isEmpty && !kind.symbolName.isEmpty)
        }
    }

    /// Die Kerne brauchen Platz für bis zu 16 Ringe in einer Zeile; kleine Werte bleiben klein.
    @Test func spansFitTheContent() {
        #expect(!OverviewTileKind.cores.allowedSpans.contains(.small))
        #expect(OverviewTileKind.cores.allowedSpans.contains(.panel))
        #expect(OverviewTileKind.uptime.allowedSpans == [.small, .wide])
        #expect(OverviewTileKind.cpu.allowedSpans == OverviewTileSpan.all)
    }

    /// Nur sichtbare Kacheln messen: Die Prozessquelle braucht nur die Prozess-Kachel.
    @Test func requirementsNameTheSources() {
        #expect(OverviewTileKind.processes.requirements.sources == [.processes])
        #expect(OverviewTileKind.processes.requirements.context == [.runningApps])
        #expect(OverviewTileKind.cores.requirements.sources == [.cpu])
        #expect(OverviewTileKind.disk.requirements == OverviewTileRequirements(sources: [.disks],
                                                                               context: [.startupVolume]))
        #expect(OverviewTileKind.thermal.requirements.sources.isEmpty)
        #expect(OverviewTileKind.loadAverage.requirements.context == [.loadAverage])
        let processFree = OverviewTileKind.allCases.filter { $0 != .processes }
        #expect(processFree.allSatisfy { !$0.requirements.sources.contains(.processes) })
    }

    @Test func kindsWithoutConfiguredSourceAreUnavailable() {
        let desktop = Set(TaskManagerSource.allCases).subtracting([.battery])
        #expect(!OverviewTileKind.battery.isAvailable(configured: desktop))
        #expect(OverviewTileKind.thermal.isAvailable(configured: []))
        #expect(OverviewTileKind.cpu.isAvailable(configured: desktop))
    }

    @Test func spanCodesRoundTrip() throws {
        for span in OverviewTileSpan.all {
            #expect(OverviewTileSpan(code: span.code) == span)
        }
        #expect(OverviewTileSpan.banner.code == "4x1")
        #expect(OverviewTileSpan(code: "9x1") == nil)
        #expect(OverviewTileSpan(code: "2×1") == nil)
        #expect(OverviewTileSpan(code: "") == nil)
        let data = try JSONEncoder().encode(OverviewTileSpan.large)
        #expect(String(decoding: data, as: UTF8.self) == "\"2x2\"")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OverviewTileSpan.self, from: Data("\"5x5\"".utf8)) }
    }

    /// Griff an der Kachel: Die gezogene Größe in Zellen rastet auf die nächste erlaubte Größe ein.
    @Test func dragSizeSnapsToNearestAllowedSpan() {
        let all = OverviewTileSpan.all
        #expect(OverviewTileSpan.nearest(columns: 1.2, rows: 0.8, among: all) == .small)
        #expect(OverviewTileSpan.nearest(columns: 2.4, rows: 1.3, among: all) == .wide)
        #expect(OverviewTileSpan.nearest(columns: 2.1, rows: 1.7, among: all) == .large)
        #expect(OverviewTileSpan.nearest(columns: 3.6, rows: 1.1, among: all) == .banner)
        #expect(OverviewTileSpan.nearest(columns: 9, rows: 9, among: all) == .panel)
        #expect(OverviewTileSpan.nearest(columns: 1, rows: 2, among: [.small, .wide]) == .small)
        #expect(OverviewTileSpan.nearest(columns: 1, rows: 1, among: []) == nil)
    }

    @Test func spanOrderIsByAreaThenWidth() {
        #expect(OverviewTileSpan.all == [.small, .wide, .large, .banner, .panel])
        #expect(OverviewTileSpan.small < .wide && .large < .banner)
    }
}
