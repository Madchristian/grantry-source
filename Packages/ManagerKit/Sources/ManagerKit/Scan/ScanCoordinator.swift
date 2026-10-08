import Foundation
import os
import Synchronization

/// Führt alle Quellen parallel aus und fasst die Ergebnisse zu einem Snapshot zusammen.
/// Fehler einer Quelle landen als `SourceError` im Snapshot, statt den Scan abzubrechen.
///
/// Jede Quelle hat eine Frist (`sourceTimeout`, Review N5): Antwortet sie nicht rechtzeitig, gilt sie als
/// fehlgeschlagen („Zeitüberschreitung“), ihre Einträge werden fortgeschrieben, und der Scan wartet nicht weiter – auch
/// nicht, wenn die Quelle den Abbruch ignoriert (sie läuft dann im Hintergrund zu Ende). Solange sie das tut, starten
/// weitere Scans sie nicht erneut, sondern melden sofort `stillRunningMessage` (Review N4) – hängende Abfragen stapeln
/// sich so nicht. Der Merker gilt je Quelle und für alle Kopien dieses Koordinators.
public struct ScanCoordinator: Sendable {
    /// Fehlertext einer Quelle, deren vorige Abfrage nach Fristablauf noch läuft.
    public static let stillRunningMessage = "Läuft noch – die vorige Abfrage hat ihre Frist überschritten"
    /// Frist je Quelle; der langsamste übliche Scan (App-Inventar beim ersten Start) braucht wenige Sekunden.
    public static let defaultSourceTimeout: Duration = .seconds(120)

    private let sources: [any InventorySource]
    private let securityPolicy: SecurityPolicy
    private let sourceTimeout: Duration
    private let currentUID: UInt32
    private let now: @Sendable () -> Date
    /// Indizes der Quellen, deren `collect()` gerade läuft (über Scans hinweg).
    private let running = RunningSources()
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "scan")

    /// - Parameters:
    ///   - securityPolicy: bewertet die Sicherheitsprüfungen nach dem Carry-Forward neu.
    ///   - sourceTimeout: Frist je Quelle.
    ///   - currentUID: Benutzer der App; trennt bei der Entprellung eigene von fremden Lauschern (für Tests
    ///     injizierbar). Gibt die Lauscher-Quelle `listenersLimitedToUID` mit, hat diese Vorrang.
    public init(
        sources: [any InventorySource],
        securityPolicy: SecurityPolicy = .standard,
        sourceTimeout: Duration = defaultSourceTimeout,
        currentUID: UInt32 = getuid(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sources = sources
        self.securityPolicy = securityPolicy
        self.sourceTimeout = sourceTimeout
        self.currentUID = currentUID
        self.now = now
    }

    /// Die Quellen dieses Koordinators – was ein Vollscan abdeckt (`MonitoringState.activeSources`, #142).
    public var sourceIDs: Set<SourceID> { Set(sources.map(\.id)) }

    /// Sendable-Ergebnis einer Quelle (`any Error` ist nicht Sendable).
    private enum Outcome: Sendable {
        case success(InventoryContribution)
        case failure(String)
    }

    /// Scannt alle Quellen (mit `only` eine Auswahl). Neue Einträge folgen der Reihenfolge der Quellen, nicht ihrer
    /// Fertigstellung.
    ///
    /// - Parameter previous: letzter gespeicherter Snapshot; Einträge fehlgeschlagener Quellen werden daraus
    ///   fortgeschrieben. Die Baseline ist `previous.baselineSources` vereinigt mit den erfolgreichen Quellen
    ///   dieses Scans (beim ersten Scan nur Letztere). Sicherheitsprüfungen übernehmen daraus Fakten ausgefallener
    ///   Prüfungen und das `firstSeenAt` ausstehender Updates; ihre Ampel wird danach zu `startedAt` neu bewertet.
    ///   Apps übernehmen daraus die letzte bekannte Signatur, Architektur und Herkunft sowie einen erkannten
    ///   Team-ID-Wechsel; Apps in nicht lesbaren Ordnern (`InventoryContribution.incompleteFolders`) werden übernommen.
    ///   Ebenso Agenten-Einträge aus nicht lesbaren Dateien (`AgentContribution.incompleteFiles`) und Autostart-Einträge
    ///   aus nicht auswertbaren Plists (`InventoryContribution.incompletePlistPaths`, als fortgeschrieben markiert).
    ///   Hat die Lauscher-Quelle geliefert, werden fehlende Lauscher entprellt (`Snapshot.carryingForwardListeners`);
    ///   hat sie vollständig geliefert (alle Benutzer), ist `hasCompleteListenerBaseline` fortan gesetzt. Jede
    ///   Quelle, die ihren vollen Umfang liefert, erhält `startedAt` als Lieferzeitpunkt (`Snapshot.lastDeliveryBySource`);
    ///   eine Zwischenmessung (`InventoryContribution.coversFullScope == false`) nur als
    ///   `Snapshot.lastInterimDeliveryBySource`, ausgefallene Quellen behalten beides aus `previous`.
    /// - Parameter only: Teilscan; nur diese Quellen werden gefragt, nicht gewählte übernehmen Einträge, Fehler und
    ///   Einschränkungen unverändert aus `previous` (`Snapshot.removingRecords(of:)`). Ohne `previous` wird voll
    ///   gescannt. Die Schritte nach dem Sammeln laufen wie beim Vollscan; mit dem übernommenen Zustand sind sie
    ///   idempotent, ein Teilscan ohne Änderung ist daher äquivalent zu `previous`. Ausnahme: Auch übernommene
    ///   Sicherheitsprüfungen bewertet `carryingForwardSecurityState` zu `startedAt` neu – eine zeitabhängige Ampel
    ///   (etwa ein lange ausstehendes Update) kann daher auch in einem Teilscan kippen.
    /// Jede Quelle erfährt über `InventorySource.accept(_:)`, dass ihr Beitrag übernommen wurde – nicht bei Abbruch des
    /// Scans und nicht nach Fristablauf (dann gilt sie als fehlgeschlagen).
    /// - Throws: ausschließlich `CancellationError`, wenn der aufrufende Task abgebrochen wurde. Ein Abbruch ist
    ///   kein Quellenfehler: Als `SourceError` erfasst, würde er fortgeschrieben und wie ein Ausfall aussehen.
    public func scan(
        previous: Snapshot? = nil, only: Set<SourceID>? = nil
    ) async throws(CancellationError) -> Snapshot {
        let startedAt = now()
        let selected = previous == nil ? nil : only
        let indices = sources.indices.filter { selected?.contains(sources[$0].id) ?? true }
        let outcomes = await collectOutcomes(of: indices)
        if Task.isCancelled { throw CancellationError() }

        var snapshot = if let previous, let selected {
            previous.removingRecords(of: selected)
        } else {
            Snapshot(takenAt: startedAt, grants: [], autostartItems: [], sourceErrors: [],
                     baselineSources: previous?.baselineSources ?? [],
                     hasCompleteListenerBaseline: previous?.hasCompleteListenerBaseline ?? false,
                     lastDeliveryBySource: previous?.lastDeliveryBySource ?? [:],
                     lastInterimDeliveryBySource: previous?.lastInterimDeliveryBySource ?? [:])
        }
        snapshot.takenAt = startedAt
        var incompleteFolders: [String] = []
        var incompletePlistPaths: [String] = []
        var agents = AgentContribution()
        var listenerScan: ListenerScanState?
        for (index, outcome) in zip(indices, outcomes) {
            let source = sources[index]
            switch outcome {
            case .success(let contribution):
                source.accept(contribution)
                incompleteFolders += contribution.incompleteFolders
                incompletePlistPaths += contribution.incompletePlistPaths
                agents.append(contribution.agents)
                snapshot.sourceLimitations += contribution.limitations.map { SourceLimitation(source: source.id, message: $0) }
                    + contribution.retryableLimitations.map {
                        SourceLimitation(source: source.id, message: $0, isRetryable: true)
                    }
                snapshot.baselineSources.insert(source.id)
                if contribution.coversFullScope {
                    snapshot.lastDeliveryBySource[source.id] = startedAt
                    snapshot.lastInterimDeliveryBySource[source.id] = nil
                } else {
                    snapshot.lastInterimDeliveryBySource[source.id] = startedAt
                }
                snapshot.grants += contribution.grants
                snapshot.autostartItems += contribution.autostartItems
                snapshot.securityChecks += contribution.securityChecks
                snapshot.installedApps += contribution.installedApps
                snapshot.networkListeners += contribution.networkListeners
                if source.id == .networkListeners {
                    let isLimited = contribution.listenersLimitedToUID != nil
                    listenerScan = ListenerScanState(currentUID: contribution.listenersLimitedToUID ?? currentUID,
                                                     isLimited: isLimited, ended: contribution.endedListenerIDs)
                    if !isLimited { snapshot.hasCompleteListenerBaseline = true }
                }
            case .failure(let message):
                Self.logger.error("Quelle \(source.id.rawValue, privacy: .public) fehlgeschlagen: \(message, privacy: .public)")
                snapshot.sourceErrors.append(SourceError(source: source.id, message: message))
            }
        }
        let carried = snapshot
            .carryingForwardRecords(ofFailedSourcesFrom: previous)
            .carryingForwardApps(inIncompleteFolders: incompleteFolders, from: previous)
            .carryingForwardAutostartItems(inIncompletePlistPaths: incompletePlistPaths, from: previous)
            .addingAgents(agents, carryingForwardFrom: previous)
            .carryingForwardSecurityState(from: previous, policy: securityPolicy, now: startedAt)
            .carryingForwardAppState(from: previous)
        guard let listenerScan else { return carried }
        return carried.carryingForwardListeners(from: previous, currentUID: listenerScan.currentUID,
                                                isLimited: listenerScan.isLimited, ended: listenerScan.ended)
    }

    /// Ob die Lauscher-Quelle in diesem Scan geliefert hat, für welchen Benutzer und ob nur eigene Sockets lesbar waren.
    private struct ListenerScanState {
        let currentUID: UInt32
        let isLimited: Bool
        let ended: Set<String>
    }

    /// Ergebnis einer Quelle samt ihrer Position in der Auswahl (`collectOutcomes(of:)`).
    ///
    /// Bewusst ein Struct statt eines `(Int, Outcome)`-Tupels: Mit Swift 6.4 unter `-O` kam der Index eines solchen
    /// Tupels aus der Task-Gruppe falsch an (meist 0), Ergebnisse landeten so bei fremden Quellen oder fielen weg.
    private struct IndexedOutcome: Sendable {
        let index: Int
        let outcome: Outcome
    }

    /// Führt die Quellen mit den Indizes `indices` (in `sources`) parallel aus; das Ergebnis folgt der Reihenfolge von
    /// `indices` und hat für jede gewählte Quelle genau einen Eintrag – eine Quelle ohne Ergebnis gilt als
    /// fehlgeschlagen, statt die Zuordnung zu verschieben. Der Merker `running` gilt je Index in `sources`, damit ein
    /// Teilscan keine Quelle erneut startet, die ein Vollscan noch abfragt (und umgekehrt).
    private func collectOutcomes(of indices: [Int]) async -> [Outcome] {
        let timeout = sourceTimeout, running = running
        return await withTaskGroup(of: IndexedOutcome.self) { group in
            for (position, index) in indices.enumerated() {
                let source = sources[index]
                group.addTask {
                    guard running.begin(index) else {
                        return IndexedOutcome(index: position, outcome: .failure(Self.stillRunningMessage))
                    }
                    return IndexedOutcome(index: position, outcome: await Self.outcome(of: source, timeout: timeout) {
                        running.end(index)
                    })
                }
            }
            var outcomes = [Outcome?](repeating: nil, count: indices.count)
            for await result in group { outcomes[result.index] = result.outcome }
            return outcomes.map { $0 ?? .failure("Kein Ergebnis geliefert") }
        }
    }

    /// Ergebnis von `source`, höchstens nach `timeout`. Sammeln und Frist laufen als eigene Tasks; das erste Ergebnis
    /// gilt (`OutcomeRace`). Ein Abbruch des Scans beendet das Warten sofort (das Ergebnis zählt dann nicht).
    /// `onCollectEnd` läuft, sobald `collect()` tatsächlich endet – auch lange nach der Frist.
    private static func outcome(
        of source: any InventorySource, timeout: Duration, onCollectEnd: @escaping @Sendable () -> Void
    ) async -> Outcome {
        let race = OutcomeRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation)
                let work = Task {
                    defer { onCollectEnd() }
                    do { race.finish(.success(try await source.collect())) }
                    catch { race.finish(.failure(error.readableDescription)) }
                }
                let deadline = Task {
                    try? await Task.sleep(for: timeout)
                    if race.finish(.failure(timeoutMessage(timeout))) { work.cancel() }
                }
                race.onFinish { work.cancel(); deadline.cancel() }
            }
        } onCancel: {
            race.finish(.failure("Abgebrochen"))
        }
    }

    /// „Zeitüberschreitung: keine Antwort nach 120 s“ (Sekunden mit Komma, ohne Nachkommastellen bei ganzen).
    static func timeoutMessage(_ timeout: Duration) -> String {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let text = seconds.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "de_DE")))
        return "Zeitüberschreitung: keine Antwort nach \(text) s"
    }

    /// Quellen, deren `collect()` läuft; `begin` scheitert, solange die Quelle noch läuft.
    private final class RunningSources: Sendable {
        private let indices = Mutex(Set<Int>())

        func begin(_ index: Int) -> Bool { indices.withLock { $0.insert(index).inserted } }
        func end(_ index: Int) { _ = indices.withLock { $0.remove(index) } }
    }

    /// Wettlauf zwischen Quelle, Frist und Abbruch: Das erste `finish` gilt und setzt die Continuation fort (auch wenn
    /// sie erst danach per `start` kommt), alle weiteren sind wirkungslos. `onFinish` räumt danach die übrigen Tasks ab.
    private final class OutcomeRace: Sendable {
        private struct State {
            var result: Outcome?
            var continuation: CheckedContinuation<Outcome, Never>?
            var cleanup: (@Sendable () -> Void)?
        }

        /// Was nach dem ersten `finish` außerhalb der Sperre noch zu tun ist (Struct statt Tupel).
        private struct Pending {
            let continuation: CheckedContinuation<Outcome, Never>?
            let cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func start(_ continuation: CheckedContinuation<Outcome, Never>) {
            let result: Outcome? = state.withLock { state in
                if state.result == nil { state.continuation = continuation }
                return state.result
            }
            if let result { continuation.resume(returning: result) }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let isFinished = state.withLock { state in
                if state.result == nil { state.cleanup = cleanup }
                return state.result != nil
            }
            if isFinished { cleanup() }
        }

        /// `true`, wenn dieses Ergebnis gilt (das erste).
        @discardableResult
        func finish(_ outcome: Outcome) -> Bool {
            let pending: Pending? = state.withLock { state in
                guard state.result == nil else { return nil }
                state.result = outcome
                defer { state.continuation = nil; state.cleanup = nil }
                return Pending(continuation: state.continuation, cleanup: state.cleanup)
            }
            guard let pending else { return false }
            pending.continuation?.resume(returning: outcome)
            pending.cleanup?()
            return true
        }
    }
}
