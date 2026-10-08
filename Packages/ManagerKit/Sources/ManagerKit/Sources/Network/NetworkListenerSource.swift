import Foundation
import os
import Synchronization

/// Lauschende Netzwerkdienste (Spec §5). Alle Benutzer liest nur der root-Helper; ihn fragt die Quelle höchstens alle
/// `ListenerTiming.helperInterval` (15 min, `ListenerHelperSchedule`), damit sein Idle-Exit (5 min) greift. Dazwischen
/// und ohne Helper liest sie lokal nur eigene Prozesse (`listenersLimitedToUID`); Lauscher anderer Benutzer schreibt der
/// `ScanCoordinator` dann fort (`Snapshot.carryingForwardListeners`). Ein solcher lokaler Beitrag deckt nicht den vollen
/// Umfang ab (`InventoryContribution.coversFullScope == false`): Er zählt als Zwischenmessung, nicht als vollständige
/// Prüfung (#142).
///
/// Eine Einschränkung meldet der lokale Beitrag nur, wenn kein Helper eingerichtet ist oder der letzte Helper-Versuch
/// scheiterte – eine planmäßige Zwischenmessung nach gelungenem Versuch zeigt keinen Hinweis. Die App übergibt immer
/// einen `provider`; ohne Helper scheitert dessen Abfrage, die Einschränkung lautet dann „… – Helper nicht erreichbar:
/// …“. Der Zweig „Helper nicht eingerichtet“ gilt nur ohne `provider` (`nil`).
public struct NetworkListenerSource: InventorySource {
    public let id: SourceID = .networkListeners
    static let limitationPrefix = "Dienste anderer Benutzer und des Systems nicht vollständig"
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "network")

    private let provider: (any ListeningSocketProviding)?
    private let local: any ListeningSocketEnumerating
    private let mapper: NetworkListenerMapper
    private let currentUID: UInt32
    private let now: @Sendable () -> Date
    private let schedule: ListenerHelperSchedule
    private let terminations: ListenerTerminationLedger
    private let queue = BlockingWorkQueue(label: "network-listeners")

    /// - Parameters:
    ///   - provider: Helper-Zugang; `nil`, wenn kein Helper eingerichtet ist.
    ///   - schedule: Takt der Helper-Versuche, geteilt von allen Kopien der Quelle; für Tests injizierbar.
    ///   - terminations: von „Prozess beenden …“ vermerkte Lauscher (`ListenerTerminationLedger`).
    public init(
        provider: (any ListeningSocketProviding)?,
        local: any ListeningSocketEnumerating = LibprocSocketEnumerator(),
        mapper: NetworkListenerMapper = NetworkListenerMapper(),
        currentUID: UInt32 = getuid(),
        now: @escaping @Sendable () -> Date = Date.init,
        schedule: ListenerHelperSchedule = ListenerHelperSchedule(),
        terminations: ListenerTerminationLedger = ListenerTerminationLedger()
    ) {
        self.provider = provider
        self.local = local
        self.mapper = mapper
        self.currentUID = currentUID
        self.now = now
        self.schedule = schedule
        self.terminations = terminations
    }

    public func collect() async throws -> InventoryContribution {
        let date = now()
        guard let provider else {
            return try await localContribution(at: date, failure: "Helper nicht eingerichtet", deniedProcessCount: 0)
        }
        // Nach „Prozess beenden …“ außerhalb des Takts: Die Wirkungsprüfung braucht den Stand aller Benutzer. Über
        // `reset()` statt eines eigenen Zweigs, damit ein abgebrochener Versuch beim nächsten Scan nachgeholt wird.
        if terminations.takeHelperRefresh() { schedule.reset() }
        // Ein Zustand für die ganze Messung (atomar gelesen): Ein gleichzeitiges `reset()` ändert ihn nicht mehr.
        let status = schedule.status(at: date)
        guard status.isDue else {
            return try await localContribution(at: date, failure: status.lastFailure,
                                         deniedProcessCount: status.lastDeniedProcessCount)
        }
        do {
            let scan = try await provider.listeningSockets()
            // Erst festschreiben, wenn der Coordinator den fertigen Beitrag übernimmt (`accept(_:)`): Läuft die
            // Aufbereitung über die Frist, fragt der nächste Scan den Helper erneut, statt ohne Einschränkung lokal zu
            // messen.
            let listeners = await queue.run { mapper.listeners(from: scan.sockets, at: date) }
            var result = contribution(listeners, at: date,
                                      deniedProcessCount: scan.deniedProcessCount)
            result.acceptanceToken = schedule.stageSuccess(attemptAt: date, deniedProcessCount: scan.deniedProcessCount,
                                                           resetGeneration: status.resetGeneration)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.info("Lauscher über den Helper nicht lesbar: \(error.readableDescription, privacy: .public)")
            schedule.recordFailure(attemptAt: date, failure: error.readableDescription,
                                   resetGeneration: status.resetGeneration)
            return try await localContribution(at: date, failure: error.readableDescription,
                                         deniedProcessCount: status.lastDeniedProcessCount)
        }
    }

    /// Schreibt den vorgemerkten Erfolg einer Helper-Messung fest, sobald der Coordinator ihren Beitrag übernommen hat.
    public func accept(_ contribution: InventoryContribution) {
        if let token = contribution.acceptanceToken { schedule.commit(token) }
    }

    /// Eigene Prozesse; mit `failure` als Einschränkung im Klartext und der Lücke der letzten Helper-Messung.
    private func localContribution(at date: Date, failure: String?, deniedProcessCount: Int) async throws -> InventoryContribution {
        try await queue.runThrowing {
            let scan = try local.listeningSockets()
            return contribution(
                mapper.listeners(from: scan.sockets, at: date), at: date, deniedProcessCount: deniedProcessCount,
                retryableLimitations: failure.map { ["\(Self.limitationPrefix) – \($0)"] } ?? [], limitedTo: currentUID,
                coversFullScope: false
            )
        }
    }

    /// Beitrag samt den vermerkten beendeten Lauschern, die dieser Scan nicht gesehen hat. `date` ist der Beginn von
    /// `collect()`, vor dem Lesen der Sockets (`ListenerTerminationLedger.settleEndedIDs(at:seen:)`).
    /// - Parameter deniedProcessCount: von der Helper-Messung nicht einsehbare Prozesse – bei ihr der gemessene Wert, bei
    ///   lokalen Zwischenmessungen der der letzten erfolgreichen Helper-Messung. Die Einschränkung bleibt so, bis eine
    ///   Helper-Messung ohne Verweigerung sie schließt (#142).
    private func contribution(
        _ listeners: [NetworkListener], at date: Date, deniedProcessCount: Int, retryableLimitations: [String] = [],
        limitedTo uid: UInt32? = nil, coversFullScope: Bool = true
    ) -> InventoryContribution {
        InventoryContribution(
            limitations: Self.deniedProcessLimitations(deniedProcessCount),
            retryableLimitations: retryableLimitations, networkListeners: listeners, listenersLimitedToUID: uid,
            endedListenerIDs: terminations.settleEndedIDs(at: date, seen: Set(listeners.map(\.id))),
            coversFullScope: coversFullScope
        )
    }
}

extension NetworkListenerSource {
    /// „3 geschützte Prozesse nicht einsehbar – ihre Netzwerkdienste sind nicht geprüft“, wenn die Helper-Messung
    /// Prozesse überspringen musste (EPERM/EACCES, auch als root etwa bei SIP-geschützten Prozessen möglich). Kein
    /// Fehler, aber keine vollständige Entwarnung; ein erneuter Scan ändert daran meist nichts (nicht behebbar).
    static func deniedProcessLimitations(_ count: Int) -> [String] {
        switch count {
        case ...0: []
        case 1: ["1 geschützter Prozess nicht einsehbar – seine Netzwerkdienste sind nicht geprüft"]
        default: ["\(count) geschützte Prozesse nicht einsehbar – ihre Netzwerkdienste sind nicht geprüft"]
        }
    }
}

/// Zeitpunkt und Ergebnis des letzten Helper-Versuchs von `NetworkListenerSource`. Ein Referenztyp, weil die Quelle
/// als `Sendable`-Struct kopiert wird und alle Kopien denselben Takt einhalten sollen. Ein abgebrochener Versuch wird
/// nicht vermerkt (`record` erst nach dem Ergebnis), damit der nächste Aufruf den Helper sofort wieder fragt.
///
/// Prüfen und Vermerken sind einzeln gesperrt, nicht als Einheit: Gleichzeitige `collect()` derselben Quelle schließt
/// innerhalb eines `ScanCoordinator` dessen `RunningSources` aus; mehrere Coordinator mit derselben Quelle (oder
/// demselben Takt) sind nicht geschützt und könnten den Helper doppelt fragen.
public final class ListenerHelperSchedule: Sendable {
    private struct State {
        var lastAttempt: Date?
        var lastFailure: String?
        /// Von der letzten erfolgreichen Helper-Messung übersprungene Prozesse (`ListeningSocketScan.deniedProcessCount`);
        /// ersetzt nur eine weitere erfolgreiche Helper-Messung, nie `reset()` oder ein Fehlschlag.
        var lastDeniedProcessCount = 0
        /// Erfolgreiche Helper-Messung, deren Beitrag noch nicht übernommen ist (`stageSuccess`/`commit`).
        var pending: PendingSuccess?
        /// Zählt `reset()`; ein danach festgeschriebener Erfolg setzt den Takt nicht wieder (der Reset gilt).
        var resetGeneration = 0
    }

    private struct PendingSuccess {
        let token: UUID
        let attempt: Date
        let deniedProcessCount: Int
        let resetGeneration: Int
    }

    /// Zustand zu Beginn einer Messung, atomar gelesen (`status(at:)`).
    struct Status {
        /// Der Helper ist zu fragen.
        let isDue: Bool
        let lastFailure: String?
        let lastDeniedProcessCount: Int
        /// Stand der Resets zu Beginn der Messung; `commit` setzt den Takt nur, wenn seither kein `reset()` kam.
        let resetGeneration: Int
    }

    private let interval: TimeInterval
    private let state = Mutex(State())

    public init(interval: TimeInterval = ListenerTiming.helperInterval) {
        self.interval = interval
    }

    /// Fälligkeit, Grund des letzten gescheiterten Versuchs und Lücke der letzten erfolgreichen Helper-Messung – in einem
    /// Zug gelesen. Fällig: noch nie gefragt, oder der letzte Versuch liegt mindestens `interval` zurück; springt die Uhr
    /// zurück, ebenfalls.
    func status(at date: Date) -> Status {
        state.withLock { state in
            let isDue = state.lastAttempt.map { last in
                let elapsed = date.timeIntervalSince(last)
                return elapsed >= interval || elapsed < 0
            } ?? true
            return Status(isDue: isDue, lastFailure: state.lastFailure, lastDeniedProcessCount: state.lastDeniedProcessCount,
                          resetGeneration: state.resetGeneration)
        }
    }

    /// Setzt nur den Abfragetakt zurück, damit der nächste `collect()` den Helper sofort fragt – etwa nach einer
    /// Registrierung oder Neuinstallation des Helpers oder „Jetzt scannen“. Die zuletzt gemessene Lücke
    /// (`lastDeniedProcessCount`) bleibt, bis eine erfolgreiche Helper-Messung sie ersetzt (#142).
    public func reset() {
        state.withLock {
            $0.lastAttempt = nil
            $0.resetGeneration += 1
        }
    }

    /// Merkt eine erfolgreiche Helper-Messung vor; wirksam erst mit `commit(_:)` (nach Übernahme ihres Beitrags). Bis
    /// dahin gilt der bisherige Zustand – der Helper bleibt fällig, Fehler und Lücke bleiben.
    /// - Parameter resetGeneration: `Status.resetGeneration` vom Beginn der Messung – ein `reset()` danach (etwa während
    ///   der Aufbereitung) bleibt so wirksam.
    func stageSuccess(attemptAt date: Date, deniedProcessCount: Int, resetGeneration: Int) -> UUID {
        let token = UUID()
        state.withLock {
            $0.pending = PendingSuccess(token: token, attempt: date, deniedProcessCount: deniedProcessCount,
                                        resetGeneration: resetGeneration)
        }
        return token
    }

    /// Schreibt die vorgemerkte Messung `token` fest. Fehler und Lücke ersetzt sie immer: Sie war eine vollständige,
    /// erfolgreiche Helper-Messung, deren Beitrag übernommen ist – ihre Werte stimmen für ihren Zeitpunkt, ein Reset
    /// verlangt nur eine frischere Abfrage, macht sie aber nicht falsch (und die nächste Messung ersetzt sie wieder).
    /// Den Zeitpunkt des letzten Versuchs setzt sie nur, wenn seit Beginn der Messung kein `reset()` kam – sonst fragt der
    /// nächste Scan den Helper wie angefordert. Eine ältere oder bereits ersetzte Vormerkung ist wirkungslos.
    func commit(_ token: UUID) {
        state.withLock { state in
            guard let pending = state.pending, pending.token == token else { return }
            state.pending = nil
            state.lastFailure = nil
            state.lastDeniedProcessCount = pending.deniedProcessCount
            if pending.resetGeneration == state.resetGeneration { state.lastAttempt = pending.attempt }
        }
    }

    /// Gescheiterter Versuch: Die Lücke der letzten erfolgreichen Messung bleibt. Den Takt setzt er wie `commit` nur,
    /// wenn seit Beginn der Messung (`resetGeneration`) kein `reset()` kam.
    func recordFailure(attemptAt date: Date, failure: String, resetGeneration: Int) {
        state.withLock {
            if $0.resetGeneration == resetGeneration { $0.lastAttempt = date }
            $0.lastFailure = failure
            $0.pending = nil
        }
    }
}
