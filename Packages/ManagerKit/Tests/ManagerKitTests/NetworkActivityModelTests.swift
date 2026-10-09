import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NetworkActivityModelTests {
    private let header = NettopParser.header
    private let instants = SteppedInstants()

    private func model(
        _ streamer: ScriptedLineStreamer,
        programs: ActivityProgramResolver = ActivityProgramResolver(
            executablePath: { _ in "/usr/bin/curl" }, inspector: RecordingSigningInspector(result: SigningInfo(kind: .apple))
        ),
        hostNames: HostNameResolver = Self.hostNames(["192.0.2.10": "api.example.com"])
    ) -> NetworkActivityModel {
        NetworkActivityModel(
            sampler: NettopSampler(streamer: streamer, startTime: { _ in 1 }, now: { [instants] in instants.next() },
                                   sleep: { _ in }),
            programs: programs,
            hostNameResolver: hostNames,
            systemVersion: "27.0.1"
        )
    }

    /// Resolver mit festen Namen, dessen Zeitlimit nicht greift: Auf einem ausgelasteten Runner käme die Fake-Antwort
    /// sonst womöglich erst nach den 2 s des Standard-Limits, und der Name fehlte bis zur nächsten Messung.
    private static func hostNames(_ names: [String: String]) -> HostNameResolver {
        HostNameResolver(lookup: FakeReverseDNS(names), timeout: .seconds(3600))
    }

    private struct ConditionTimedOut: Error {}

    /// Wartet suspendierend (nie blockierend), bis `condition` gilt; nach `deadline` meldet es `what` als Fehler und
    /// bricht den Test ab. Die Frist greift nur im Fehlerfall – auf einem Runner mit drei Kernen dauert eine
    /// Task-Fortsetzung unter Last mehrere Sekunden.
    private func eventually(
        _ what: Comment = "Bedingung", within deadline: Duration = LatencyBound.wellBeforeLongTimeouts,
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        let end = ContinuousClock.now + deadline
        while !condition() {
            guard ContinuousClock.now < end else {
                Issue.record("Zeitüberschreitung (\(deadline)): \(what)", sourceLocation: sourceLocation)
                throw ConditionTimedOut()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private var twoSamples: [String] {
        [header, "curl.42,,0,0,", "tcp4 192.0.2.1:50000<->192.0.2.10:443,Established,0,0,",
         header, "curl.42,,3000,1500,", "tcp4 192.0.2.1:50000<->192.0.2.10:443,Established,3000,1500,", header]
    }

    @Test func showsRatesAndHostNamesAndStopsNettop() async throws {
        let streamer = ScriptedLineStreamer([.init(twoSamples, ending: .hangUntilCancelled)])
        let model = model(streamer)
        model.start()
        #expect(model.status == .running)
        try await eventually { model.frame.report.history.count == 1 && model.hostNames["192.0.2.10"] != nil }

        let row = try #require(model.rows.first)
        #expect(row.title == "curl")
        #expect(row.downloadRate == 1000)
        #expect(row.children?.first?.title == "api.example.com (192.0.2.10)")
        #expect(model.notice == nil)

        model.stop()
        #expect(model.status == .idle)
        await model.stopAndWait()
        #expect(streamer.terminatedRuns == 1)
    }

    @Test func launchFailureShowsRetryableNoticeWithoutNumbers() async throws {
        let streamer = ScriptedLineStreamer([.init(ending: .launchFailure), .init(twoSamples, ending: .hangUntilCancelled)])
        let model = model(streamer)
        model.start()
        try await eventually { model.status != .running }

        #expect(model.status == .failed(.unavailable(reason: "No such file or directory")))
        #expect(model.rows.isEmpty)
        #expect(model.notice?.offersRetry == true)

        model.retry()
        try await eventually { model.frame.report.history.count == 1 }
        #expect(model.status == .running)
        await model.stopAndWait()
    }

    @Test func unknownFormatNamesSystemVersion() async throws {
        let model = model(ScriptedLineStreamer([.init(["kaputt", header], ending: .hangUntilCancelled)]))
        model.start()
        try await eventually { model.status != .running }

        #expect(model.status == .failed(.unrecognizedFormat))
        #expect(model.notice?.headline == "Ausgabeformat von nettop nicht erkannt (macOS 27.0.1)")
        #expect(model.notice?.offersRetry == false)
    }

    /// Ein erneutes Öffnen während des Beendens startet sofort einen neuen Lauf; der alte meldet nichts mehr.
    /// Liefert der alte Lauf nach `stop()` + `start()` noch eine Messung, zeigt das Modell trotzdem nur den neuen Lauf,
    /// und die späte Messung ändert keinen Zustand der Programmzuordnung mehr.
    @Test func restartWhileStoppingKeepsNewRun() async throws {
        let streamer = ManualLineStreamer()
        let queriedPIDs = Mutex<Set<Int32>>([])
        let programs = ActivityProgramResolver(
            executablePath: { pid in
                queriedPIDs.withLock { _ = $0.insert(pid) }
                return nil
            },
            inspector: RecordingSigningInspector(result: .unknown)
        )
        let model = NetworkActivityModel(
            sampler: NettopSampler(streamer: streamer, startTime: { _ in 1 }, now: { [instants] in instants.next() },
                                   sleep: { _ in }),
            programs: programs,
            hostNameResolver: Self.hostNames([:]), systemVersion: "27.0.1"
        )
        let names = { model.frame.report.processes.map(\.shortName) }
        model.start()
        try await eventually("erster Lauf gestartet") { streamer.startedRuns == 1 }
        streamer.send([header, "alt.42,,0,0,", header], toRun: 0)
        try await eventually("Messung des alten Laufs") { names() == ["alt"] }

        model.stop()
        model.start()
        #expect(model.status == .running)
        try await eventually("zweiter Lauf gestartet") { streamer.startedRuns == 2 }
        streamer.send([header, "neu.43,,0,0,", header], toRun: 1)
        try await eventually("Messung des neuen Laufs") { names() == ["neu"] }

        streamer.send(["spaet.44,,500,500,", header, "spaet.44,,900,900,", header], toRun: 0)
        try await eventually("alter Lauf hat seine Zeilen gelesen") { streamer.consumedLines(ofRun: 0) == 7 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(names() == ["neu"])
        let lateProcessQueried = queriedPIDs.withLock { $0.contains(44) }
        #expect(!lateProcessQueried)
        #expect(model.status == .running)

        model.stop()
        streamer.closeAll()
        await model.stopAndWait()
        #expect(streamer.terminatedRuns == 2)
    }

    /// Wechsel „Dienste | Aktivität“: Erscheint die neue Ansicht vor dem Verschwinden der alten, läuft dieselbe
    /// Messung weiter; erst wenn kein Abnehmer mehr misst, endet nettop.
    @Test func consumersShareOneRun() async throws {
        let streamer = ScriptedLineStreamer([.init(twoSamples, ending: .hangUntilCancelled)])
        let model = model(streamer)
        model.start(for: .listenerDetail)
        try await eventually { model.frame.report.history.count == 1 }

        model.start(for: .activityView)
        model.stop(for: .listenerDetail)
        #expect(model.status == .running)
        #expect(model.frame.report.history.count == 1)
        let activity = model.listenerActivity(forProgramAt: "/usr/bin/curl")
        #expect(activity.rate == TrafficRate(download: 1000, upload: 500))
        #expect(activity.connections.first?.direction == .outbound)

        model.stop(for: .activityView)
        #expect(model.status == .idle)
        await model.stopAndWait()
        #expect(streamer.startedRuns == 1)
        #expect(streamer.terminatedRuns == 1)
    }

    /// Kopf der Ansicht: Summe ↓/↑ des Macs und Verlauf – unabhängig von Filter und Suche.
    @Test func totalsAndHistoryCoverAllProcessesRegardlessOfFilter() async throws {
        let lines = [header, "curl.42,,0,0,", "node.43,,0,0,",
                     header, "curl.42,,3000,1500,", "node.43,,600,300,", header]
        let model = model(ScriptedLineStreamer([.init(lines, ending: .hangUntilCancelled)]))
        model.query = "nichts"
        model.start()
        try await eventually { model.frame.report.history.count == 1 }

        #expect(model.rows.isEmpty)
        model.query = ""
        #expect(model.rows.map(\.title) == ["curl", "curl"])
        model.query = "nichts"

        let total = model.frame.report.total
        let processRates = model.frame.report.processes.reduce(TrafficRate.zero) { $0 + $1.rate }
        #expect(model.rows.isEmpty)
        #expect(total == processRates)
        #expect(total.download > 0)
        #expect(total.upload > 0)
        #expect(model.frame.report.history == [total])
        await model.stopAndWait()
    }

    /// Ein fertiger Hostname erscheint gebündelt auch ohne weitere Messung – samt neu aufgebauter Zeile.
    @Test func hostNamesArriveWithoutNextSample() async throws {
        let lines = [header, "curl.42,,0,0,", "tcp4 192.0.2.1:50000<->192.0.2.10:443,Established,0,0,", header]
        let model = model(ScriptedLineStreamer([.init(lines, ending: .hangUntilCancelled)]))
        model.filter.onlyActive = false
        model.start()
        try await eventually("Hostname übernommen") { model.hostNames["192.0.2.10"] == "api.example.com" }

        #expect(model.frame.report.history.isEmpty)
        #expect(model.rows.first?.children?.first?.title == "api.example.com (192.0.2.10)")
        await model.stopAndWait()
    }

    /// Eine beendete (ausgegraute) Verbindung behält ihren Hostnamen, statt auf die IP zurückzuspringen.
    @Test func greyedConnectionKeepsHostName() async throws {
        let streamer = ManualLineStreamer()
        let model = NetworkActivityModel(
            sampler: NettopSampler(streamer: streamer, startTime: { _ in 1 }, now: { [instants] in instants.next() },
                                   sleep: { _ in }),
            programs: ActivityProgramResolver(executablePath: { _ in nil }, inspector: RecordingSigningInspector(result: .unknown)),
            hostNameResolver: Self.hostNames(["192.0.2.10": "api.example.com"]),
            systemVersion: "27.0.1"
        )
        model.filter.onlyActive = false
        model.start()
        try await eventually("Lauf gestartet") { streamer.startedRuns == 1 }
        streamer.send([header, "curl.42,,0,0,", "tcp4 192.0.2.1:50000<->192.0.2.10:443,Established,0,0,", header],
                      toRun: 0)
        try await eventually("Hostname übernommen") { model.hostNames["192.0.2.10"] == "api.example.com" }

        streamer.send(["curl.42,,0,0,", header], toRun: 0)
        try await eventually("Verbindung ausgegraut") {
            model.frame.report.processes.first?.connections.first?.isGone == true
        }
        #expect(model.hostNames["192.0.2.10"] == "api.example.com")
        #expect(model.rows.first?.children?.first?.title == "api.example.com (192.0.2.10)")

        model.stop()
        streamer.closeAll()
        await model.stopAndWait()
    }

    /// nettop endet wiederholt: Fehlerzustand mit „Erneut versuchen“, keine Zahlen.
    @Test func repeatedEndsShowRetryableNotice() async throws {
        let runs = (0..<NettopSampler.maximumConsecutiveRestarts).map { _ in ScriptedLineStreamer.Run() }
        let model = model(ScriptedLineStreamer(runs))
        model.start()
        try await eventually { model.status != .running }

        #expect(model.status == .failed(.endedRepeatedly))
        #expect(model.rows.isEmpty)
        #expect(model.frame == .empty)
        #expect(model.notice?.offersRetry == true)
    }

    /// Unlesbare Verbindungszeilen: Messung läuft weiter, die Leiste meldet den Teil-Lesefehler.
    @Test func unreadableConnectionLinesShowPartialNotice() async throws {
        let lines = [header, "curl.42,,0,0,", "tcp4 192.0.2.1<->192.0.2.10:443,Established,1,2,", header]
        let model = model(ScriptedLineStreamer([.init(lines, ending: .hangUntilCancelled)]))
        model.start()
        try await eventually { model.frame.report.skippedLineCount > 0 }

        #expect(model.status == .running)
        #expect(model.notice?.headline == "Teilweise gelesen")
        #expect(model.notice?.offersRetry == false)
        await model.stopAndWait()
    }

    /// `stop()` verwirft eingereihte Signaturprüfungen; die laufende endet regulär.
    @Test func stopDiscardsQueuedSignatureInspections() async throws {
        let inspector = HoldingSigningInspector()
        let programs = ActivityProgramResolver(executablePath: { "/opt/tool\($0)" }, inspector: inspector)
        let lines = [header, "a.11,,0,0,", "b.12,,0,0,", "c.13,,0,0,", header]
        let model = model(ScriptedLineStreamer([.init(lines, ending: .hangUntilCancelled)]), programs: programs)
        model.start()
        try await eventually { !inspector.paths.isEmpty }

        model.stop()
        inspector.release()
        await model.stopAndWait()
        await programs.waitForInspections()
        #expect(inspector.paths.count == 1)
    }

    /// `stop()` bricht laufende Hostnamen-Abfragen ab; `stopAndWait()` kehrt zurück, obwohl die Abfrage hängt.
    @Test func stopCancelsHostNameLookups() async throws {
        let gate = Gate()
        let lookup = FakeReverseDNS(["192.0.2.10": "api.example.com"], gate: gate)
        let hostNames = HostNameResolver(lookup: lookup, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let model = model(ScriptedLineStreamer([.init(twoSamples, ending: .hangUntilCancelled)]), hostNames: hostNames)
        model.start()
        try await eventually { !lookup.lookedUp.isEmpty }

        // Ohne Abbruch hinge die Abfrage (Gate zu, Zeitlimit 1 h) und bliebe eingetragen.
        model.stop()
        let deadline = ContinuousClock.now + LatencyBound.wellBeforeLongTimeouts
        while model.hostNameLookupCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.hostNameLookupCount == 0)
        #expect(model.hostNames.isEmpty)
        if model.hostNameLookupCount == 0 { await model.stopAndWait() }
        gate.open()
    }

    /// Wird das Modell ohne `stop()` freigegeben, endet nettop trotzdem.
    @Test func releasingModelWithoutStopEndsNettop() async throws {
        let streamer = ScriptedLineStreamer([.init(twoSamples, ending: .hangUntilCancelled)])
        var model: NetworkActivityModel? = model(streamer)
        model?.start()
        try await eventually { model?.frame.report.history.count == 1 }

        model = nil
        try await eventually { streamer.terminatedRuns == 1 }
    }

    #if DEBUG
    @Test func previewNeverStartsNettop() {
        let model = NetworkActivityModel.preview(frame: NetworkActivityPreviewData.frame, status: .running,
                                                 hostNames: NetworkActivityPreviewData.hostNames)
        model.start()
        #expect(model.rows.map(\.title) == ["Firefox", "node", "curl"])
    }
    #endif
}

/// Hält die erste Prüfung auf der Signatur-Queue (nicht im kooperativen Pool) an, bis `release()` kommt.
private final class HoldingSigningInspector: SigningInspecting {
    private let state = Mutex<(paths: [String], released: Bool)>(([], false))

    var paths: [String] { state.withLock { $0.paths } }

    func release() { state.withLock { $0.released = true } }

    func inspect(path: String) -> SigningInfo {
        state.withLock { $0.paths.append(path) }
        let deadline = Date().addingTimeInterval(30)
        while !state.withLock({ $0.released }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        return SigningInfo(kind: .apple)
    }
}

/// Läufe, deren Zeilen der Test einzeln nachschiebt (`send`). Ein Lauf liest seine Zeilen auch nach dem Abbruch weiter –
/// wie ein Block, der beim Abbrechen schon unterwegs war – und endet erst mit `closeAll()`. Wartet suspendierend.
private final class ManualLineStreamer: LineStreaming {
    private struct State {
        var pending: [[String]] = []
        var consumed: [Int] = []
        var closed = false
        var started = 0
        var terminated = 0
    }

    private let state = Mutex(State())

    var startedRuns: Int { state.withLock { $0.started } }
    var terminatedRuns: Int { state.withLock { $0.terminated } }

    func consumedLines(ofRun run: Int) -> Int { state.withLock { $0.consumed[run] } }

    func send(_ lines: [String], toRun run: Int) { state.withLock { $0.pending[run] += lines } }

    func closeAll() { state.withLock { $0.closed = true } }

    func run(_ executable: String, _ arguments: [String], onLine: @Sendable (String) throws -> Void) async throws -> Int32 {
        let run = state.withLock { state in
            state.pending.append([])
            state.consumed.append(0)
            state.started += 1
            return state.started - 1
        }
        while true {
            let (line, closed) = state.withLock { state -> (String?, Bool) in
                guard !state.pending[run].isEmpty else { return (nil, state.closed) }
                state.consumed[run] += 1
                return (state.pending[run].removeFirst(), false)
            }
            if let line {
                try onLine(line)
            } else if closed {
                break
            } else {
                // Kurz suspendieren, ohne auf Abbruch zu reagieren: `Task.sleep` würde im abgebrochenen Task sofort
                // werfen, daher in einem eigenen, nie abgebrochenen Task. Keine globale Dispatch-Queue – deren Threads
                // vergibt der Kernel bei ausgelastetem Pool nicht.
                await Task.detached { try? await Task.sleep(for: .milliseconds(5)) }.value
            }
        }
        guard Task.isCancelled else { return 0 }
        state.withLock { $0.terminated += 1 }
        throw CancellationError()
    }
}
