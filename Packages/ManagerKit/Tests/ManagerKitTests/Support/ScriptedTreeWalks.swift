import Foundation
import Synchronization
@testable import ManagerKit

/// Durchläufe mit festgelegter Rechenzeit je Baum für die Komplettprüfung in Blöcken (#662): Ein Baum kostet `cost(path)`;
/// jeder Aufruf verbraucht davon höchstens sein Budget und meldet `partial`, solange etwas übrig ist. Am Ende liefert der
/// Durchlauf den echten Fingerabdruck (`CodeTreeFingerprint.read`), damit unveränderte Bäume zum Cache passen.
/// Protokolliert jeden begonnenen Durchlauf und jeden Abschnitt mit Zeitpunkt (`now`, am Ende des Abschnitts) und Priorität
/// des Threads. `spend` lässt die Rechenzeit eines Abschnitts als Wanduhr vergehen (etwa gedrosselt das Doppelte).
final class ScriptedTreeWalks: Sendable {
    struct Advance: Sendable {
        let path: String
        /// Laufende Nummer des Durchlaufs (über alle Bäume).
        let walk: Int
        let date: Date
        let budget: Duration?
        let cpuTime: Duration
        let qos: qos_class_t
        let finished: Bool
    }

    private struct State {
        var walks: [(path: String, date: Date)] = []
        var advances: [Advance] = []
    }

    private let state = Mutex(State())
    private let cost: @Sendable (String) -> Duration
    private let now: @Sendable () -> Date
    private let wall: @Sendable (Duration) -> Void

    init(cost: @escaping @Sendable (String) -> Duration, now: @escaping @Sendable () -> Date = Date.init,
         spend: @escaping @Sendable (Duration) -> Void = { _ in }) {
        self.cost = cost
        self.now = now
        wall = spend
    }

    /// Begonnene Durchläufe je Pfad, in Reihenfolge.
    var walks: [(path: String, date: Date)] { state.withLock { $0.walks } }
    var advances: [Advance] { state.withLock { $0.advances } }

    func walks(of path: String) -> [Date] { walks.filter { $0.path == path }.map(\.date) }

    var factory: @Sendable (String) -> (any CodeTreeWalking)? {
        { [self] path in
            let number = state.withLock { state in
                state.walks.append((path, now()))
                return state.walks.count - 1
            }
            return Walk(path: path, number: number, remaining: cost(path), owner: self)
        }
    }

    fileprivate func record(_ advance: Advance) { state.withLock { $0.advances.append(advance) } }
    fileprivate func pass(_ time: Duration) { wall(time) }
    fileprivate var date: Date { now() }

    private final class Walk: CodeTreeWalking, @unchecked Sendable {
        let path: String
        let number: Int
        var remaining: Duration
        var result: String??
        let owner: ScriptedTreeWalks

        init(path: String, number: Int, remaining: Duration, owner: ScriptedTreeWalks) {
            self.path = path
            self.number = number
            self.remaining = remaining
            self.owner = owner
        }

        func advance(cpuBudget: Duration?) -> CodeTreeWalkStep {
            if let result { return CodeTreeWalkStep(progress: .finished(result), cpuTime: .zero) }
            let used = min(remaining, cpuBudget ?? remaining)
            remaining -= used
            owner.pass(used)
            let progress: CodeTreeWalkStep.Progress
            if remaining > .zero {
                progress = .partial
            } else {
                let fingerprint = CodeTreeFingerprint.read(at: path)
                result = .some(fingerprint)
                progress = .finished(fingerprint)
            }
            owner.record(Advance(path: path, walk: number, date: owner.date, budget: cpuBudget, cpuTime: used,
                                 qos: qos_class_self(), finished: remaining == .zero))
            return CodeTreeWalkStep(progress: progress, cpuTime: used)
        }
    }
}
