import Synchronization
@testable import ManagerKit

/// Delegiert an `StubAppResolver` und zählt die Auflösungen.
final class CountingResolver: AppResolving {
    private let count = Mutex(0)
    private let stub = StubAppResolver()

    var calls: Int { count.withLock { $0 } }

    func resolve(bundleID: String) async -> AppIdentity {
        count.withLock { $0 += 1 }
        return await stub.resolve(bundleID: bundleID)
    }

    func resolve(path: String) async -> AppIdentity {
        count.withLock { $0 += 1 }
        return await stub.resolve(path: path)
    }
}
