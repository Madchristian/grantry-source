import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Wachbuch-Recorder (TM-12.3) mit Fake-Quellen und Fake-Uhr: Takt, Ruhezustand, Übernahme aus dem Task-Manager ohne
/// Doppelmessung, Umschalten, Beginn und Ende von Befunden.
@Suite(.timeLimit(.minutes(1))) struct WatchbookRecorderTests {
    /// CPU mit einstellbarer Last: Jeder Aufruf zählt 100 Ticks weiter, davon `load` belegt.
    final class LoadCPU: MetricSource {
        private let state = Mutex((load: 0.25, busy: UInt64(0), idle: UInt64(0), calls: 0))

        var calls: Int { state.withLock { $0.calls } }

        func set(load: Double) { state.withLock { $0.load = load } }

        func read() throws -> CPULoadReading {
            state.withLock { $0.calls += 1 }
            return ticks()
        }

        /// Dieselben Kernzähler, ohne als eigene Messung des Wachbuchs zu zählen – so liest sie der Task-Manager.
        func ticks() -> CPULoadReading {
            state.withLock { state in
                state.busy += UInt64((state.load * 100).rounded())
                state.idle += UInt64(((1 - state.load) * 100).rounded())
                return CPULoadReading(cores: [CoreTicks(kind: .performance, busy: state.busy, idle: state.idle)])
            }
        }
    }

    /// Quelle mit einstellbarem Wert.
    final class Settable<Reading: Sendable>: MetricSource {
        private let state: Mutex<(value: Reading, calls: Int)>

        init(_ value: Reading) { state = Mutex((value, 0)) }

        var calls: Int { state.withLock { $0.calls } }

        func set(_ value: Reading) { state.withLock { $0.value = value } }

        func read() throws -> Reading {
            state.withLock { state in
                state.calls += 1
                return state.value
            }
        }
    }

    static let memory = MemoryStatus(physicalBytes: 16 << 30, usedBytes: 8 << 30, swapUsedBytes: 0,
                                     swapTotalBytes: 0, pressure: .normal, processCount: 1)

    /// Ein Recorder mit eigener Ablage, Fake-Quellen und einer Wanduhr, die mit der `TestClock` läuft.
    final class Setup: Sendable {
        let clock = TestClock()
        let start = WatchbookFixtures.dayStart.addingTimeInterval(12 * 3_600)
        let cpu = LoadCPU()
        let memory = Settable(WatchbookRecorderTests.memory)
        let processes = Settable<[ProcessCounters]>([])
        let battery = Settable(BatteryReading(charge: 0.8, source: .externalPower))
        let store: WatchbookStore
        let recorder: WatchbookRecorder<TestClock>

        init(directory: URL, boot: Date? = nil, wakeReason: String? = "rtc", alerts: SevereFindingAlerts? = nil) {
            store = WatchbookStore(directory: directory.appending(path: "Watchbook"))
            let clock = clock, start = start
            let environment = WatchbookEnvironment(
                now: { start.addingTimeInterval(Double(clock.now.offset.components.seconds)) }, bootTime: { boot },
                wakeReason: { wakeReason }, currentUID: WatchbookFixtures.currentUID)
            recorder = WatchbookRecorder(
                store: store,
                sources: TaskManagerSources(processes: processes, cpu: cpu, memory: memory, battery: battery),
                clock: clock, environment: environment, failures: SourceFailureLog(report: { _, _ in }),
                alerts: alerts)
        }

        func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        /// Stellt die Uhr Takt für Takt vor; `ticks` eigene 10-s-Takte ab der Frist `from`.
        func tick(_ ticks: Int, from seconds: Int) async {
            for index in 0..<ticks {
                let deadline = seconds + index * 10
                await clock.waitForSleeper(until: .at(.seconds(deadline)))
                clock.advance(by: .seconds(deadline) - clock.now.offset)
            }
            await clock.waitForSleeper(until: .at(.seconds(seconds + ticks * 10)))
        }

        func records() async -> WatchbookRecords {
            await recorder.flush()
            return store.records(in: Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 4_000_000_000))
        }

        func points() async -> [Date] { await records().points.map(\.time) }

        /// Beendet den Recorder (schreibt auch zurückgehaltene Abschnitte) und liest alles.
        func finish() async -> WatchbookRecords {
            await recorder.shutdown()
            return await records()
        }

        func events(of kind: WatchbookEvent.Kind) async -> [WatchbookEvent] {
            await records().events.filter { $0.kind == kind }
        }
    }

    private func withSetup(boot: Date? = nil, _ body: (Setup) async throws -> Void) async throws {
        try await ScratchDirectory.withCanonical(prefix: "watchbook-recorder") { directory in
            let setup = Setup(directory: directory, boot: boot)
            try await body(setup)
            await setup.recorder.shutdown()
        }
    }

    // MARK: Takt

    @Test func measuresEveryTenSecondsAfterABaseline() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(3, from: 10)
            #expect(setup.cpu.calls == 4)
            #expect(await setup.points() == [setup.time(10), setup.time(20), setup.time(30)])
            #expect(await setup.records().points.first?.values[.cpuTotal] == 0.25)
            #expect(WatchbookRecorder<TestClock>.tolerance == .seconds(1))
        }
    }

    /// Aus heißt kein Takt und keine Datei.
    @Test func offMeansNoTaktAndNoFile() async throws {
        try await withSetup { setup in
            #expect(setup.clock.advance(by: .seconds(60)) == 0)
            #expect(setup.cpu.calls == 0)
            await setup.recorder.flush()
            #expect(!FileManager.default.fileExists(atPath: setup.store.directory.path))
        }
    }

    /// Ausschalten beendet den Takt und schreibt, was bis dahin gemessen wurde.
    @Test func switchingOffStopsTheTaktAndWritesWhatWasMeasured() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(2, from: 10)
            await setup.recorder.setEnabled(false)
            #expect(setup.clock.advance(by: .seconds(60)) == 0)
            #expect(setup.cpu.calls == 3)
            #expect(setup.store.records(in: setup.time(0)..<setup.time(100)).points.count == 2)
        }
    }

    // MARK: Ruhezustand

    @Test func sleepIsAGapWithSleepAndWakeEvents() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(2, from: 10)
            await setup.recorder.systemWillSleep()
            // Geschrieben vor dem Ruhezustand.
            #expect(setup.store.records(in: setup.time(0)..<setup.time(100)).points.count == 2)
            #expect(setup.clock.advance(by: .seconds(3_600)) == 0)
            #expect(setup.cpu.calls == 3)

            await setup.recorder.systemDidWake()
            await setup.tick(1, from: 3_630)
            #expect(setup.cpu.calls == 5)
            #expect(await setup.points() == [setup.time(10), setup.time(20), setup.time(3_630)])
            let system = await setup.events(of: .system)
            #expect(system.map(\.type) == ["system.sleep", "system.wake"])
            #expect(system.first?.start == setup.time(20) && system.first?.end == setup.time(3_620))
            #expect(system.last?.summary == "Aufgewacht, Grund laut macOS: rtc.")
        }
    }

    // MARK: Befunde von außen

    /// Datenträger-Befunde (TM-15.5) gehen als Ereignisse ins Wachbuch; ein späterer Eintrag mit derselben ID (Ende)
    /// ersetzt den laufenden. Ausgeschaltet wird nichts geschrieben.
    @Test func recordsFindingsFromOutside() async throws {
        try await withSetup { setup in
            let inventory = VolumeInventory(devices: [StorageDevice(id: "disk4", name: "Extern", smartStatus: .failing)],
                                            localSnapshots: nil, isComplete: true)
            let finding = FindingRules.storageFindings(in: inventory, at: setup.time(5))[0]
            await setup.recorder.recordFindings([finding.watchbookEvent])
            #expect(await setup.events(of: .finding).isEmpty)
            await setup.recorder.setEnabled(true)
            await setup.recorder.recordFindings([finding.watchbookEvent])
            let ended = FindingRules.storageChanges(from: [finding], to: [], at: setup.time(50))
            await setup.recorder.recordFindings(ended.map(\.watchbookEvent))
            let events = await setup.events(of: .finding).filter { $0.type == "storage.smart" }
            #expect(events.map(\.id) == [finding.id])
            #expect(events.first?.end == setup.time(50))
            #expect(events.first?.tone == .critical)
        }
    }

    // MARK: Übernahme aus dem Task-Manager

    /// Läuft der Task-Manager, ruht der eigene Takt: Das Wachbuch nimmt dessen Messungen und liest nichts selbst.
    @Test func takesOverTheTaskManagerWithoutMeasuringTwice() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            let ownCalls = (setup.cpu.calls, setup.memory.calls, setup.processes.calls, setup.battery.calls)
            setup.recorder.taskManagerDidStart()
            await setup.recorder.settle()
            // Die Frist des eigenen Takts (20 s) verstreicht, ohne dass er misst.
            #expect(setup.clock.advance(by: .seconds(10)) == 0)

            let feed = TaskManagerFeed(setup: setup)
            for _ in 0..<20 { await feed.measure(advancing: .seconds(1)) }
            #expect((setup.cpu.calls, setup.memory.calls, setup.processes.calls, setup.battery.calls) == ownCalls)
            setup.recorder.taskManagerDidStop()
            let points = await setup.finish().points
            #expect(points.map(\.time) == [10, 21, 31].map { setup.time($0) })
            #expect(points.allSatisfy { $0.values[.cpuTotal] == 0.25 })
            #expect((setup.cpu.calls, setup.memory.calls, setup.processes.calls, setup.battery.calls) == ownCalls)
        }
    }

    /// Die Menüleisten-Anzeige liest weder Prozesse noch Akku: Nur diese Quellen ergänzt das Wachbuch, einmal je 10 s.
    @Test func menuBarTakeoverReadsOnlyTheMissingSources() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            setup.recorder.taskManagerDidStart()
            await setup.recorder.settle()
            let feed = TaskManagerFeed(setup: setup, sources: TaskManagerModel.Consumer.menuBar.sources)
            for _ in 0..<20 { await feed.measure(advancing: .seconds(1)) }
            #expect(setup.cpu.calls == 2)
            #expect(setup.memory.calls == 2)
            #expect(setup.processes.calls == 4)
            #expect(setup.battery.calls == 4)
            setup.recorder.taskManagerDidStop()
            let points = await setup.finish().points
            #expect(points.map(\.time) == [10, 20, 30].map { setup.time($0) })
            #expect(points.allSatisfy { $0.values[.externalPower] == 1 })
        }
    }

    /// Nach dem Task-Manager misst das Wachbuch wieder selbst, im Raster des letzten Punkts – ohne Lücke.
    @Test func switchingBackResumesTheOwnTaktWithoutGap() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            setup.recorder.taskManagerDidStart()
            await setup.recorder.settle()
            let feed = TaskManagerFeed(setup: setup)
            for _ in 0..<15 { await feed.measure(advancing: .seconds(1)) }
            setup.recorder.taskManagerDidStop()
            await setup.recorder.settle()
            let calls = setup.cpu.calls
            await setup.tick(2, from: 30)
            #expect(setup.cpu.calls == calls + 2)
            let points = await setup.finish().points
            #expect(points.map(\.time) == [10, 20, 30, 40].map { setup.time($0) })
            #expect(points.allSatisfy { $0.values[.cpuTotal] == 0.25 })
        }
    }

    /// Ausgeschaltet nimmt das Wachbuch auch vom Task-Manager nichts an; eingeschaltet ruht dann sofort sein Takt.
    @Test func ignoresTaskManagerMeasurementsWhileOff() async throws {
        try await withSetup { setup in
            setup.recorder.taskManagerDidStart()
            let feed = TaskManagerFeed(setup: setup)
            for _ in 0..<12 { await feed.measure(advancing: .seconds(1)) }
            await setup.recorder.setEnabled(true)
            #expect(!(await setup.recorder.isTicking))
            #expect(setup.cpu.calls == 0)
            setup.recorder.taskManagerDidStop()
            let records = await setup.finish()
            #expect(records.points.isEmpty)
        }
    }

    /// Ein Laufbeginn überlappt beim Taktwechsel das Ende des vorigen Laufs: Der eigene Takt bleibt aus.
    @Test func overlappingRunsKeepTheOwnTaktResting() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            setup.recorder.taskManagerDidStart()
            setup.recorder.taskManagerDidStart()
            setup.recorder.taskManagerDidStop()
            await setup.recorder.settle()
            #expect(setup.clock.advance(by: .seconds(20)) == 0)
            setup.recorder.taskManagerDidStop()
            await setup.recorder.settle()
            #expect(await setup.recorder.isTicking)
        }
    }

    // MARK: Befunde

    @Test func recordsBeginAndEndOfFindings() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            setup.cpu.set(load: 0.95)
            await setup.tick(18, from: 10)
            var findings = await setup.events(of: .finding)
            #expect(findings.map(\.type) == [SystemFinding.Kind.systemLoad.rawValue])
            #expect(findings.first?.start == setup.time(10))
            #expect(findings.first?.end == nil)

            setup.cpu.set(load: 0.1)
            await setup.tick(8, from: 190)
            findings = await setup.events(of: .finding)
            #expect(findings.count == 1)
            #expect(findings.first?.start == setup.time(10))
            #expect(findings.first?.end == setup.time(180))
        }
    }

    /// Ein schwerer Befund meldet sich als Mitteilung, die ins Wachbuch an seinen Beginn führt (TM-12.8).
    @Test func severeFindingIsNotified() async throws {
        try await ScratchDirectory.withCanonical(prefix: "watchbook-recorder") { directory in
            let notifier = RecordingNotifier()
            let setup = Setup(directory: directory, alerts: SevereFindingAlerts(notifier: notifier, isEnabled: { true }))
            setup.memory.set(MemoryStatus(physicalBytes: 16 << 30, usedBytes: 15 << 30, swapUsedBytes: 0,
                                          swapTotalBytes: 0, pressure: .critical, processCount: 1))
            await setup.recorder.setEnabled(true)
            await setup.tick(8, from: 10)
            var posts = notifier.posts.makeAsyncIterator()
            let post = try #require(await posts.next())
            #expect(post.title == "Kritischer Speicherdruck")
            #expect(post.destination == .watchbook(setup.time(10)))
            await setup.recorder.shutdown()
            #expect(notifier.all.count == 1)
        }
    }

    /// Beim Beenden der App endet ein laufender Befund mit dem letzten Punkt, an dem er noch lief.
    @Test func shutdownEndsRunningFindings() async throws {
        try await ScratchDirectory.withCanonical(prefix: "watchbook-recorder") { directory in
            let setup = Setup(directory: directory)
            await setup.recorder.setEnabled(true)
            setup.cpu.set(load: 0.95)
            await setup.tick(15, from: 10)
            await setup.recorder.shutdown()
            let findings = setup.store.records(in: setup.time(0)..<setup.time(1_000)).events
            #expect(findings.map(\.end) == [setup.time(150)])
        }
    }

    // MARK: Systemereignisse

    @Test func recordsBootAndPowerSourceChanges() async throws {
        try await withSetup(boot: WatchbookFixtures.dayStart.addingTimeInterval(11 * 3_600)) { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            setup.battery.set(BatteryReading(charge: 0.79, source: .battery))
            await setup.tick(1, from: 20)
            let system = await setup.events(of: .system)
            #expect(system.map(\.type) == ["system.boot", "system.power-adapter-off"])
            #expect(system.first?.start == WatchbookFixtures.dayStart.addingTimeInterval(11 * 3_600))
            #expect(system.last?.start == setup.time(20))
        }
    }

    /// Thermik und Energiesparmodus kommen per Wechsel von der Quelle; sie werden nie selbst abgefragt.
    @Test func recordsThermalAndLowPowerChangesFromTheSource() async throws {
        try await withSetup { setup in
            await setup.recorder.setEnabled(true)
            await setup.recorder.setThermalCondition(.nominal)
            await setup.tick(1, from: 10)
            await setup.recorder.setThermalCondition(ThermalCondition(state: .serious, isLowPowerModeEnabled: true))
            await setup.tick(1, from: 20)
            let points = await setup.records().points
            #expect(points.map { $0.values[.thermalState] } == [0, 2])
            let system = await setup.events(of: .system)
            #expect(Set(system.map(\.type)) == ["system.thermal-state", "system.low-power-on"])
            #expect(system.allSatisfy { $0.start == setup.time(20) })
        }
    }

    /// Änderungen aus dem Verlauf werden zu Marken – einmal, auch wenn sie erneut kommen; ausgeschaltet keine Datei.
    @Test func recordsChangeMarksOnceAndNothingWhileOff() async throws {
        try await withSetup { setup in
            let event = ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item("com.example.a")),
                                    detectedAt: setup.time(5))
            let entry = HistoryEvent(id: UUID(), event: event, isRead: false)
            await setup.recorder.recordChanges([entry])
            await setup.recorder.flush()
            #expect(!FileManager.default.fileExists(atPath: setup.store.directory.path))
            await setup.recorder.setEnabled(true)
            await setup.recorder.recordChanges([entry])
            await setup.recorder.recordChanges([entry])
            let marks = await setup.events(of: .change)
            #expect(marks.map(\.id) == [entry.id])
        }
    }

    /// Ein Start vor der Aufbewahrungsfrist landet nicht im Wachbuch (er würde sofort wieder entfernt).
    @Test func ignoresBootOlderThanTheRetention() async throws {
        try await withSetup(boot: WatchbookFixtures.dayStart.addingTimeInterval(-8 * 86_400)) { setup in
            await setup.recorder.setEnabled(true)
            await setup.tick(1, from: 10)
            #expect(await setup.events(of: .system).isEmpty)
        }
    }
}

/// Spielt Takte des Task-Managers ein wie `TaskManagerEngine`: eigene Zähler, eigener Akkumulator, Abgriff je Takt.
private final class TaskManagerFeed {
    let setup: WatchbookRecorderTests.Setup
    let sources: Set<TaskManagerSource>
    private var accumulator = TaskManagerAccumulator(interval: .oneSecond)
    private var hasMeasured = false

    init(setup: WatchbookRecorderTests.Setup, sources: Set<TaskManagerSource> = Set(TaskManagerSource.allCases)) {
        self.setup = setup
        self.sources = sources
    }

    /// Ein Takt nach `interval`: Uhr vorstellen, messen, abgreifen, abwarten.
    func measure(advancing interval: Duration) async {
        setup.clock.advance(by: interval)
        let all = TaskManagerReadings(
            processes: .success([]), cpu: .success(setup.cpu.ticks()), memory: .success(WatchbookRecorderTests.memory),
            battery: .success(BatteryReading(charge: 0.8, source: .externalPower)))
        let readings = TaskManagerReadings(
            processes: sources.contains(.processes) ? all.processes : nil,
            cpu: sources.contains(.cpu) ? all.cpu : nil, memory: sources.contains(.memory) ? all.memory : nil,
            battery: sources.contains(.battery) ? all.battery : nil)
        let frame = accumulator.ingest(readings, elapsed: hasMeasured ? interval : nil)
        hasMeasured = true
        setup.recorder.taskManagerDidMeasure(readings, frame: frame)
        await setup.recorder.settle()
    }
}
