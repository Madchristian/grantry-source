import Foundation
import Synchronization
@testable import ManagerKit

/// Liefert feste laufende Prozesse und offene Pfade oder wirft; zählt die Aufrufe.
final class FakeOpenFileProbe: OpenFileProbing {
    struct Unreadable: Error {}

    private let openPaths: [OpenPath]?
    private let running: Set<String>
    private let calls = Mutex(0)

    /// `openPaths == nil`: Die Prozessliste ist nicht lesbar. `running`: zusätzlich laufende Prozesse ohne offene Pfade.
    init(_ openPaths: [OpenPath]? = [], running: Set<String> = []) {
        self.openPaths = openPaths
        self.running = running.union((openPaths ?? []).map(\.processName))
    }

    var callCount: Int { calls.withLock { $0 } }

    func usage(ofProcessesNamed names: Set<String>) throws -> ProcessUsage {
        calls.withLock { $0 += 1 }
        guard let openPaths else { throw Unreadable() }
        return ProcessUsage(running: running.intersection(names), openPaths: openPaths.filter { names.contains($0.processName) })
    }
}
