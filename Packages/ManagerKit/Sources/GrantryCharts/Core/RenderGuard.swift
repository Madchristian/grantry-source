#if DEBUG
import AppKit
import SwiftUI

/// Render-Wächter (#372): treibt eine Ansicht über feste Messtakte mit einem simulierten Bildtakt und zählt dabei die
/// `RenderProbe`-Zählpunkte. Ohne Uhr: Ein Messtakt ist ein neuer Wert aus `content`, ein Bild ein erzwungener
/// Durchlauf von Ereignisschleife, Layout und Zeichnen; gewartet wird nie. Die Ansicht liegt in einem Fenster, das nie
/// auf den Bildschirm kommt, und braucht weder Anzeige noch Bildschirmaufnahme-Berechtigung.
///
/// Regeln aus #369 (`Report.violations`): zwischen zwei Messtakten nichts – keine Auswertung, kein Zeichnen, keine
/// Animation –, je Messtakt jeder Graph höchstens einmal gezeichnet, Animationen nur über `ValueTransition`.
///
/// Neuzeichnen im Bildtakt (`TimelineView`) treibt das System über seinen Bildtakt, nicht über die erzwungenen Bilder.
/// Damit es in jedem Messtakt auffällt, zählt ein eigener Fühler (`FrameSentinel`, selbst eine `TimelineView`) die
/// gelieferten Bildtakte, und jeder Messtakt läuft weiter, bis `displayFramesPerTick` ankamen – höchstens
/// `maximumFramesPerTick` Bilder. Korrekte Ansichten zählen zwischen den Takten immer 0, wie viele Bilder es auch werden;
/// kommt kein Bildtakt an, meldet `violations` das, statt still nichts zu sehen.
@MainActor
public enum RenderGuard {
    /// Messtakte je Lauf (Issue #372: mindestens 10).
    public nonisolated static let tickCount = 10
    /// Bilder je Messtakt: 120 Hz bei 1 s Takt.
    public nonisolated static let framesPerTick = 120
    /// Bildtakte des Systems je Messtakt: Eine eben neu ausgewertete `TimelineView` ist beim ersten noch nicht fällig.
    public nonisolated static let displayFramesPerTick = 2
    /// Obergrenze, falls das System keinen Bildtakt liefert.
    public nonisolated static let maximumFramesPerTick = 50 * framesPerTick

    public enum Phase: String, Sendable {
        /// Erste Darstellung; wird nicht geprüft.
        case warmup
        /// Das erste Bild nach dem neuen Wert.
        case update
        /// Die übrigen Bilder bis zum nächsten Takt.
        case between
    }

    public enum Measure: String, Sendable {
        case bodies, draws, animatedUpdates
        /// „Bewegung reduzieren“ ist aktiv: Animationen sind aus, der Wächter sähe sie nicht.
        case reducedMotion
        /// Zu wenige Bildtakte des Systems in diesem Messtakt: Neuzeichnen im Bildtakt bliebe unsichtbar.
        case displayFrames
    }

    public struct Tick: Sendable {
        public var update: [String: RenderCounts]
        public var between: [String: RenderCounts]
        /// Vom System gelieferte Bildtakte (`FrameSentinel`) in diesem Messtakt.
        public var displayFrames: Int
    }

    public struct Violation: Equatable, Sendable, CustomStringConvertible {
        public let tick: Int
        public let phase: Phase
        public let site: String
        public let measure: Measure
        public let value: Int
        public let limit: Int

        public var description: String {
            "Takt \(tick) \(phase.rawValue): \(site) \(measure.rawValue) = \(value), erlaubt \(limit)"
        }
    }

    public struct Report: Sendable {
        public var warmup: [String: RenderCounts]
        public var ticks: [Tick]
        /// Ob Animationen liefen (`chartStyle.animates`).
        public var animates: Bool

        /// Verstöße gegen die Regeln aus #369. `root` begrenzt zusätzlich die Auswertungen der Tab-Ansicht je Takt.
        public func violations(root: String? = nil, rootBodiesPerTick: Int = 1) -> [Violation] {
            var found: [Violation] = []
            if !animates {
                found.append(Violation(tick: 0, phase: .warmup, site: "chartStyle", measure: .reducedMotion, value: 1,
                                       limit: 0))
            }
            for (index, tick) in ticks.enumerated() {
                let number = index + 1
                if tick.displayFrames < displayFramesPerTick {
                    found.append(Violation(tick: number, phase: .between, site: "FrameSentinel",
                                           measure: .displayFrames, value: tick.displayFrames,
                                           limit: displayFramesPerTick))
                }
                for (site, counts) in tick.between.sorted(by: { $0.key < $1.key }) {
                    for (measure, value) in counts.values where value > 0 {
                        found.append(Violation(tick: number, phase: .between, site: site, measure: measure,
                                               value: value, limit: 0))
                    }
                }
                for (site, counts) in tick.update.sorted(by: { $0.key < $1.key }) {
                    // Ein `Canvas` zeichnet nur neu, wenn seine Ansicht neu ausgewertet wurde: höchstens einmal je Graph.
                    if counts.draws > counts.bodies {
                        found.append(Violation(tick: number, phase: .update, site: site, measure: .draws,
                                               value: counts.draws, limit: counts.bodies))
                    }
                    let allowed = site == RenderProbe.valueTransition ? counts.bodies : 0
                    if counts.animatedUpdates > allowed {
                        found.append(Violation(tick: number, phase: .update, site: site, measure: .animatedUpdates,
                                               value: counts.animatedUpdates, limit: allowed))
                    }
                    if site == root, counts.bodies > rootBodiesPerTick {
                        found.append(Violation(tick: number, phase: .update, site: site, measure: .bodies,
                                               value: counts.bodies, limit: rootBodiesPerTick))
                    }
                }
            }
            return found
        }
    }

    /// Stellt `content(0)` dar und liefert danach `tickCount` neue Werte `content(1)` … `content(tickCount)`, je Wert
    /// mindestens `framesPerTick` Bilder und `displayFramesPerTick` Bildtakte des Systems.
    public static func measure<Content: View>(ticks tickCount: Int = tickCount, framesPerTick: Int = framesPerTick,
                                              size: CGSize,
                                              @ViewBuilder content: @escaping @MainActor (Int) -> Content) -> Report {
        let recorder = RenderRecorder()
        let source = TickSource()
        let hosting = NSHostingView(rootView: ZStack {
            // Neben der Ansicht, nicht in ihr: Ein neuer Messtakt soll den Fühler nicht mit auswerten.
            FrameSentinel(source: source)
            TickHost(source: source, content: content)
                .environment(\.renderRecorder, recorder)
                .transaction { $0.renderRecorder = recorder }
        })
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        pump(hosting, frames: framesPerTick)
        let warmup = recorder.take()
        var ticks: [Tick] = []
        for tick in 1...max(tickCount, 1) {
            source.tick = tick
            pump(hosting, frames: 1)
            let update = recorder.take()
            let delivered = source.displayFrames
            var frames = 1
            while frames < framesPerTick
                || (source.displayFrames - delivered < displayFramesPerTick && frames < maximumFramesPerTick) {
                pump(hosting, frames: 1)
                frames += 1
            }
            ticks.append(Tick(update: update, between: recorder.take(),
                              displayFrames: source.displayFrames - delivered))
        }
        return Report(warmup: warmup, ticks: ticks, animates: source.animates)
    }

    /// Ein Bild: anstehende Ereignisse der Schleife ausliefern, ohne zu warten, dann Layout und Zeichnen erzwingen.
    private static func pump(_ view: NSView, frames: Int) {
        for _ in 0..<frames {
            RunLoop.main.run(mode: .default, before: .distantPast)
            view.layoutSubtreeIfNeeded()
            view.display()
        }
    }
}

extension RenderCounts {
    fileprivate var values: [(RenderGuard.Measure, Int)] {
        [(.bodies, bodies), (.draws, draws), (.animatedUpdates, animatedUpdates)]
    }
}

/// Messtakt, den `RenderGuard` weiterschaltet.
@MainActor @Observable
private final class TickSource {
    var tick = 0
    @ObservationIgnored var animates = true
    @ObservationIgnored var displayFrames = 0
    @ObservationIgnored private var lastFrame: Date?

    func deliver(_ frame: Date) {
        guard frame != lastFrame else { return }
        lastFrame = frame
        displayFrames += 1
    }
}

/// Fühler für den Bildtakt des Systems: wertet je geliefertem Bild seinen Inhalt aus, wie es eine `TimelineView` im
/// Bildtakt in einem Graphen täte, und meldet das `TickSource`. Zeichnet nichts.
private struct FrameSentinel: View {
    let source: TickSource

    var body: some View {
        TimelineView(.animation) { timeline in
            let _ = source.deliver(timeline.date)
            Color.clear
        }
    }
}

private struct TickHost<Content: View>: View {
    let source: TickSource
    let content: @MainActor (Int) -> Content

    @Environment(\.chartStyle) private var style

    var body: some View {
        // Ohne Beobachtung gemerkt: Der Stil ändert sich während der Messung nicht.
        source.animates = style.animates
        return content(source.tick)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
