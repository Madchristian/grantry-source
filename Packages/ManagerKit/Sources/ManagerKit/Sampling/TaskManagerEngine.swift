/// Abgriff der Takte des Task-Managers, etwa für das Wachbuch (TM-12.3): sieht Beginn und Ende jedes Laufs und je Takt
/// die Rohmessung samt fertigem Stand. Läuft synchron im Messtakt außerhalb des Main Actors und muss daher sofort
/// zurückkehren; Laufbeginn und -ende können sich bei einem Taktwechsel überschneiden.
public protocol TaskManagerTap: Sendable {
    func taskManagerDidStart()
    func taskManagerDidMeasure(_ readings: TaskManagerReadings, frame: TaskManagerFrame)
    func taskManagerDidStop()
}

/// Misst im Takt und liefert fertige Stände (Spec §3): der erste sofort, danach je `interval`. Dauert eine Messung
/// länger als der Takt, folgt die nächste sofort statt mehrerer aufgestauter. Endet beim Abbruch des Tasks. Je Takt
/// liest sie nur die Quellen, die `selection` gerade vorgibt (#318), und meldet jede Messung an `tap`.
public struct TaskManagerEngine<C: Clock<Duration>>: Sendable {
    private let sources: TaskManagerSources
    private let selection: TaskManagerSourceSelection
    private let interval: TaskManagerInterval
    private let clock: C
    private let failures: SourceFailureLog
    /// Verlauf des vorigen Laufs, der fortgesetzt wird (`TaskManagerModel`).
    private let history: SampleHistory?
    private let tap: (any TaskManagerTap)?

    public init(sources: TaskManagerSources, interval: TaskManagerInterval, clock: C, failures: SourceFailureLog) {
        self.init(sources: sources, selection: TaskManagerSourceSelection(Set(TaskManagerSource.allCases)),
                  interval: interval, clock: clock, failures: failures)
    }

    init(sources: TaskManagerSources, selection: TaskManagerSourceSelection, interval: TaskManagerInterval, clock: C,
         failures: SourceFailureLog, history: SampleHistory? = nil, tap: (any TaskManagerTap)? = nil) {
        self.sources = sources
        self.selection = selection
        self.interval = interval
        self.clock = clock
        self.failures = failures
        self.history = history
        self.tap = tap
    }

    public func run(_ deliver: @Sendable (TaskManagerFrame) -> Void) async {
        tap?.taskManagerDidStart()
        defer { tap?.taskManagerDidStop() }
        var accumulator = TaskManagerAccumulator(interval: interval, history: history)
        var lastMeasurement: C.Instant?
        var deadline = clock.now
        while !Task.isCancelled {
            let readings = await TaskManagerReadings.read(sources.restricted(to: selection.current))
            SamplingTrace.tick(.taskManager)
            failures.note(readings)
            let now = clock.now
            let frame = accumulator.ingest(readings, elapsed: lastMeasurement.map { $0.duration(to: now) })
            tap?.taskManagerDidMeasure(readings, frame: frame)
            deliver(frame)
            lastMeasurement = now
            deadline = max(deadline.advanced(by: interval.duration), clock.now)
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
        }
    }
}
