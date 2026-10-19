import Foundation
import Synchronization
@testable import ManagerKit

/// Verschiebt nach `verify` in einen Scratch-Ordner statt in den echten Papierkorb. Mit `force(_:for:)` liefert er für
/// einen Pfad ein festes Ergebnis, ohne ihn anzufassen.
final class RecordingTrash: TrashPerforming {
    enum Forced {
        case outcome(TrashItemOutcome)
        /// Kein Eintrag im Bericht, nur `TrashReport.failure`.
        case missing(failure: String?)
    }

    let destination: URL
    private let moved = Mutex<[String]>([])
    private let forced = Mutex<[String: Forced]>([:])

    init(destination: URL) {
        self.destination = destination
    }

    var movedPaths: [String] { moved.withLock { $0 } }

    func force(_ result: Forced, for path: String) {
        forced.withLock { $0[path] = result }
    }

    func requestPermission() async -> TrashPermission { .granted }

    func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        var outcomes: [String: TrashItemOutcome] = [:]
        var failure: String?
        for candidate in candidates {
            switch forced.withLock({ $0[candidate.path] }) {
            case .outcome(let outcome):
                outcomes[candidate.path] = outcome
                continue
            case .missing(let reason):
                failure = reason
                continue
            case nil:
                break
            }
            if case .blocked(let reason) = verify(candidate) {
                outcomes[candidate.path] = .blocked(reason)
                continue
            }
            let target = destination.appending(path: UUID().uuidString)
            do {
                try FileManager.default.moveItem(atPath: candidate.path, toPath: target.path)
                moved.withLock { $0.append(candidate.path) }
                outcomes[candidate.path] = .trashed
            } catch {
                outcomes[candidate.path] = .remaining(error.localizedDescription)
            }
        }
        return TrashReport(outcomes: outcomes, failure: failure)
    }
}
