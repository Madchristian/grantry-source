import Foundation
import Synchronization
import TestSupport
@testable import ManagerKit

/// Reverse-DNS mit festen Namen; mit `gate` hält jede Abfrage an, bis der Test sie freigibt. `calls` meldet jede
/// begonnene Abfrage.
final class FakeReverseDNS: ReverseDNSLookup {
    let calls: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let names: [String: String]
    private let gate: Gate?
    private let log = Mutex<[String]>([])

    init(_ names: [String: String], gate: Gate? = nil) {
        self.names = names
        self.gate = gate
        (calls, continuation) = AsyncStream.makeStream(of: String.self)
    }

    var lookedUp: [String] { log.withLock { $0 } }

    func hostName(for address: String) async -> String? {
        log.withLock { $0.append(address) }
        continuation.yield(address)
        if let gate { try? await gate.wait() }
        return names[address]
    }
}

/// Von Hand vorgestellte `ContinuousClock`-Zeit.
final class MutableInstant: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) { instant.withLock { $0 += duration } }
}
