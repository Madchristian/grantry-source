import Foundation
import Observation

/// Zustand des Bereichs „Task-Manager“ (Spec 2026-11-06 §2, §3): misst nur, solange ein Abnehmer da ist (Fenster über
/// `measuresWhileVisible`, Menüleisten-Anzeige über `TaskManagerMenuBarModel`), und liest nur die Quellen, die die
/// aktiven Abnehmer brauchen (`Consumer.sources`); kommt einer dazu oder geht, läuft dieselbe Messung mit angepasster
/// Auswahl weiter. Die Engine läuft außerhalb des Main Actors; hier kommen nur
/// fertige Stände (`TaskManagerFrame`) an. `stop()` kehrt sofort zurück, `stopAndWait()` wartet beim Beenden der App,
/// bis kein Lauf mehr misst. Ein neuer Lauf mit demselben Takt setzt den Verlauf fort und trägt die Pause als Lücke ein
/// (Bewertung 2026.11.7, Mangel 7: nach dem Verdecken begannen die Graphen leer); ein anderer Takt beginnt leer. Das Fenster
/// liest `frame`, das nur ihm folgt; die Menüleiste liest `latestFrame`.
@MainActor
@Observable
public final class TaskManagerModel {
    public enum Consumer: Hashable, Sendable {
        /// `menuBarPopover`: das offene Popover der Übersicht (#495), das zusätzlich Prozesse, GPU und Akku liest.
        case window, menuBar, menuBarPopover
    }

    /// Stand für das Fenster: folgt dem Takt nur, solange der Abnehmer `.window` misst (`measuresWhileVisible`). Ein
    /// geschlossenes oder verdecktes Fenster bleibt so still, auch wenn die Menüleiste weiter misst (Bewertung
    /// 2026.11.9/1510, Mangel 2b: seine Ansichten rechneten und zeichneten sonst je Takt weiter); kommt es zurück, zeigt
    /// es sofort den jüngsten Stand.
    public private(set) var frame = TaskManagerFrame.empty(interval: .default)
    /// Ankunft von `frame`; Zeitbezug der Graphen. `distantPast`, solange noch kein Stand kam.
    public private(set) var frameDate = Date.distantPast
    /// Jüngster Stand für jeden Abnehmer, etwa die Menüleiste.
    public private(set) var latestFrame = TaskManagerFrame.empty(interval: .default)
    /// Ankunft von `latestFrame`.
    public private(set) var latestFrameDate = Date.distantPast
    public private(set) var isRunning = false
    /// Laufende Befunde für Lage- und Zustandszeile, einmal je Takt mit `FindingRules` ermittelt (`FindingTracker`).
    public private(set) var findings: [SystemFinding] = []
    /// Thermischer Zustand und Energiesparmodus; jeder Takt trägt ihren Stand (`TaskManagerSnapshot.thermal`).
    public let thermal: ThermalStateSource
    public static let intervalStorageKey = "taskManager.interval"

    /// Messtakt für Fenster und Menüleiste (TM17, E2); eine Änderung startet eine laufende Messung neu und wird mit
    /// `settings` gespeichert.
    public var interval = TaskManagerInterval.default {
        didSet {
            guard interval != oldValue else { return }
            settings?.set(interval.rawValue, forKey: Self.intervalStorageKey)
            if run != nil { restart() }
        }
    }

    /// Eingerichtete Quellen; Kacheln fehlender Quellen blendet die Oberfläche aus.
    public var configuredSources: Set<TaskManagerSource> { sources.configured }
    /// Nach jedem angekommenen Stand, etwa für den App-Verlauf (`AppUsageModel.record`).
    @ObservationIgnored public var onFrame: (@MainActor (TaskManagerFrame) -> Void)?
    /// Sieht jeden Lauf und jede Messung außerhalb des Main Actors, etwa das Wachbuch (TM-12.3), das dann nicht selbst
    /// misst. Gilt ab dem nächsten Lauf.
    @ObservationIgnored public var tap: (any TaskManagerTap)?

    private struct Run {
        let generation: Int
        let producer: Task<Void, Never>
        /// Endet erst nach `producer`.
        let consumer: Task<Void, Never>
    }

    @ObservationIgnored private let sources: TaskManagerSources
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let failures: SourceFailureLog
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let currentUID: UInt32
    @ObservationIgnored private var tracker = FindingTracker()
    @ObservationIgnored private let settings: (any SettingsStore)?
    /// Aktive Abnehmer mit den Quellen, die sie brauchen.
    @ObservationIgnored private var consumers: [Consumer: Set<TaskManagerSource>] = [:] {
        didSet { selection.select(consumers.values.reduce(into: []) { $0.formUnion($1) }) }
    }
    /// Quellen der aktiven Abnehmer; die laufende Engine liest sie je Takt.
    @ObservationIgnored private let selection = TaskManagerSourceSelection([])
    @ObservationIgnored private var run: Run?
    /// Beendete Läufe, die noch auslaufen, nach Generation; jeder trägt sich am Ende selbst aus.
    @ObservationIgnored private var stopping: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0

    public init(sources: TaskManagerSources = .system, clock: any Clock<Duration> = ContinuousClock(),
                failures: SourceFailureLog = SourceFailureLog(), now: @escaping @Sendable () -> Date = { Date() },
                thermal: ThermalStateSource = ThermalStateSource(), currentUID: UInt32 = getuid(),
                settings: (any SettingsStore)? = nil) {
        self.sources = sources
        self.clock = clock
        self.failures = failures
        self.now = now
        self.thermal = thermal
        self.currentUID = currentUID
        self.settings = settings
        if let stored = settings?.object(forKey: Self.intervalStorageKey) as? String,
           let interval = TaskManagerInterval(rawValue: stored) {
            self.interval = interval
        }
    }

    isolated deinit {
        run?.producer.cancel()
    }

    /// Misst für `consumer` mit `sources` (ohne Angabe `Consumer.sources`); ein erneuter Aufruf ändert nur die Auswahl,
    /// die laufende Messung und ihr Verlauf bleiben.
    public func start(for consumer: Consumer, sources: Set<TaskManagerSource>? = nil) {
        consumers[consumer] = sources ?? consumer.sources
        startIfNeeded()
        if consumer == .window { publishToWindow() }
    }

    public func stop(for consumer: Consumer) {
        consumers[consumer] = nil
        if consumers.isEmpty { stopRun() }
    }

    /// Quellen, die der laufende Takt liest.
    var selectedSources: Set<TaskManagerSource> { selection.current }

    /// Beendet jede Messung und wartet, bis alle Läufe ausgelaufen sind.
    public func stopAndWait() async {
        consumers.removeAll()
        stopRun()
        for task in Array(stopping.values) { await task.value }
    }

    private func startIfNeeded() {
        guard run == nil else { return }
        generation += 1
        let generation = generation
        let history = continuedHistory(at: now())
        latestFrame = TaskManagerFrame(snapshot: TaskManagerSnapshot(), history: history)
        publishToWindow()
        isRunning = true
        let (frames, continuation) = AsyncStream.makeStream(of: TaskManagerFrame.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let sources = sources, selection = selection, interval = interval, clock = clock, failures = failures, tap = tap
        let producer = Task.detached {
            await Self.measure(sources: sources, selection: selection, interval: interval, clock: clock,
                               failures: failures, history: history, tap: tap) {
                continuation.yield($0)
            }
            continuation.finish()
        }
        let consumer = Task { [weak self] in
            for await frame in frames { self?.apply(frame, generation: generation) }
            await producer.value
            self?.runEnded(generation)
        }
        run = Run(generation: generation, producer: producer, consumer: consumer)
    }

    /// Verlauf des letzten Laufs mit einer Lücke für die Pause bis `date`; leer beim ersten Lauf oder anderem Takt.
    private func continuedHistory(at date: Date) -> SampleHistory {
        guard latestFrameDate != .distantPast, latestFrame.history.interval == interval.duration else {
            return SampleHistory(interval: interval.duration)
        }
        var history = latestFrame.history
        let seconds = Double(interval.duration.components.seconds)
            + Double(interval.duration.components.attoseconds) / 1e18
        let missed = Int((date.timeIntervalSince(latestFrameDate) / seconds).rounded(.down)) - 1
        history.recordGap(max(missed, 0))
        return history
    }

    private nonisolated static func measure<C: Clock<Duration>>(
        sources: TaskManagerSources, selection: TaskManagerSourceSelection, interval: TaskManagerInterval, clock: C,
        failures: SourceFailureLog, history: SampleHistory, tap: (any TaskManagerTap)?,
        deliver: @Sendable (TaskManagerFrame) -> Void
    ) async {
        await TaskManagerEngine(sources: sources, selection: selection, interval: interval, clock: clock,
                                failures: failures, history: history, tap: tap).run(deliver)
    }

    private func stopRun() {
        guard let run else { return }
        run.producer.cancel()
        stopping[run.generation] = run.consumer
        self.run = nil
        isRunning = false
    }

    private func restart() {
        stopRun()
        startIfNeeded()
    }

    /// Wertet eine Sensor-Messung des Helpers für die Regel „Drosselung“ aus (`SensorModel.onReading`), nur während
    /// gemessen wird; `nil` heißt, der Helper lieferte nichts.
    public func record(sensors reading: SensorReading?) {
        guard run != nil else { return }
        tracker.record(ThrottlingSample(time: now(), sensors: reading, thermalState: thermal.current.state))
        publishFindings()
    }

    /// Datenträger-Befunde aus dem Volume-Inventar einer Prüfung nach dem Scan (`VolumeFindingCheck`); gelten auch,
    /// solange nicht gemessen wird.
    public func record(volumes inventory: VolumeInventory, at time: Date) {
        tracker.record(inventory, at: time)
        publishFindings()
    }

    private func apply(_ frame: TaskManagerFrame, generation: Int) {
        guard run?.generation == generation else { return }
        var frame = frame
        frame.snapshot.thermal = thermal.current
        latestFrame = frame
        latestFrameDate = now()
        publishToWindow()
        tracker.record(frame.snapshot, at: latestFrameDate, thermalState: thermal.current.state, currentUID: currentUID)
        publishFindings()
        onFrame?(frame)
    }

    /// Reicht den jüngsten Stand an das Fenster weiter, solange es misst.
    private func publishToWindow() {
        guard consumers[.window] != nil else { return }
        frame = latestFrame
        frameDate = latestFrameDate
    }

    private func publishFindings() {
        if tracker.findings != findings { findings = tracker.findings }
    }

    private func runEnded(_ generation: Int) {
        stopping[generation] = nil
    }
}
