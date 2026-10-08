import Foundation
import Synchronization
@testable import ManagerKit

/// Quelle mit je Aufruf vorgegebenem Ergebnis (das letzte wiederholt sich), die ihre Aufrufe zählt. `starts` meldet
/// jeden Aufruf, sobald er beginnt. Mit `latch` hält jeder Aufruf an (auch über einen Abbruch hinweg), bis der Test ihn
/// freigibt – wie eine Quelle, die an einem Systemaufruf hängt.
final class CountingSource: InventorySource, Sendable {
    /// Fehler mit dem Text „kaputt“.
    struct Failure: Error, CustomStringConvertible {
        var description: String { "kaputt" }
    }

    let id: SourceID
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let script: [Result<InventoryContribution, Failure>]
    private let latch: Latch?
    private let calls = Mutex(0)

    init(_ id: SourceID, script: [Result<InventoryContribution, Failure>], latch: Latch? = nil) {
        precondition(!script.isEmpty)
        self.id = id
        self.script = script
        self.latch = latch
        (starts, started) = AsyncStream<Void>.makeStream()
    }

    convenience init(
        _ id: SourceID, _ result: Result<InventoryContribution, Failure> = .success(InventoryContribution()),
        latch: Latch? = nil
    ) {
        self.init(id, script: [result], latch: latch)
    }

    var callCount: Int { calls.withLock { $0 } }

    func collect() async throws -> InventoryContribution {
        let index = calls.withLock { calls in
            defer { calls += 1 }
            return calls
        }
        started.yield()
        if let latch {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    latch.wait()
                    continuation.resume()
                }
            }
        }
        return try script[min(index, script.count - 1)].get()
    }
}
