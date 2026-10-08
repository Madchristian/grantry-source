import Synchronization
@testable import ManagerKit

/// Liefert immer `result` und zeichnet die geprüften Pfade in Aufrufreihenfolge auf.
final class RecordingSigningInspector: SigningInspecting {
    private let result: SigningInfo
    private let recorded = Mutex<[String]>([])

    init(result: SigningInfo) { self.result = result }

    var paths: [String] { recorded.withLock { $0 } }

    func inspect(path: String) -> SigningInfo {
        recorded.withLock { $0.append(path) }
        return result
    }
}
