import Synchronization
@testable import ManagerKit

/// Messquelle mit vorgegebenen Ergebnissen in Reihenfolge; das letzte wiederholt sich. Zählt die Aufrufe.
final class ScriptedMetricSource<Reading: Sendable>: MetricSource {
    private let results: Mutex<[Result<Reading, any Error>]>
    private let calls = Mutex(0)

    init(results: [Result<Reading, any Error>]) {
        precondition(!results.isEmpty, "mindestens ein Ergebnis")
        self.results = Mutex(results)
    }

    convenience init(readings: [Reading]) {
        self.init(results: readings.map { .success($0) })
    }

    var callCount: Int { calls.withLock { $0 } }

    func read() throws -> Reading {
        calls.withLock { $0 += 1 }
        let result = results.withLock { results in results.count > 1 ? results.removeFirst() : results[0] }
        return try result.get()
    }
}

/// Fehler einer Fake-Quelle.
struct SourceFailure: Error, Equatable {
    let message: String
}

/// Sammelt Werte aus nebenläufigen Closures (ein `Mutex` lässt sich nicht in escaping Closures einfangen).
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func append(_ value: Value) { storage.withLock { $0.append(value) } }

    var values: [Value] { storage.withLock { $0 } }
}
