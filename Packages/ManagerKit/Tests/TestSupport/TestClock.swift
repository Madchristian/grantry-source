import Synchronization

/// Deterministische `Clock` für Tests: Die Zeit steht, bis `advance(by:)` sie vorstellt. `sleep(until:)` suspendiert
/// bis dahin, echte Wartezeiten gibt es nicht.
///
/// Weil Schläfer asynchron (aus anderen Tasks) eintreffen, bietet die Uhr `waitForSleeper(until:)`: Tests warten damit,
/// bis ein Schlaf mit genau dieser Frist registriert ist, bevor sie die Zeit vorstellen. `nextSleeperDeadline()` wartet
/// auf irgendeinen Schläfer und nennt die früheste Frist – für Abläufe, deren Fristen der Test nicht vorab kennt.
/// `nextSleeperDeadline(after:)` wartet auf einen Schläfer, der sich nach `registrations` angemeldet hat – etwa nachdem
/// ein Ablauf einen laufenden Schlaf abgebrochen und neu geplant hat.
public final class TestClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable {
        /// Abstand zum Startzeitpunkt der Uhr.
        public let offset: Duration

        public init(offset: Duration) { self.offset = offset }

        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        /// Laufende Nummer der Anmeldung (`registrations` danach).
        let registration: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Watcher {
        /// `nil`: jeder Schläfer.
        let deadline: Instant?
        /// Nur Schläfer, die sich danach angemeldet haben.
        let after: Int
        let continuation: CheckedContinuation<Void, Never>

        func matches(_ sleeper: Sleeper) -> Bool {
            sleeper.registration > after && deadline.map { sleeper.deadline == $0 } ?? true
        }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var registrations = 0
        var sleepers: [Int: Sleeper] = [:]
        var watchers: [Int: Watcher] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    /// Zahl der wartenden Schläfer.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    /// Zahl der bisher angemeldeten Schläfer, auch der beendeten.
    public var registrations: Int { state.withLock { $0.registrations } }
    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Unter der Sperre: Ein Abbruch vor der Registrierung wird hier gesehen, einer danach vom Handler.
                let pendingWatchers: [Watcher]? = state.withLock { state in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return nil
                    }
                    guard deadline > state.now else {
                        continuation.resume()
                        return nil
                    }
                    state.registrations += 1
                    let sleeper = Sleeper(deadline: deadline, registration: state.registrations, continuation: continuation)
                    state.sleepers[id] = sleeper
                    let matching = state.watchers.filter { $0.value.matches(sleeper) }
                    matching.keys.forEach { state.watchers.removeValue(forKey: $0) }
                    return Array(matching.values)
                }
                pendingWatchers?.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Stellt die Uhr vor und weckt alle Schläfer, deren Frist erreicht ist.
    ///
    /// - Returns: Anzahl der geweckten Schläfer. `0` belegt deterministisch, dass durch das Vorstellen nichts
    ///   ausgelöst wurde – ohne auf ein Ereignis warten zu müssen, das ausbleiben soll.
    @discardableResult
    public func advance(by duration: Duration) -> Int {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let dueIDs = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        due.forEach { $0.continuation.resume() }
        return due.count
    }

    /// Kehrt zurück, sobald ein Schläfer mit genau dieser Frist wartet – oder wenn der Test abgebrochen wird
    /// (etwa durch `.timeLimit`), damit ein fehlender Schläfer den Testlauf nicht blockiert.
    public func waitForSleeper(until deadline: Instant) async {
        await waitForSleeper(matching: deadline, after: 0)
    }

    /// Kehrt zurück, sobald irgendein Schläfer wartet, mit der frühesten Frist aller wartenden; `nil` nur nach Abbruch.
    public func nextSleeperDeadline() async -> Instant? {
        await nextSleeperDeadline(after: 0)
    }

    /// Wie `nextSleeperDeadline()`, aber erst, wenn ein Schläfer wartet, der sich nach `registrations` angemeldet hat.
    public func nextSleeperDeadline(after registrations: Int) async -> Instant? {
        await waitForSleeper(matching: nil, after: registrations)
        return state.withLock { $0.sleepers.values.map(\.deadline).min() }
    }

    /// `deadline == nil`: jeder Schläfer.
    private func waitForSleeper(matching deadline: Instant?, after registrations: Int) async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    let watcher = Watcher(deadline: deadline, after: registrations, continuation: continuation)
                    if Task.isCancelled || state.sleepers.values.contains(where: watcher.matches) {
                        return true
                    }
                    state.watchers[id] = watcher
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let watcher = state.withLock { $0.watchers.removeValue(forKey: id) }
            watcher?.continuation.resume()
        }
    }
}

extension TestClock.Instant {
    /// Startzeitpunkt jeder `TestClock`.
    public static let start = TestClock.Instant(offset: .zero)

    /// `start + offset`, für gut lesbare Fristen in Tests.
    public static func at(_ offset: Duration) -> TestClock.Instant { start.advanced(by: offset) }
}
