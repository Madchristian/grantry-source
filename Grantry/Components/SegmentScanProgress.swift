import Foundation
import ManagerKit
import Observation

/// Gemeinsame Fortschrittsquelle der „Scannen“-Buttons in „Aufräumen“ (#270): App-Reste, Speicher und Prozesse halten
/// je eine und setzen ihre Leiste mit `scanProgressAboveTable(_:)` über die eigene Tabelle. Die Leiste zeigt nur den
/// laufenden Scan dieses Segments, nie den Monitoring-Vollscan („Aktualisieren“).
///
/// Gewichtet wird mit den Schrittdauern des letzten erfolgreichen Laufs (`ScanStepTracker`); sie bleiben nur im
/// Speicher, damit keine zusätzliche Datei gelesen oder geschrieben wird. Veröffentlicht wird höchstens 4/s.
@MainActor
@Observable
final class SegmentScanProgress {
    /// So lange steht die Leiste nach dem Ende bei 100 %, bevor sie verschwindet.
    static let finishedHold: Duration = .milliseconds(400)

    /// Fortschritt für die Leiste; `nil` = keine Leiste.
    private(set) var current: ScanProgress?
    /// Ein Scan läuft – der „Scannen“-Button dieses Segments ist gesperrt. Während der Haltezeit bei 100 % nicht mehr.
    private(set) var isRunning = false

    @ObservationIgnored private let hold: Duration
    @ObservationIgnored private let clock: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var tracker: ScanStepTracker<String>?
    @ObservationIgnored private var history: ScanStepDurations<String>?
    @ObservationIgnored private var started = ContinuousClock.now
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var hiding: Task<Void, Never>?

    init(hold: Duration = finishedHold, clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.hold = hold
        self.clock = clock
    }

    /// Beginnt einen Lauf und ersetzt einen laufenden; ohne `steps` unbestimmt bis zur Meldung `.planned`.
    @discardableResult
    func begin(steps: [String]? = nil) -> ScanStepReporter {
        hiding?.cancel()
        run += 1
        started = clock()
        isRunning = true
        if let steps {
            plan(steps)
        } else {
            tracker = nil
            current = ScanProgress(isIndeterminate: true)
        }
        return ScanStepReporter(progress: self, run: run)
    }

    /// Meldung des Laufs `run`; die eines ersetzten, abgebrochenen oder beendeten Laufs verfällt.
    func record(_ event: ScanStepEvent<String>, run: Int) {
        guard run == self.run, isRunning else { return }
        switch event {
        case .planned(let steps):
            guard tracker == nil else { return }
            plan(steps)
        case .completed(let step, let succeeded):
            guard tracker?.complete(step, elapsed: elapsed, succeeded: succeeded, now: clock()) == true else { return }
            current = tracker?.progress
        }
    }

    /// Springt auf 100 % und blendet die Leiste nach `hold` aus. `recordingDurations: false` für Teilläufe, deren
    /// Schritte die Gewichte des vollständigen Laufs nicht ersetzen sollen.
    func finish(recordingDurations: Bool = true) {
        guard isRunning else { return }
        tracker?.finish(elapsed: elapsed)
        if recordingDurations, let durations = tracker?.completedDurations { history = durations }
        end(showing: ScanProgress(fraction: 1))
        guard hold > .zero else {
            current = nil
            return
        }
        let run = run
        hiding = Task { [weak self, hold] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self, self.run == run else { return }
            self.current = nil
        }
    }

    /// Abbruch durch den Nutzer: Leiste sofort weg, nichts wird gelernt.
    func cancel() {
        guard isRunning else { return }
        end(showing: nil)
    }

    private var elapsed: TimeInterval { started.duration(to: clock()).scanSeconds }

    private func plan(_ steps: [String]) {
        let tracker = ScanStepTracker(steps: Set(steps), previous: history, schedule: .sequential)
        self.tracker = tracker
        current = tracker.progress
    }

    private func end(showing progress: ScanProgress?) {
        tracker = nil
        isRunning = false
        current = progress
    }
}

extension SegmentScanProgress {
    /// Laufender Scan mit festem Stand, für die Vorschauen der Aufräumen-Tabellen.
    static func preview(_ progress: ScanProgress = ScanProgress(fraction: 0.62, remainingSeconds: 18)) -> SegmentScanProgress {
        let preview = SegmentScanProgress()
        preview.isRunning = true
        preview.current = progress
        return preview
    }
}

/// Meldet die Schritte genau eines Laufs an seine `SegmentScanProgress`; passt als `ScanStepHandler<String>`.
struct ScanStepReporter: Sendable {
    let progress: SegmentScanProgress
    let run: Int

    func callAsFunction(_ event: ScanStepEvent<String>) async {
        await progress.record(event, run: run)
    }
}
