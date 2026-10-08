import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct NetworkListenerSourceTests {
    /// Liefert der Reihe nach `results` (das letzte wiederholt sich) und zählt die Aufrufe.
    private final class Provider: ListeningSocketProviding {
        private let state: Mutex<(results: [Result<ListeningSocketScan, any Error>], calls: Int)>

        init(_ results: [Result<ListeningSocketScan, any Error>]) { state = Mutex((results, 0)) }
        convenience init(_ result: Result<ListeningSocketScan, any Error>) { self.init([result]) }

        var calls: Int { state.withLock { $0.calls } }

        func listeningSockets() async throws -> ListeningSocketScan {
            try state.withLock { state in
                state.calls += 1
                return state.results.count > 1 ? state.results.removeFirst() : state.results[0]
            }.get()
        }
    }

    private struct Local: ListeningSocketEnumerating {
        let scan: ListeningSocketScan
        func listeningSockets() throws -> ListeningSocketScan { scan }
    }

    /// Von außen verstellbare Uhr.
    private final class Clock: Sendable {
        private let date = Mutex(TestData.date)
        var now: Date { date.withLock { $0 } }
        func advance(by interval: TimeInterval) { date.withLock { $0 += interval } }
    }

    private let rootSocket = ListeningSocket(pid: 1, uid: 0, executablePath: "/usr/local/sbin/d", transport: .tcp,
                                             localAddress: "0.0.0.0", localPort: 22)
    private let ownSocket = ListeningSocket(pid: 2, uid: 501, executablePath: "/opt/homebrew/bin/node", transport: .tcp,
                                            localAddress: "127.0.0.1", localPort: 3000)
    private let clock = Clock()

    private func source(
        _ provider: (any ListeningSocketProviding)?, schedule: ListenerHelperSchedule = ListenerHelperSchedule(),
        terminations: ListenerTerminationLedger = ListenerTerminationLedger()
    ) -> NetworkListenerSource {
        let clock = clock
        return NetworkListenerSource(
            provider: provider, local: Local(scan: ListeningSocketScan(sockets: [ownSocket], deniedProcessCount: 9)),
            mapper: NetworkListenerMapper(inspector: RecordingSigningInspector(result: .unknown)), currentUID: 501,
            now: { clock.now }, schedule: schedule, terminations: terminations
        )
    }

    private var helperScan: ListeningSocketScan { ListeningSocketScan(sockets: [rootSocket]) }

    @Test func usesHelperWhenAvailable() async throws {
        let contribution = try await source(Provider(.success(helperScan))).collectAccepted()
        #expect(contribution.networkListeners.map(\.uid) == [0])
        #expect(contribution.retryableLimitations.isEmpty)
        #expect(contribution.listenersLimitedToUID == nil)
    }

    @Test func fallsBackToOwnProcesses() async throws {
        let contribution = try await source(Provider(.failure(HelperClientError.unavailable("aus")))).collectAccepted()
        #expect(contribution.networkListeners.map(\.uid) == [501])
        #expect(contribution.listenersLimitedToUID == 501)
        #expect(contribution.retryableLimitations.count == 1)
        #expect(contribution.retryableLimitations[0].hasPrefix("Dienste anderer Benutzer und des Systems nicht vollständig"))
    }

    @Test func withoutHelperScansLocally() async throws {
        let contribution = try await source(nil).collectAccepted()
        #expect(contribution.networkListeners.map(\.uid) == [501])
        #expect(contribution.listenersLimitedToUID == 501)
        #expect(contribution.retryableLimitations == ["\(NetworkListenerSource.limitationPrefix) – Helper nicht eingerichtet"])
    }

    @Test func helperIsAskedAtMostEveryFifteenMinutes() async throws {
        let provider = Provider(.success(helperScan))
        let source = source(provider)

        _ = try await source.collectAccepted()
        #expect(provider.calls == 1)

        clock.advance(by: 60)
        let between = try await source.collectAccepted()
        #expect(provider.calls == 1)
        #expect(between.networkListeners.map(\.uid) == [501])
        #expect(between.listenersLimitedToUID == 501)
        #expect(between.retryableLimitations.isEmpty)

        clock.advance(by: 14 * 60)
        let due = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(due.listenersLimitedToUID == nil)
    }

    /// Ruhiger lokaler Modus nach gelungenem Helper-Versuch: keine Einschränkung, fremde Lauscher werden
    /// fortgeschrieben – es entsteht kein `.added`, `NetworkListenerBaseline` greift hier nicht.
    @Test func quietLocalScanAfterHelperSuccessAddsNothing() async throws {
        let clock = clock
        let helper = Provider(.success(ListeningSocketScan(sockets: [rootSocket, ownSocket])))
        let coordinator = ScanCoordinator(sources: [source(helper)], currentUID: 501, now: { clock.now })
        let complete = try await coordinator.scan()

        clock.advance(by: 60)
        let local = try await coordinator.scan(previous: complete)
        let events = NetworkListenerBaseline.filtering(SnapshotDiffer().diff(from: complete, to: local),
                                                       previous: complete, current: local, currentUID: 501)

        #expect(local.sourceLimitations.isEmpty)
        #expect(Set(local.networkListeners.map(\.uid)) == [0, 501])
        #expect(events.isEmpty)
    }

    /// Nach einer vollständigen Erfassung fällt der Helper einmal aus; währenddessen startet ein fremder Dienst. Die
    /// nächste Helper-Lieferung meldet ihn als neu – die Baseline-Regel gilt nur für die erste vollständige Lieferung.
    @Test func newForeignListenerAfterHelperOutageIsReported() async throws {
        let clock = clock
        let newRoot = ListeningSocket(pid: 3, uid: 0, executablePath: "/usr/local/sbin/intruder", transport: .tcp,
                                      localAddress: "0.0.0.0", localPort: 4444)
        let provider = Provider([
            .success(ListeningSocketScan(sockets: [rootSocket, ownSocket])),
            .failure(HelperClientError.unavailable("aus")),
            .success(ListeningSocketScan(sockets: [rootSocket, ownSocket, newRoot])),
        ])
        let coordinator = ScanCoordinator(sources: [source(provider)], currentUID: 501, now: { clock.now })
        let complete = try await coordinator.scan()
        clock.advance(by: 15 * 60)
        let outage = try await coordinator.scan(previous: complete)
        clock.advance(by: 15 * 60)
        let recovered = try await coordinator.scan(previous: outage)
        let events = NetworkListenerBaseline.filtering(SnapshotDiffer().diff(from: outage, to: recovered),
                                                       previous: outage, current: recovered, currentUID: 501)

        #expect(outage.sourceLimitations.count == 1)
        #expect(provider.calls == 3)
        #expect(events.map(\.kind) == [.added])
        #expect(events.first?.after == .networkListener(try #require(recovered.networkListeners.first {
            $0.executablePath == newRoot.executablePath
        })))
    }

    /// #142 (Codex-Review Runde 3): Die Teilscans alle 60 s lesen zwischen den Helper-Abfragen nur eigene Sockets. Sie
    /// sind Zwischenmessungen und ersetzen nicht den Zeitpunkt der vollständigen Prüfung – „Aktuell · Geprüft“ nennt den
    /// Helper-Zeitpunkt, die Zwischenmessung steht nur als Hinweis dabei. Scheitert der Helper, ist es eine Lücke.
    @Test func interimMeasurementKeepsTimeOfCompleteCheck() async throws {
        let provider = Provider([.success(helperScan), .failure(HelperClientError.unavailable("aus"))])
        let clock = clock
        let coordinator = ScanCoordinator(sources: [source(provider)], currentUID: 501, now: { clock.now })
        let full = try await coordinator.scan()
        #expect(full.lastDeliveryBySource[.networkListeners] == TestData.date)
        #expect(full.lastInterimDeliveryBySource.isEmpty)

        clock.advance(by: 60)
        let interim = try await coordinator.scan(previous: full, only: [.networkListeners])
        #expect(provider.calls == 1)
        #expect(interim.lastDeliveryBySource[.networkListeners] == TestData.date)
        #expect(interim.lastInterimDeliveryBySource[.networkListeners] == TestData.date + 60)
        let coverage = AreaCoverage(area: .network, snapshot: interim)
        #expect(coverage.state == .current)
        #expect(coverage.checkedAt == TestData.date)
        #expect(coverage.timeText(now: clock.now, calendar: TestData.utcCalendar) == "Geprüft heute, 14:13")
        #expect(coverage.notes(now: clock.now, calendar: TestData.utcCalendar)
            == ["Eigene Dienste zuletzt gemessen: heute, 14:14"])

        // Nächster Helper-Termin scheitert: Lücke, der Stand bleibt der der letzten vollständigen Prüfung.
        clock.advance(by: 15 * 60)
        let failed = try await coordinator.scan(previous: interim, only: [.networkListeners])
        #expect(provider.calls == 2)
        #expect(failed.lastDeliveryBySource[.networkListeners] == TestData.date)
        let gap = AreaCoverage(area: .network, snapshot: failed)
        #expect(gap.state == .partial)
        #expect(gap.checkedAt == TestData.date)
        #expect(gap.nextStep(missingSetupSteps: []) == .rescan)
    }

    /// #142 (Codex-Review Runde 4): Übersprungene Prozesse der Helper-Messung (EPERM/EACCES) sind eine Lücke – auch in
    /// den folgenden lokalen Zwischenmessungen, bis eine Helper-Messung ohne Verweigerung sie schließt. Lokal verweigerte
    /// Prozesse (anderer Benutzer, erwartbar) zählen nicht.
    @Test func deniedProcessesOfHelperScanAreAGapUntilAFullHelperScan() async throws {
        let denied = ListeningSocketScan(sockets: [rootSocket], deniedProcessCount: 3)
        let provider = Provider([.success(denied), .success(helperScan)])
        let clock = clock
        let coordinator = ScanCoordinator(sources: [source(provider)], currentUID: 501, now: { clock.now })
        let expected = ["3 geschützte Prozesse nicht einsehbar – ihre Netzwerkdienste sind nicht geprüft"]

        let full = try await coordinator.scan()
        #expect(full.sourceLimitations == [SourceLimitation(source: .networkListeners, message: expected[0])])
        #expect(full.lastDeliveryBySource[.networkListeners] == TestData.date)
        let coverage = AreaCoverage(area: .network, snapshot: full)
        #expect(coverage.state == .partial)
        #expect(!coverage.isComplete)
        #expect(coverage.checkedAt == TestData.date)
        #expect(coverage.reasons(now: clock.now) == expected)
        #expect(coverage.nextStep(missingSetupSteps: []) == nil)

        clock.advance(by: 60)
        let interim = try await coordinator.scan(previous: full, only: [.networkListeners])
        #expect(provider.calls == 1)
        #expect(interim.sourceLimitations.map(\.message) == expected)
        #expect(AreaCoverage(area: .network, snapshot: interim).state == .partial)

        clock.advance(by: 15 * 60)
        let clean = try await coordinator.scan(previous: interim, only: [.networkListeners])
        #expect(provider.calls == 2)
        #expect(clean.sourceLimitations.isEmpty)
        #expect(AreaCoverage(area: .network, snapshot: clean).state == .current)
        clock.advance(by: 60)
        let cleanInterim = try await coordinator.scan(previous: clean, only: [.networkListeners])
        #expect(cleanInterim.sourceLimitations.isEmpty)
    }

    /// Lokale Messung, die beim Lesen wartet, bis der Test sie freigibt; meldet ihren Beginn.
    private struct BlockingLocal: ListeningSocketEnumerating {
        let scan: ListeningSocketScan
        let entered: Latch
        let proceed: Latch
        func listeningSockets() throws -> ListeningSocketScan {
            entered.release()
            proceed.wait()
            return scan
        }
    }

    /// #142 (Codex-Review Runde 5): „Jetzt scannen“ setzt den Helper-Takt zurück, während eine lokale Zwischenmessung
    /// läuft. Die Lücke der letzten Helper-Messung darf dabei nicht verschwinden – weder in der laufenden Messung noch
    /// in späteren, bis eine erfolgreiche Helper-Messung sie ersetzt.
    @Test func resetDuringInterimMeasurementKeepsDeniedGap() async throws {
        let schedule = ListenerHelperSchedule()
        let entered = Latch(), proceed = Latch()
        let clock = clock
        let provider = Provider([.success(ListeningSocketScan(sockets: [rootSocket], deniedProcessCount: 2)),
                                 .failure(HelperClientError.unavailable("aus")),
                                 .success(helperScan)])
        let source = NetworkListenerSource(
            provider: provider,
            local: BlockingLocal(scan: ListeningSocketScan(sockets: [ownSocket]), entered: entered, proceed: proceed),
            mapper: NetworkListenerMapper(inspector: RecordingSigningInspector(result: .unknown)), currentUID: 501,
            now: { clock.now }, schedule: schedule
        )
        let gap = NetworkListenerSource.deniedProcessLimitations(2)

        let full = try await source.collectAccepted()
        #expect(full.limitations == gap)

        clock.advance(by: 60)
        // Die Zwischenmessung wartet auf ihrer eigenen Queue. Reset und Freigabe laufen unabhängig davon.
        Thread {
            entered.wait()  // die Zwischenmessung läuft und wartet
            schedule.reset()
            proceed.release()
        }.start()
        #expect(try await source.collectAccepted().limitations == gap)
        #expect(provider.calls == 1)

        // Nach dem Reset fragt der nächste Scan den Helper; scheitert er, bleibt die Lücke (samt Fehlerhinweis).
        clock.advance(by: 60)
        proceed.release()
        let failed = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(failed.limitations == gap)
        #expect(failed.retryableLimitations.count == 1)

        // Erst eine erfolgreiche Helper-Messung ohne Verweigerung schließt sie.
        schedule.reset()
        let clean = try await source.collectAccepted()
        #expect(provider.calls == 3)
        #expect(clean.limitations.isEmpty)
        #expect(clean.retryableLimitations.isEmpty)
    }

    /// Signaturprüfung, deren erster Aufruf wartet, bis der Test ihn freigibt – verzögert die Aufbereitung der
    /// Helper-Messung über die Frist des Coordinators.
    private final class GatedInspector: SigningInspecting {
        let gate = Latch()
        /// Wird beim ersten (angehaltenen) Aufruf ausgelöst.
        let entered = Latch()
        private let calls = Mutex(0)
        func inspect(path: String) -> SigningInfo {
            if calls.withLock({ $0 += 1; return $0 }) == 1 {
                entered.release()
                gate.wait()
            }
            return .unknown
        }
    }

    /// #142 (Codex-Review Runde 6): Überschreitet die Aufbereitung einer Helper-Messung die Frist, verwirft der
    /// Coordinator den Beitrag. Der Erfolg darf dann nicht festgeschrieben sein: Die Lücke der letzten Messung bleibt, und
    /// der nächste Scan fragt den Helper erneut, statt ohne Einschränkung lokal zu messen („Aktuell“).
    @Test
    func helperSuccessCountsOnlyOnceTheCoordinatorAcceptsIt() async throws {
        let inspector = GatedInspector()
        let schedule = ListenerHelperSchedule()
        let clock = clock
        let provider = Provider(.success(helperScan))
        let source = NetworkListenerSource(
            provider: provider, local: Local(scan: ListeningSocketScan(sockets: [ownSocket])),
            mapper: NetworkListenerMapper(inspector: inspector), currentUID: 501, now: { clock.now }, schedule: schedule
        )
        let coordinator = ScanCoordinator(sources: [source], sourceTimeout: .milliseconds(50), currentUID: 501,
                                          now: { clock.now })

        let timedOut = try await coordinator.scan()
        #expect(timedOut.failedSources == [.networkListeners])
        #expect(provider.calls == 1)
        // Auch nach der Frist bleibt die angehaltene Aufbereitung belegt: keine weitere Helper-Anfrage/Prüfung.
        let stillRunning = try await coordinator.scan()
        #expect(stillRunning.sourceErrors.first?.message == ScanCoordinator.stillRunningMessage)
        #expect(provider.calls == 1)
        inspector.gate.release()

        // Zwischenmessung 60 s später: Der verworfene Erfolg gilt nicht – der Helper ist weiter fällig.
        clock.advance(by: 60)
        var next = try await coordinator.scan(previous: timedOut, only: [.networkListeners])
        for _ in 0..<200 where next.sourceErrors.first?.message == ScanCoordinator.stillRunningMessage {
            try await Task.sleep(for: .milliseconds(10))  // die verworfene Messung läuft im Hintergrund zu Ende
            next = try await coordinator.scan(previous: timedOut, only: [.networkListeners])
        }
        #expect(provider.calls == 2)
        #expect(next.sourceErrors.isEmpty)
        #expect(next.lastDeliveryBySource[.networkListeners] == clock.now)
        #expect(next.lastInterimDeliveryBySource.isEmpty)
        #expect(AreaCoverage(area: .network, snapshot: next).state == .current)
        #expect(AreaCoverage(area: .network, snapshot: timedOut).state != .current)

        // Erst jetzt ist der Erfolg übernommen: Die folgende Messung ist eine Zwischenmessung.
        clock.advance(by: 60)
        let interim = try await coordinator.scan(previous: next, only: [.networkListeners])
        #expect(provider.calls == 2)
        #expect(interim.lastInterimDeliveryBySource[.networkListeners] == clock.now)
    }

    /// #142 (Codex-Review Runde 7): Ein `reset()` („Jetzt scannen“) während der Aufbereitung einer Helper-Messung bleibt
    /// wirksam, auch wenn ihr Beitrag danach übernommen wird: Der nächste Scan fragt den Helper erneut. Die Lücke der
    /// Messung gilt trotzdem (sie war vollständig und erfolgreich).
    @Test func resetDuringMappingIsHonouredAfterAcceptance() async throws {
        let inspector = GatedInspector()
        let schedule = ListenerHelperSchedule()
        let clock = clock
        let provider = Provider(.success(ListeningSocketScan(sockets: [rootSocket], deniedProcessCount: 1)))
        let source = NetworkListenerSource(
            provider: provider, local: Local(scan: ListeningSocketScan(sockets: [ownSocket])),
            mapper: NetworkListenerMapper(inspector: inspector), currentUID: 501, now: { clock.now }, schedule: schedule
        )
        // Die Aufbereitung blockiert ihren Pool-Thread bis zur Freigabe; Reset und Freigabe laufen auf eigenem Thread.
        Thread {
            inspector.entered.wait()  // Aufbereitung läuft und ist angehalten
            schedule.reset()
            inspector.gate.release()
        }.start()
        source.accept(try await source.collect())

        let status = schedule.status(at: clock.now + 60)
        #expect(status.isDue)
        #expect(status.lastDeniedProcessCount == 1)
        clock.advance(by: 60)
        let next = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(next.listenersLimitedToUID == nil)
    }

    /// Dasselbe für einen gescheiterten Versuch: Ein Reset währenddessen bleibt wirksam.
    @Test func resetDuringFailedAttemptIsHonoured() async throws {
        let schedule = ListenerHelperSchedule()
        let generation = schedule.status(at: TestData.date).resetGeneration
        schedule.reset()
        schedule.recordFailure(attemptAt: TestData.date, failure: "aus", resetGeneration: generation)
        #expect(schedule.status(at: TestData.date + 60).isDue)
        #expect(schedule.status(at: TestData.date + 60).lastFailure == "aus")
    }

    /// Eine Vormerkung ohne Übernahme ändert den Zustand nicht; ein Reset danach behält beim Festschreiben den Takt.
    @Test func stagedSuccessWithoutCommitKeepsPreviousState() {
        let schedule = ListenerHelperSchedule()
        let first = schedule.stageSuccess(attemptAt: TestData.date, deniedProcessCount: 2,
                                          resetGeneration: schedule.status(at: TestData.date).resetGeneration)
        #expect(schedule.status(at: TestData.date + 60).isDue)
        schedule.commit(first)
        #expect(!schedule.status(at: TestData.date + 60).isDue)
        #expect(schedule.status(at: TestData.date + 60).lastDeniedProcessCount == 2)

        let second = schedule.stageSuccess(attemptAt: TestData.date + 60, deniedProcessCount: 0,
                                           resetGeneration: schedule.status(at: TestData.date + 60).resetGeneration)
        schedule.reset()
        schedule.commit(second)
        let status = schedule.status(at: TestData.date + 120)
        #expect(status.isDue)  // der Reset gilt weiter
        #expect(status.lastDeniedProcessCount == 0)
        schedule.commit(second)  // zweites Festschreiben wirkungslos
    }

    @Test func deniedProcessTextsAreSingularAndPlural() {
        #expect(NetworkListenerSource.deniedProcessLimitations(0).isEmpty)
        #expect(NetworkListenerSource.deniedProcessLimitations(1)
            == ["1 geschützter Prozess nicht einsehbar – seine Netzwerkdienste sind nicht geprüft"])
    }

    /// Eine vollständige Lieferung löscht die Zwischenmessung.
    @Test func completeDeliveryClearsInterimMeasurement() async throws {
        let provider = Provider(.success(helperScan))
        let clock = clock
        let schedule = ListenerHelperSchedule()
        let coordinator = ScanCoordinator(sources: [source(provider, schedule: schedule)], currentUID: 501, now: { clock.now })
        let full = try await coordinator.scan()
        clock.advance(by: 60)
        let interim = try await coordinator.scan(previous: full, only: [.networkListeners])
        #expect(!interim.lastInterimDeliveryBySource.isEmpty)
        clock.advance(by: 60)
        schedule.reset()
        let again = try await coordinator.scan(previous: interim, only: [.networkListeners])
        #expect(again.lastDeliveryBySource[.networkListeners] == TestData.date + 120)
        #expect(again.lastInterimDeliveryBySource.isEmpty)
    }

    @Test func failedHelperKeepsLimitationUntilNextAttempt() async throws {
        let provider = Provider([.failure(HelperClientError.unavailable("aus")), .success(helperScan)])
        let source = source(provider)

        let failed = try await source.collectAccepted()
        #expect(failed.retryableLimitations.count == 1)

        clock.advance(by: 60)
        let between = try await source.collectAccepted()
        #expect(provider.calls == 1)
        #expect(between.retryableLimitations == failed.retryableLimitations)
        #expect(between.listenersLimitedToUID == 501)

        clock.advance(by: 15 * 60)
        let recovered = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(recovered.retryableLimitations.isEmpty)
        #expect(recovered.listenersLimitedToUID == nil)
    }

    @Test func cancelledHelperCallIsRetried() async throws {
        let provider = Provider([.failure(CancellationError()), .success(helperScan)])
        let source = source(provider)

        await #expect(throws: CancellationError.self) { try await source.collectAccepted() }

        let retried = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(retried.listenersLimitedToUID == nil)
    }

    /// Kopien der Quelle (Struct) teilen sich den Zeitplan.
    @Test func copiesShareTheSchedule() async throws {
        let provider = Provider(.success(helperScan))
        let source = source(provider)
        let copy = source

        _ = try await source.collectAccepted()
        _ = try await copy.collectAccepted()
        #expect(provider.calls == 1)
    }

    @Test func resetAsksTheHelperRightAway() async throws {
        let provider = Provider([.failure(HelperClientError.outdated), .success(helperScan)])
        let schedule = ListenerHelperSchedule()
        let source = source(provider, schedule: schedule)

        _ = try await source.collectAccepted()
        clock.advance(by: 60)
        schedule.reset()
        let afterReset = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(afterReset.retryableLimitations.isEmpty)
        #expect(afterReset.listenersLimitedToUID == nil)
    }

    /// Springt die Uhr zurück, wird der Helper genau einmal gefragt, danach gilt wieder der normale Takt.
    @Test func clockJumpingBackAsksTheHelperOnce() async throws {
        let provider = Provider(.success(helperScan))
        let source = source(provider)

        _ = try await source.collectAccepted()
        clock.advance(by: -60 * 60)
        let jumped = try await source.collectAccepted()
        #expect(provider.calls == 2)
        #expect(jumped.listenersLimitedToUID == nil)

        clock.advance(by: 60)
        _ = try await source.collectAccepted()
        #expect(provider.calls == 2)

        clock.advance(by: 14 * 60)
        _ = try await source.collectAccepted()
        #expect(provider.calls == 3)
    }

    // MARK: „Prozess beenden …“ (`ListenerTerminationLedger`)

    @Test func reportsEndedListenersThatAreNotSeen() async throws {
        let ledger = ListenerTerminationLedger()
        let gone = TestData.listener("/usr/local/bin/gone", uid: 501)
        let node = TestData.listener("/opt/homebrew/bin/node", uid: 501, addresses: ["127.0.0.1"])
        ledger.record(gone.id, at: clock.now)
        ledger.record(node.id, at: clock.now)
        let contribution = try await source(nil, terminations: ledger).collectAccepted()
        #expect(contribution.endedListenerIDs == [gone.id])
    }

    /// Nach „Prozess beenden …“ fragt die Quelle den Helper außerhalb ihres 15-min-Takts – einmal.
    @Test func terminationAsksTheHelperOutsideItsInterval() async throws {
        let provider = Provider(.success(helperScan))
        let ledger = ListenerTerminationLedger()
        let source = source(provider, terminations: ledger)
        _ = try await source.collectAccepted()
        _ = try await source.collectAccepted()
        #expect(provider.calls == 1)
        ledger.record("x", at: clock.now)
        _ = try await source.collectAccepted()
        _ = try await source.collectAccepted()
        #expect(provider.calls == 2)
    }

    /// Wird die außerplanmäßige Helper-Abfrage abgebrochen, holt der nächste Scan sie nach.
    @Test func cancelledTerminationRefreshIsRetried() async throws {
        let provider = Provider([.success(helperScan), .failure(CancellationError()), .success(helperScan)])
        let ledger = ListenerTerminationLedger()
        let source = source(provider, terminations: ledger)
        _ = try await source.collectAccepted()
        ledger.record("x", at: clock.now)

        await #expect(throws: CancellationError.self) { try await source.collectAccepted() }
        let retried = try await source.collectAccepted()
        #expect(provider.calls == 3)
        #expect(retried.listenersLimitedToUID == nil)
    }

    /// Ein beendeter root-Dienst fällt sofort weg, obwohl ihn sonst die 20-min-Frist hielte. Das erzeugt ein
    /// `.removed`, das `NetworkListenerBaseline` durchlässt und das nie gemeldet wird.
    @Test func terminatedForeignListenerIsRemovedWithoutNotification() async throws {
        let clock = clock
        let provider = Provider([.success(helperScan), .success(ListeningSocketScan(sockets: []))])
        let ledger = ListenerTerminationLedger()
        let coordinator = ScanCoordinator(sources: [source(provider, terminations: ledger)], currentUID: 501,
                                          now: { clock.now })
        let before = try await coordinator.scan()
        let root = try #require(before.networkListeners.first)

        clock.advance(by: 60)
        ledger.record(root.id, at: clock.now)
        let after = try await coordinator.scan(previous: before)
        let events = NetworkListenerBaseline.filtering(SnapshotDiffer().diff(from: before, to: after),
                                                       previous: before, current: after, currentUID: 501)

        #expect(after.networkListeners.isEmpty)
        #expect(events.map(\.kind) == [.removed])
        #expect(!events.contains { NotificationPolicy(listenerSetting: { .all }).shouldNotify($0) })
    }

    /// Startet der Dienst neu, ist er wieder sichtbar und wird danach wie jeder andere fremde Lauscher fortgeschrieben –
    /// der Vermerk macht ihn nicht dauerhaft unsichtbar.
    @Test func restartedListenerStaysVisible() async throws {
        let clock = clock
        let provider = Provider(.success(helperScan))
        let ledger = ListenerTerminationLedger()
        let coordinator = ScanCoordinator(sources: [source(provider, terminations: ledger)], currentUID: 501,
                                          now: { clock.now })
        let before = try await coordinator.scan()
        let root = try #require(before.networkListeners.first)

        clock.advance(by: 60)
        ledger.record(root.id, at: clock.now)
        let restarted = try await coordinator.scan(previous: before)
        clock.advance(by: 60)
        let local = try await coordinator.scan(previous: restarted)

        #expect(provider.calls == 2)
        #expect(restarted.networkListeners.map(\.id) == [root.id])
        #expect(local.networkListeners.map(\.id).contains(root.id))
    }
}

extension InventorySource {
    /// `collect()` samt Übernahme wie im `ScanCoordinator` (`accept(_:)`) – für Tests, die die Quelle direkt fragen.
    func collectAccepted() async throws -> InventoryContribution {
        let contribution = try await collect()
        accept(contribution)
        return contribution
    }
}
