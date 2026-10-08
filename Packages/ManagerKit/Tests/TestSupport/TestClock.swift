import Synchronization

/// Deterministische `Clock` für Tests: Die Zeit steht, bis `advance(by:)` sie vorstellt. `sleep(until:)` suspendiert
/// bis dahin, echte Wartezeiten gibt es nicht.
///
/// Weil Schläfer asynchron (aus anderen Tasks) eintreffen, bietet die Uhr `waitForSleeper(until:)`: Tests warten damit,
/// bis ein Schlaf mit genau dieser Frist registriert ist, bevor sie die Zeit vorstellen.
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
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Watcher {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var watchers: [Int: Watcher] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
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
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    let matching = state.watchers.filter { $0.value.deadline == deadline }
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
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if Task.isCancelled || state.sleepers.values.contains(where: { $0.deadline == deadline }) {
                        return true
                    }
                    state.watchers[id] = Watcher(deadline: deadline, continuation: continuation)
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
