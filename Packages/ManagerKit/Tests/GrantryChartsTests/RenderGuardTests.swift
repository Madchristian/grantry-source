#if DEBUG
import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Render-Wächter (#372): Die Graphen zeichnen je Messpunkt einmal und zwischen zwei Messpunkten nie, auch bei einem
/// Bildtakt von 120 Hz; Animationen laufen nur über `ValueTransition`. Getrieben ohne Uhr: Jeder Messtakt ist ein neuer
/// Wert, jedes Bild ein erzwungener Durchlauf von Layout und Zeichnen (`RenderGuard`). Die Gegenproben bilden den Stand
/// vor #369 nach (`TimelineView` im Bildtakt, Animation je Takt) und müssen auffallen.
@MainActor
@Suite(.serialized) struct RenderGuardTests {
    private static let size = CGSize(width: 900, height: 600)
    private static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Verlauf bis Takt `tick`: 61 Punkte im Abstand von 1 s, der neueste bei `origin + tick`.
    private static func series(_ tick: Int, phase: Double = 0) -> ChartSeries {
        ChartSeries(values: (0...60).map { 0.45 + 0.35 * sin(Double(tick + $0) / 4 + phase) }, spacing: 1,
                    latest: origin.addingTimeInterval(Double(tick)))
    }

    /// Alle Bausteine mit Zeichenfunktion, wie die Tabs sie nutzen, je Takt mit neuen Werten.
    private static func gallery(_ tick: Int) -> some View {
        let load = 0.2 + 0.6 * abs(sin(Double(tick) / 3))
        return VStack {
            HStack {
                LiveGraph(series: series(tick), overlays: [.init(series: series(tick, phase: 1), scale: .fixed(0...1),
                                                                 color: .orange)])
                MirrorGraph(upper: series(tick).scaled(by: 4e6), lower: series(tick, phase: 2).scaled(by: 2e6))
                StackedAreaGraph(layers: [.init(id: "app", series: series(tick), color: .blue),
                                          .init(id: "cache", series: series(tick, phase: 1), color: .green)],
                                 total: 2)
            }
            HStack {
                Sparkline(series: series(tick), color: .teal)
                MirrorSparkline(upper: series(tick).scaled(by: 4e6), lower: series(tick, phase: 2).scaled(by: 2e6),
                                colors: (.blue, .orange))
                Spur(fraction: load, color: .teal)
                ArcGauge(fraction: load, color: .teal, textColor: .primary, value: "\(tick)", caption: "CPU")
                HeatCell("\(tick)", heat: load)
            }
            CoreGrid(clusters: [.init(kind: .performance, title: "P", detail: "", value: "\(tick)",
                                      series: series(tick), cores: (0..<4).map { .init(id: $0, series: series(tick + $0)) })])
        }
    }

    @Test func graphsDrawOncePerPointAndNeverBetween() throws {
        let report = RenderGuard.measure(size: Self.size) { Self.gallery($0) }
        #expect(report.violations().isEmpty, "\(report.violations())")
        #expect(report.ticks.count >= 10)
        // Wirklich gezeichnet: jeder Baustein mit Zeichenfunktion in jedem Takt.
        for site in ["LiveGraph", "MirrorGraph", "StackedAreaGraph", "ArcGauge"] {
            #expect(report.ticks.allSatisfy { $0.update[site, default: .init()].draws >= 1 }, "\(site) zeichnet nicht")
        }
        // Die Sparkline ohne Raster und Peilpunkt besteht aus Formen statt `Canvas` (#478): Sie zählt nur Auswertungen.
        for site in ["HeatCell", "CoreCell", "Sparkline", "MirrorSparkline", "Spur"] {
            #expect(report.ticks.allSatisfy { $0.update[site, default: .init()].bodies >= 1 }, "\(site) ohne Zähler")
        }
        // Ohne `Canvas` legt ein Fenster keinen Metal-Grafikpuffer an; im Popover sparte das rund 280 MB (Bewertung
        // 2026.11.9/1510, Mangel 1).
        for site in ["Sparkline", "MirrorSparkline", "Spur"] {
            #expect(report.ticks.allSatisfy { $0.update[site, default: .init()].draws == 0 }, "\(site) zeichnet per Canvas")
        }
    }

    /// Gegenprobe Stand vor #369: Ein Graph per `TimelineView(.animation)` zeichnet im Bildtakt neu – das fällt in jedem
    /// Messtakt auf, weil jeder Takt bis zu einem Bildtakt des Systems läuft.
    @Test func frameRateRedrawFailsInEveryTick() {
        let report = RenderGuard.measure(size: Self.size) { FrameRateGraph(series: Self.series($0)) }
        let flagged = Set(report.violations().filter { $0.site == "FrameRateGraph" && $0.phase == .between }.map(\.tick))
        #expect(flagged == Set(1...RenderGuard.tickCount))
        #expect(report.ticks.allSatisfy { $0.displayFrames >= 1 })
    }

    /// Gegenprobe Stand vor #369: Eine Tabelle sortiert je Takt animiert um; die Zellen bekommen die Animation mit.
    @Test func animationPerTickFails() {
        let report = RenderGuard.measure(size: Self.size) { tick in
            let order = tick.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0]
            VStack {
                ForEach(order, id: \.self) { row in HeatCell("\(row)", heat: 0.31) }
            }
            .animation(.smooth(duration: 0.45), value: order)
        }
        #expect(report.violations().contains { $0.site == "HeatCell" && $0.measure == .animatedUpdates })
    }

    /// `ValueTransition`: kleine Schwankungen innerhalb einer Zehntelstufe ohne Übergang.
    @Test func valueTransitionStaysQuietWithinAStep() {
        let report = RenderGuard.measure(size: Self.size) { tick in
            SteppedFill(fraction: 0.31 + 0.002 * Double(tick))
        }
        #expect(report.violations().isEmpty, "\(report.violations())")
        #expect(report.ticks.allSatisfy { $0.update[RenderProbe.valueTransition, default: .init()].animatedUpdates == 0 })
    }

    /// `ValueTransition`: ein Übergang je Stufenwechsel, nicht mehr.
    @Test func valueTransitionAnimatesOncePerStepChange() {
        let report = RenderGuard.measure(size: Self.size) { tick in
            SteppedFill(fraction: tick.isMultiple(of: 2) ? 0.2 : 0.8)
        }
        #expect(report.violations().isEmpty, "\(report.violations())")
        #expect(report.ticks.allSatisfy { $0.update[RenderProbe.valueTransition, default: .init()].animatedUpdates == 1 })
    }

    /// Tabellenzellen wechseln ohne Übergang, auch bei großen Sprüngen (#478): In einer nach CPU sortierten Tabelle wechselt
    /// fast in jedem Takt irgendeine Zelle die Stufe, jeder Übergang zeichnete 0,3 s im Bildtakt.
    @Test func heatCellChangesWithoutTransition() {
        let report = RenderGuard.measure(size: Self.size) { tick in
            HeatCell("\(tick)", heat: tick.isMultiple(of: 2) ? 0.2 : 0.8)
        }
        #expect(report.violations().isEmpty, "\(report.violations())")
        #expect(report.ticks.allSatisfy { $0.update[RenderProbe.valueTransition, default: .init()].animatedUpdates == 0 })
        #expect(report.ticks.allSatisfy { $0.update["HeatCell", default: .init()].bodies >= 1 })
    }

    /// Andere Ansichten im selben Prozess zählen nicht mit, auch wenn sie während der Messung zeichnen – etwa
    /// Snapshot-Tests, die die Ereignisschleife des Wächters mit ausführt.
    @Test func renderingOutsideTheGuardDoesNotCount() {
        let outside = Task { @MainActor in
            for tick in 0..<200 {
                _ = ImageRenderer(content: LiveGraph(series: Self.series(tick)).frame(width: 200, height: 80)).cgImage
                await Task.yield()
            }
        }
        defer { outside.cancel() }
        let report = RenderGuard.measure(size: Self.size) { tick in
            Text(verbatim: "\(tick)").renderProbe("Inside")
        }
        #expect(report.violations().isEmpty, "\(report.violations())")
        let sites = Set(([report.warmup] + report.ticks.flatMap { [$0.update, $0.between] }).flatMap(\.keys))
        #expect(sites == ["Inside"])
    }

    /// Nur das Zurückfedern nach dem Ziehen zeichnet im Bildtakt, und höchstens 1 s.
    @Test func springBackLastsAtMostOneSecond() {
        #expect(Scrub.springDuration <= .seconds(1))
    }
}

/// Graph wie bis 2026.11.7 (1188): Bild hängt von der Uhr ab und wird im Bildtakt neu gezeichnet.
private struct FrameRateGraph: View {
    let series: ChartSeries

    var body: some View {
        TimelineView(.animation) { timeline in
            Plot("FrameRateGraph") { context, size in
                let shift = timeline.date.timeIntervalSince(series.latest)
                context.fill(Path(CGRect(x: shift, y: 0, width: size.width / 2, height: size.height)), with: .color(.red))
            }
        }
        .renderProbe("FrameRateGraph")
    }
}

private extension ChartSeries {
    func scaled(by factor: Double) -> ChartSeries {
        var scaled = self
        scaled.values = values.map { $0.map { $0 * factor } }
        return scaled
    }
}

/// Fläche mit Deckkraft nach Anteil und dem Übergang aus `ValueTransition`, wie Ringe und Säulen ihn nutzen.
private struct SteppedFill: View {
    let fraction: Double

    @Environment(\.chartStyle) private var style

    var body: some View {
        Rectangle()
            .fill(.teal.opacity(fraction))
            .animatesSteps(of: fraction, when: style.animates)
    }
}
#endif
