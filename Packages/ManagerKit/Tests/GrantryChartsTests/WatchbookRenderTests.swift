#if DEBUG
import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Leistungsregeln des Wachbuch-Tabs (Spec 2026-11-08 § 4.4, TM-12.5): Spuren, Ereignisleiste und Thermikband zeichnen je
/// neuer Spalte einmal und zwischen zwei Spalten nie; eine bewegte Zeitmarke zeichnet nur die Marke neu, nicht die
/// Graphen (`RenderGuard`, Muster `runningGraphStandsStillBetweenPoints`).
@MainActor
@Suite(.serialized) struct WatchbookRenderTests {
    private static let size = SnapshotGallery.watchbookSize
    private static let graphs = ["TimelineGraph", "TimelineMirrorGraph", "WatchbookEventBar", "WatchbookStateBand"]

    /// Die Stunde aus der Galerie, je Takt um `tick` Spalten weitergeschoben – wie eine neu gelesene Reihe.
    private static func content(_ tick: Int) throws -> WatchbookTimelineContent {
        var content = try #require(SnapshotGallery.watchbookTimeline(.hour))
        func shifted<T>(_ values: [T]) -> [T] { Array(values.dropFirst(tick) + values.prefix(tick)) }
        content.lanes = content.lanes.map { lane in
            let graph: WatchbookLaneContent.Graph = switch lane.graph {
            case .line(let values, let upperBound, let hue):
                .line(values: shifted(values), upperBound: upperBound, hue: hue)
            case .mirror(let upper, let lower, let upperBound, let upperHue, let lowerHue):
                .mirror(upper: shifted(upper), lower: shifted(lower), upperBound: upperBound, upperHue: upperHue,
                        lowerHue: lowerHue)
            }
            return WatchbookLaneContent(id: lane.id, title: lane.title, hue: lane.hue, graph: graph)
        }
        content.thermal = shifted(content.thermal)
        let step = Double(tick) / Double(max(content.columnCount, 1))
        content.marks = content.marks.map {
            WatchbookMarkContent(id: $0.id, style: $0.style, start: $0.start - step, end: $0.end - step,
                                 symbol: $0.symbol, text: $0.text)
        }
        return content
    }

    private static let noAnalysis = WatchbookAnalysis(moment: nil, findings: [], findingsEmptyText: "")

    private static func board(_ content: WatchbookTimelineContent, marker: Int?,
                              analysis: WatchbookAnalysis = noAnalysis) -> some View {
        WatchbookBoard(status: WatchbookStatus(verdict: "Ruhig seit 1 Stunde", finding: false, items: [], facts: ""),
                       state: .recorded(content),
                       readout: WatchbookReadout(time: "jetzt", laneValues: ["1 %", "2 GB", "–", "–"], thermal: "normal"),
                       detail: "", period: .constant(0), periods: [(0, "1 h")], marker: .constant(marker),
                       analysis: analysis, selectedFinding: .constant(nil), jump: { _ in }, enable: {})
            .instrumentBackground()
    }

    @Test func newColumnsDrawOnceAndNothingBetween() throws {
        let contents = try (0...RenderGuard.tickCount).map(Self.content)
        let report = RenderGuard.measure(size: Self.size) { Self.board(contents[$0], marker: nil) }
        #expect(report.violations(root: "WatchbookBoard").isEmpty, "\(report.violations(root: "WatchbookBoard"))")
        for site in Self.graphs {
            #expect(report.ticks.allSatisfy { $0.update[site, default: .init()].draws >= 1 }, "\(site) zeichnet nicht")
        }
    }

    @Test func movingTheMarkerRedrawsOnlyTheMarker() throws {
        let content = try Self.content(0)
        let report = RenderGuard.measure(size: Self.size) { Self.board(content, marker: 100 + $0 * 7) }
        #expect(report.violations(root: "WatchbookBoard").isEmpty, "\(report.violations(root: "WatchbookBoard"))")
        #expect(report.ticks.allSatisfy { $0.update["WatchbookMarker", default: .init()].draws >= 1 })
        for site in Self.graphs {
            #expect(report.ticks.allSatisfy { $0.update[site, default: .init()].draws == 0 }, "\(site) zeichnet neu")
        }
    }

    /// Mit Panel „Zu diesem Zeitpunkt“ (TM-12.6): Eine bewegte Zeitmarke mit neuem Panelinhalt zeichnet die Graphen nicht
    /// neu.
    @Test func movingTheMarkerWithThePanelLeavesTheGraphs() throws {
        let content = try Self.content(0)
        let analysis = SnapshotGallery.watchbookAnalysis(.hour)
        let moment = try #require(analysis.moment)
        let report = RenderGuard.measure(size: Self.size) { tick in
            var shifted = moment
            shifted.time = "So 15:\(10 + tick)"
            return Self.board(content, marker: 100 + tick * 7,
                              analysis: WatchbookAnalysis(moment: shifted, findings: analysis.findings,
                                                          findingsEmptyText: analysis.findingsEmptyText))
        }
        #expect(report.violations(root: "WatchbookBoard").isEmpty, "\(report.violations(root: "WatchbookBoard"))")
        for site in Self.graphs {
            #expect(report.ticks.allSatisfy { $0.update[site, default: .init()].draws == 0 }, "\(site) zeichnet neu")
        }
    }

    /// Ohne neue Spalte bleibt die Tafel pixelgleich: Das Bild hängt nicht von der Uhr ab.
    @Test func boardStandsStillBetweenColumns() async throws {
        let content = try Self.content(0)
        let first = try #require(ChartImage(Self.board(content, marker: 430), size: Self.size, paused: false))
        try await Task.sleep(for: .milliseconds(400))
        let second = try #require(ChartImage(Self.board(content, marker: 430), size: Self.size, paused: false))
        #expect(first.coverage > 0.05)
        #expect(first.difference(to: second) == 0)
    }
}
#endif
