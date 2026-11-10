import Foundation
import GrantryShared
import os
import Synchronization

/// Zeitpunkte und Zustände des Systems, die der Recorder liest; in Tests ersetzt (keine Wanduhr, #214).
public struct WatchbookEnvironment: Sendable {
    /// Wanduhr für die Zeitpunkte der Punkte und Ereignisse.
    public var now: @Sendable () -> Date
    /// Start des Macs (`kern.boottime`).
    public var bootTime: @Sendable () -> Date?
    /// Grund des letzten Aufwachens (`kern.wakereason`), Rohtext von macOS.
    public var wakeReason: @Sendable () -> String?
    public var currentUID: UInt32

    public init(now: @escaping @Sendable () -> Date, bootTime: @escaping @Sendable () -> Date?,
                wakeReason: @escaping @Sendable () -> String?, currentUID: UInt32) {
        self.now = now
        self.bootTime = bootTime
        self.wakeReason = wakeReason
        self.currentUID = currentUID
    }

    /// Lesen ohne Root, ohne Helper und ohne Prozessstart (`sysctl`).
    public static var system: WatchbookEnvironment {
        WatchbookEnvironment(now: { Date() }, bootTime: { SystemUptime.bootTime().map(SystemUptime.date) },
                             wakeReason: { Sysctl.string("kern.wakereason") }, currentUID: getuid())
    }
}

/// Steuerung des Recorders, wie sie Einstellung und App-Lebenszyklus brauchen (`WatchbookModel`).
public protocol WatchbookRecording: Sendable {
    func setEnabled(_ enabled: Bool) async
    /// Thermischer Zustand und Energiesparmodus nach jedem Wechsel (`ThermalStateSource`); der Recorder fragt sie nie
    /// selbst ab.
    func setThermalCondition(_ condition: ThermalCondition) async
    /// Änderungen aus dem Verlauf als Marken (TM-12.4, `WatchbookJournal.recordChanges`); ausgeschaltet nichts.
    func recordChanges(_ history: [HistoryEvent]) async
    /// Befunde, die nicht aus den Messpunkten des Wachbuchs entstehen (Datenträger, TM-15.5); ausgeschaltet nichts.
    func recordFindings(_ events: [WatchbookEvent]) async
    func systemWillSleep() async
    func systemDidWake() async
    /// Beim Beenden der App: schreibt alles und misst danach nie wieder.
    func shutdown() async
    /// Aufbewahrung und Obergrenze auch ohne neue Punkte einhalten.
    func enforceRetention() async
}

/// Wachbuch-Recorder (Spec 2026-11-08 §5.1, TM-12.3): zeichnet im Hintergrund auf – auch ohne offenes Fenster – und misst
/// nie doppelt.
///
/// - **Eigener Takt:** alle 10 s (`interval`, Toleranz 10 %, QoS `utility`) aus den Quellen `sources` – CPU, Speicher,
///   Schnittstellen, Datenträger, GPU-Zähler, Akku und Prozesse für die größten Verbraucher; ohne Helper, ohne `nettop`,
///   ohne GPU-Arbeit, ohne Prozessstart. Die erste Messung ist Basis; Punkte haben stets Raten über den Abschnitt davor.
/// - **Übernahme:** Läuft der Task-Manager (Fenster oder Menüleisten-Anzeige), meldet er jede Messung über
///   `TaskManagerTap`; der eigene Takt ruht. Etwa alle 10 s wird eine seiner Rohmessungen zum 10-s-Punkt (Raten über
///   denselben Akkumulator wie im eigenen Takt); was er nicht liest (die Menüleiste: Prozesse, GPU, Akku), liest der
///   Recorder dann einmal selbst dazu. Seine schnelleren Takte gehen als volle Auflösung um Befunde ins Wachbuch
///   (`WatchbookResolution`).
/// - **Systemereignisse:** Start, Ruhezustand bis Aufwachen mit Grund, Wechsel von Netzteil, thermischem Zustand,
///   Speicherdruck und Energiesparmodus. Thermik und Energiesparmodus kommen per Wechsel von `ThermalStateSource`
///   (`setThermalCondition`), ohne Abfrage je Takt. Der Ruhezustand ist eine Lücke: Vorher wird geschrieben, danach
///   beginnt die Messung mit einer neuen Basis.
/// - **Leistungsaufnahme** nur, wenn die Sensoren des Helpers ohnehin messen (`sensorsDidMeasure`, TM-14.5): je Punkt
///   das Mittel seines Abschnitts, sonst leer. Der Recorder startet die Sensoren nie selbst.
/// - **Befunde:** nach jedem 10-s-Punkt mit `FindingRules` (`WatchbookFindingLog`), mit Beginn und Ende; schwere melden
///   sich gedrosselt als Mitteilung (`SevereFindingAlerts`, TM-12.8).
/// - **Änderungen** aus dem Verlauf als Marken (`recordChanges`, TM-12.4): beim Einschalten der Nachtrag, danach die
///   neuen Einträge je Scan; schon Geschriebenes wird nicht doppelt geführt.
/// - **Aus** heißt kein Takt, kein Abgriff und keine Datei.
///
/// Eingaben aus dem Messtakt des Task-Managers laufen in Reihenfolge über einen Puffer, den eine einzige Schleife
/// abarbeitet; bleibt sie hängen, entfallen weitere Messungen statt Speicher anzuhäufen – Beginn und Ende seiner Läufe
/// nie.
public actor WatchbookRecorder<C: Clock<Duration>>: TaskManagerTap, WatchbookRecording {
    public static var interval: Duration { .seconds(10) }
    /// 10 % des Takts: Das System darf Wecker bündeln.
    public static var tolerance: Duration { .seconds(1) }
    /// Abstand, ab dem eine Messung des Task-Managers zum nächsten 10-s-Punkt wird (sein Takt schwankt leicht).
    static var takeoverSpacing: Duration { .milliseconds(9_500) }
    /// Größte Zeit seit der vorigen Messung, über die noch Raten entstehen; danach ist die Messung neue Basis.
    static var maximumCoverage: Duration { .seconds(WatchbookPoint.maximumCoverage) }
    /// Kleinerer Abstand zum vorigen Punkt: doppelte Messung beim Taktwechsel, sie wird verworfen.
    static var minimumSpacing: Duration { .seconds(5) }
    /// Höchstens so viele Messungen des Task-Managers warten auf die Schleife; weitere entfallen.
    static var maximumPendingMeasurements: Int { 32 }

    private static var logger: Logger { Logger(subsystem: ManagerKit.logSubsystem, category: "watchbook") }

    private enum Input: Sendable {
        case measured(TaskManagerReadings, TaskManagerFrame, C.Instant, Date)
        case taskManagerChanged
        case barrier(CheckedContinuation<Void, Never>)
    }

    /// Was der Messtakt des Task-Managers ohne Umweg über den Actor braucht.
    private struct Shared {
        var isEnabled = false
        /// Laufende Messungen des Task-Managers; Beginn und Ende zweier Läufe können sich überschneiden.
        var taskManagerRuns = 0
        /// Messungen im Puffer, die die Schleife noch nicht verarbeitet hat.
        var pendingMeasurements = 0
        /// Sensor-Messungen seit dem letzten Punkt.
        var power = WatchbookPowerLog()
    }

    private nonisolated let shared = Mutex(Shared())
    private nonisolated let inputs: AsyncStream<Input>.Continuation
    private nonisolated let clock: C
    private nonisolated let environment: WatchbookEnvironment
    private let stream: AsyncStream<Input>
    private let sources: TaskManagerSources
    private let journal: WatchbookJournal
    private let thresholds: FindingThresholds
    private let failures: SourceFailureLog

    private var isEnabled = false
    private var isAsleep = false
    private var isShutDown = false
    /// Wechselt bei jedem Ein-, Ausschalten und Ruhezustand: Eine Messung, die davor begann, wird verworfen.
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var ownTakt: Task<Void, Never>?
    private var accumulator = TaskManagerAccumulator.withoutHistory()
    private var lastBase: C.Instant?
    private var resolution: WatchbookResolution
    private var findings: WatchbookFindingLog
    private var alerts: SevereFindingAlerts?
    private var systemState = WatchbookSystemState()
    /// Letzter gemeldeter Stand; `nil`, bis `ThermalStateSource` ihn meldet.
    private var thermal: ThermalCondition?
    private var sleepStart: Date?
    /// Letzter Fehler beim Schreiben; `nil` nach Erfolg.
    public private(set) var lastError: String?

    public init(store: WatchbookStore, sources: TaskManagerSources = .watchbook, clock: C,
                environment: WatchbookEnvironment = .system, thresholds: FindingThresholds = .standard,
                failures: SourceFailureLog = SourceFailureLog(), alerts: SevereFindingAlerts? = nil) {
        (stream, inputs) = AsyncStream.makeStream(of: Input.self)
        journal = WatchbookJournal(store: store)
        self.sources = sources
        self.clock = clock
        self.environment = environment
        self.thresholds = thresholds
        self.failures = failures
        resolution = WatchbookResolution(thresholds: thresholds)
        findings = WatchbookFindingLog(thresholds: thresholds)
        self.alerts = alerts
    }

    deinit {
        inputs.finish()
        ownTakt?.cancel()
    }

    /// Ob der eigene 10-s-Takt läuft.
    var isTicking: Bool { ownTakt != nil }

    /// Was beim letzten Schreiben und der letzten Wartung nicht wie vorgesehen ging (`WatchbookJournal.problems`).
    public var problems: [WatchbookProblem] { journal.problems }

    // MARK: Steuerung

    public func setEnabled(_ enabled: Bool) {
        guard !isShutDown, enabled != isEnabled else { return }
        isEnabled = enabled
        shared.withLock { shared in
            shared.isEnabled = enabled
            shared.power = WatchbookPowerLog()
        }
        generation += 1
        if enabled {
            startLoopIfNeeded()
            recordBoot()
            updateTakt()
        } else {
            stopTakt()
            finish()
        }
    }

    public func setThermalCondition(_ condition: ThermalCondition) {
        thermal = condition
    }

    public func recordChanges(_ history: [HistoryEvent]) {
        guard isEnabled, !history.isEmpty else { return }
        do {
            try journal.recordChanges(history, currentUID: environment.currentUID, now: environment.now())
        } catch {
            note(error)
        }
    }

    public func recordFindings(_ events: [WatchbookEvent]) {
        guard isEnabled, !events.isEmpty else { return }
        write([], events, at: environment.now())
    }

    public func systemWillSleep() {
        guard isEnabled, !isAsleep else { return }
        isAsleep = true
        generation += 1
        stopTakt()
        let now = environment.now()
        sleepStart = now
        resolution.dropFrames()
        write(resolution.releaseAll(findings: findings.findings), [], at: now)
        flushJournal(at: now)
    }

    public func systemDidWake() {
        guard isEnabled else { return }
        isAsleep = false
        generation += 1
        let now = environment.now()
        var events = sleepStart.map { [WatchbookSystemEvent.sleep(from: $0, to: now)] } ?? []
        events.append(WatchbookSystemEvent.wake(at: now, reason: environment.wakeReason()))
        sleepStart = nil
        // Nichts über den Ruhezustand hinweg verrechnen: Die nächste Messung ist Basis.
        accumulator = .withoutHistory()
        lastBase = nil
        write([], events, at: now)
        updateTakt()
    }

    public func shutdown() {
        guard !isShutDown else { return }
        if isEnabled {
            stopTakt()
            finish()
        }
        isShutDown = true
        isEnabled = false
        shared.withLock { $0.isEnabled = false }
        generation += 1
        inputs.finish()
    }

    /// Schreibt den Puffer des Journals; zurückgehaltene Abschnitte (`WatchbookResolution`) bleiben, bis sie
    /// entschieden sind.
    public func flush() {
        flushJournal(at: environment.now())
    }

    public func enforceRetention() {
        do {
            try journal.store.maintain(now: environment.now())
        } catch {
            note(error)
        }
    }

    /// Verdichtete Reihe einschließlich noch nicht geschriebener und zurückgehaltener Punkte (`WatchbookStore.series`).
    public func series(_ period: WatchbookPeriod, endingAt end: Date, width: Int) -> WatchbookSeries {
        journal.store.series(period, endingAt: end, width: width,
                             pendingPoints: journal.pendingPoints + resolution.heldPoints,
                             pendingEvents: journal.pendingEvents)
    }

    /// Verbraucher um `time` einschließlich noch nicht geschriebener und zurückgehaltener Punkte
    /// (`WatchbookStore.consumers`).
    public func consumers(near time: Date, within window: TimeInterval) -> WatchbookConsumers? {
        journal.store.consumers(near: time, within: window,
                                pendingPoints: journal.pendingPoints + resolution.heldPoints)
    }

    /// „Wachbuch löschen“: alle Dateien und alles, was noch nicht geschrieben ist; die Aufzeichnung läuft weiter.
    public func removeAll() throws {
        resolution = WatchbookResolution(thresholds: thresholds)
        findings = WatchbookFindingLog(thresholds: thresholds)
        try journal.remove()
    }

    /// Wartet, bis alle bisher eingegangenen Messungen des Task-Managers verarbeitet sind (Tests).
    func settle() async {
        startLoopIfNeeded()
        await withCheckedContinuation { continuation in
            if case .terminated = inputs.yield(.barrier(continuation)) { continuation.resume() }
        }
    }

    // MARK: Abgriff des Task-Managers (`TaskManagerTap`)

    public nonisolated func taskManagerDidStart() {
        shared.withLock { $0.taskManagerRuns += 1 }
        inputs.yield(.taskManagerChanged)
    }

    public nonisolated func taskManagerDidMeasure(_ readings: TaskManagerReadings, frame: TaskManagerFrame) {
        let accepted = shared.withLock { shared in
            guard shared.isEnabled, shared.pendingMeasurements < Self.maximumPendingMeasurements else { return false }
            shared.pendingMeasurements += 1
            return true
        }
        guard accepted else { return }
        inputs.yield(.measured(readings, frame, clock.now, environment.now()))
    }

    // MARK: Sensoren des Helpers

    /// Eine Messung der Sensoren (`SensorModel.onReading`, alle 2 s, nur während Leistung, Chip oder Übersicht
    /// sichtbar ist); ausgeschaltet oder ohne Leistungswert nichts. Ohne Umweg über den Actor.
    public nonisolated func sensorsDidMeasure(_ reading: SensorReading?) {
        guard let power = reading.flatMap(WatchbookPower.init) else { return }
        let now = environment.now()
        shared.withLock { shared in
            guard shared.isEnabled else { return }
            shared.power.record(power, at: now)
        }
    }

    public nonisolated func taskManagerDidStop() {
        shared.withLock { $0.taskManagerRuns -= 1 }
        inputs.yield(.taskManagerChanged)
    }

    // MARK: Takt

    private func startLoopIfNeeded() {
        guard loop == nil, !isShutDown else { return }
        let stream = stream
        loop = Task(priority: .utility) { [weak self] in
            for await input in stream {
                guard let self else { return }
                await self.handle(input)
            }
        }
    }

    private func handle(_ input: Input) async {
        switch input {
        case .taskManagerChanged:
            updateTakt()
        case .barrier(let continuation):
            continuation.resume()
        case .measured(let readings, let frame, let instant, let date):
            shared.withLock { $0.pendingMeasurements -= 1 }
            await takeOver(readings, frame: frame, at: instant, date: date)
        }
    }

    /// Eigener Takt nur, solange eingeschaltet, wach und ohne laufenden Task-Manager.
    private func updateTakt() {
        let taskManagerRuns = shared.withLock { $0.taskManagerRuns }
        if isEnabled, !isAsleep, taskManagerRuns <= 0 {
            startTakt()
        } else {
            stopTakt()
        }
    }

    /// Erste Messung im Raster des letzten Punkts, ohne Vorgänger sofort (Basis).
    private func startTakt() {
        guard ownTakt == nil else { return }
        let generation = generation, clock = clock
        let first = lastBase.map { $0.advanced(by: Self.interval) } ?? clock.now
        ownTakt = Task(priority: .utility) { [weak self] in
            var deadline = first
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: deadline, tolerance: Self.tolerance)
                } catch {
                    return
                }
                guard let self else { return }
                await self.measure(generation: generation)
                deadline = max(deadline.advanced(by: Self.interval), clock.now)
            }
        }
    }

    private func stopTakt() {
        ownTakt?.cancel()
        ownTakt = nil
    }

    /// Ein Takt aus den eigenen Quellen.
    private func measure(generation: Int) async {
        guard isCurrent(generation) else { return }
        let readings = await TaskManagerReadings.readSequentially(sources)
        SamplingTrace.tick(.watchbook)
        failures.note(readings)
        guard isCurrent(generation) else { return }
        ingestBase(readings, at: clock.now, date: environment.now())
    }

    /// Eine Messung des Task-Managers: als volle Auflösung und alle 10 s als Punkt, ergänzt um die Quellen, die er
    /// gerade nicht liest.
    private func takeOver(_ readings: TaskManagerReadings, frame: TaskManagerFrame, at instant: C.Instant,
                          date: Date) async {
        guard isEnabled, !isAsleep else { return }
        if let elapsed = frame.elapsed, elapsed <= Self.maximumCoverage {
            let power = shared.withLock { $0.power.latest(at: date) }
            resolution.addFrame(point(frame.snapshot, at: date, power: power))
        }
        guard lastBase.map({ $0.duration(to: instant) >= Self.takeoverSpacing }) ?? true else { return }
        let generation = generation
        let missing = sources.configured.subtracting(readings.measuredSources)
        var complete = readings
        if !missing.isEmpty {
            let supplement = await TaskManagerReadings.readSequentially(sources.restricted(to: missing))
            failures.note(supplement)
            complete.fill(from: supplement)
        }
        guard isCurrent(generation) else { return }
        ingestBase(complete, at: instant, date: date)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && isEnabled && !isAsleep
    }

    // MARK: Punkte, Befunde, Ereignisse

    /// Macht aus einer Rohmessung den 10-s-Punkt, wertet die Befunde aus und erkennt Zustandswechsel.
    private func ingestBase(_ readings: TaskManagerReadings, at instant: C.Instant, date: Date) {
        let elapsed = lastBase.map { $0.duration(to: instant) }
        if let elapsed, elapsed < Self.minimumSpacing { return }
        let usable = elapsed.flatMap { $0 <= Self.maximumCoverage ? $0 : nil }
        let frame = accumulator.ingest(readings, elapsed: usable)
        let power = shared.withLock { $0.power.section(endingAt: date) }
        lastBase = instant
        guard usable != nil else {
            // Neue Basis nach einer Lücke: Takte davor gehören zu keinem Abschnitt.
            resolution.dropFrames()
            return
        }
        let point = point(frame.snapshot, at: date, power: power)
        let processes = ProcessLoadSample(time: date, snapshot: frame.snapshot, currentUID: environment.currentUID,
                                          above: thresholds.processLoad.limit)
        var events = findings.record(point, processes: processes)
        alerts?.review(findings.findings, at: date)
        let state = WatchbookSystemState(point: point, isLowPowerModeEnabled: thermal?.isLowPowerModeEnabled)
        events += state.changes(since: systemState, at: date)
        systemState = state.merged(over: systemState)
        resolution.addBase(point)
        write(resolution.release(now: date, findings: findings.findings), events, at: date)
    }

    private func point(_ snapshot: TaskManagerSnapshot, at date: Date, power: WatchbookPower?) -> WatchbookPoint {
        WatchbookPoint(time: date, snapshot: snapshot, currentUID: environment.currentUID,
                       thermalState: thermal?.state, power: power)
    }

    /// Start des Macs, sofern er in die Aufbewahrung fällt; derselbe Start ersetzt nur sich selbst.
    private func recordBoot() {
        let now = environment.now()
        guard let boot = environment.bootTime(), boot <= now,
              boot > now.addingTimeInterval(-WatchbookStore.retention) else { return }
        write([], [WatchbookSystemEvent.boot(at: boot)], at: now)
    }

    /// Ausschalten oder Beenden: laufende Befunde enden, alles Zurückgehaltene wird entschieden und geschrieben; danach
    /// beginnt die Messung von vorn.
    private func finish() {
        let now = environment.now()
        let current = findings.findings
        let ended = findings.closeAll()
        write(resolution.releaseAll(findings: current), ended, at: now)
        flushJournal(at: now)
        resolution = WatchbookResolution(thresholds: thresholds)
        accumulator = .withoutHistory()
        lastBase = nil
        systemState = WatchbookSystemState()
        sleepStart = nil
    }

    // MARK: Schreiben

    /// Übergibt an das Journal; es schreibt gebündelt höchstens alle 60 s. Ein Fehler betrifft nur den Eintrag, bei dem
    /// er auftritt – das Journal behält ihn für den nächsten Versuch.
    private func write(_ points: [WatchbookPoint], _ events: [WatchbookEvent], at now: Date) {
        for event in events {
            do { try journal.record(event, now: now) } catch { note(error) }
        }
        for point in points {
            do { try journal.record(point, now: now) } catch { note(error) }
        }
    }

    private func flushJournal(at now: Date) {
        do {
            try journal.flush(now: now)
            lastError = nil
        } catch {
            note(error)
        }
    }

    /// Merkt sich den Fehler und protokolliert ihn einmal, solange er sich nicht ändert.
    private func note(_ error: any Error) {
        let description = error.readableDescription
        guard description != lastError else { return }
        lastError = description
        Self.logger.error("Wachbuch nicht geschrieben: \(description, privacy: .public)")
    }
}

extension TaskManagerReadings {
    /// Quellen mit einem Ergebnis in dieser Messung (auch ausgefallene).
    var measuredSources: Set<TaskManagerSource> {
        let present: [(TaskManagerSource, Bool)] = [
            (.processes, processes != nil), (.cpu, cpu != nil), (.memory, memory != nil), (.disks, disks != nil),
            (.interfaces, interfaces != nil), (.gpu, gpu != nil), (.battery, battery != nil),
        ]
        return Set(present.filter(\.1).map(\.0))
    }

    /// Ergänzt Quellen ohne Ergebnis aus `other`.
    mutating func fill(from other: TaskManagerReadings) {
        processes = processes ?? other.processes
        cpu = cpu ?? other.cpu
        memory = memory ?? other.memory
        disks = disks ?? other.disks
        interfaces = interfaces ?? other.interfaces
        gpu = gpu ?? other.gpu
        battery = battery ?? other.battery
    }
}
