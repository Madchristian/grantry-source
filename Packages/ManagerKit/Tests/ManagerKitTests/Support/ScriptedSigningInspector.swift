import Synchronization
@testable import ManagerKit

/// Liefert der Reihe nach `results` (das letzte wiederholt sich) und zählt die Prüfungen – etwa erst eine
/// Zeitüberschreitung, dann ein echtes Ergebnis.
final class ScriptedSigningInspector: SigningInspecting {
    private let state: Mutex<(results: [SigningInspection], calls: Int)>

    init(_ results: [SigningInspection]) { state = Mutex((results, 0)) }

    var calls: Int { state.withLock { $0.calls } }

    func inspection(ofPath path: String) -> SigningInspection {
        state.withLock { state in
            state.calls += 1
            return state.results.count > 1 ? state.results.removeFirst() : state.results[0]
        }
    }

    func inspect(path: String) -> SigningInfo { inspection(ofPath: path).info }
}
