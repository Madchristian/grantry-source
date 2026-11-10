import Foundation

/// Auflösung des Wachbuchs (Spec 2026-11-08 §5.1): Grundlage sind 10-s-Punkte. Misst der Task-Manager schneller, kommen
/// seine Takte als volle Auflösung hinzu; geschrieben werden sie nur um Befunde (`findingMargin` davor und danach),
/// sonst gilt der 10-s-Punkt ihres Abschnitts – nie beides für dieselbe Zeit.
///
/// Ein Befund steht erst nach seiner Mindestdauer fest. Abschnitte mit Takten bleiben daher `holdback` lang
/// zurückgehalten, bis entschieden ist, ob sie in ein Befundfenster fallen; Abschnitte ohne Takte (eigener 10-s-Takt)
/// gehen sofort weiter, sofern kein älterer Abschnitt noch wartet. Rein und ohne Uhr.
struct WatchbookResolution {
    /// Volle Auflösung so lange vor dem Beginn und nach dem Ende eines Befunds.
    static let findingMargin: TimeInterval = 120

    /// Ein 10-s-Abschnitt: sein Basispunkt und die Takte des Task-Managers, die in ihn fallen (oft keine).
    private struct Period {
        let base: WatchbookPoint
        let frames: [WatchbookPoint]

        var start: Date { frames.first?.time ?? base.time }
    }

    let holdback: TimeInterval
    /// Abgeschlossene Abschnitte, älteste zuerst.
    private var periods: [Period] = []
    /// Takte des laufenden Abschnitts.
    private var frames: [WatchbookPoint] = []

    init(holdback: TimeInterval) {
        self.holdback = holdback
    }

    /// Rückhalt passend zu den Regeln: längste Mindestdauer plus Rand plus zwei 10-s-Takte für Auswertung und Abstand.
    init(thresholds: FindingThresholds) {
        let longest = SystemFinding.Kind.allCases.map { thresholds.rule(for: $0).minimumDuration }.max() ?? 0
        self.init(holdback: longest + Self.findingMargin + 2 * WatchbookPoint.interval)
    }

    /// Basispunkte der zurückgehaltenen Abschnitte – für die Anzeige, solange noch nichts geschrieben ist.
    var heldPoints: [WatchbookPoint] { periods.map(\.base) }

    /// Ein Takt des Task-Managers in voller Auflösung.
    mutating func addFrame(_ point: WatchbookPoint) {
        frames.append(point)
    }

    /// Schließt den laufenden Abschnitt mit seinem 10-s-Punkt ab.
    mutating func addBase(_ point: WatchbookPoint) {
        periods.append(Period(base: point, frames: frames))
        frames = []
    }

    /// Verwirft die Takte des laufenden Abschnitts, etwa vor einer Lücke (Ruhezustand).
    mutating func dropFrames() {
        frames = []
    }

    /// Gibt in Reihenfolge ab, was entschieden werden kann: Abschnitte ohne Takte sofort, die übrigen nach `holdback`.
    mutating func release(now: Date, findings: [SystemFinding]) -> [WatchbookPoint] {
        let decided = periods.prefix { period in
            period.frames.isEmpty || period.base.time.addingTimeInterval(holdback) <= now
        }
        periods.removeFirst(decided.count)
        return points(of: decided, findings: findings)
    }

    /// Entscheidet alle abgeschlossenen Abschnitte sofort (Ruhezustand, Ausschalten, Beenden).
    mutating func releaseAll(findings: [SystemFinding]) -> [WatchbookPoint] {
        defer { periods = [] }
        return points(of: periods[...], findings: findings)
    }

    private func points(of periods: ArraySlice<Period>, findings: [SystemFinding]) -> [WatchbookPoint] {
        let windows = findings.map { finding in
            finding.start.addingTimeInterval(-Self.findingMargin)...(finding.end ?? .distantFuture)
                .addingTimeInterval(Self.findingMargin)
        }
        return periods.flatMap { period -> [WatchbookPoint] in
            let isNearFinding = windows.contains { $0.overlaps(period.start...period.base.time) }
            return isNearFinding && !period.frames.isEmpty ? period.frames : [period.base]
        }
    }
}
