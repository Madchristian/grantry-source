import Foundation
import Synchronization
@testable import ManagerKit

/// Zählt vollständige Baum-Traversierungen (`CodeTreeFingerprint.read`) je Pfad für `DeepSignatureVerifier`;
/// `incomplete` simuliert einen nicht vollständig erfassbaren Baum (`nil`).
final class CountingTreeFingerprint: Sendable {
    private let reads = Mutex<[String]>([])
    private let incomplete: Bool

    init(incomplete: Bool = false) {
        self.incomplete = incomplete
    }

    var count: Int { reads.withLock(\.count) }

    var reader: @Sendable (String) -> String? {
        { [self] path in
            reads.withLock { $0.append(path) }
            return incomplete ? nil : CodeTreeFingerprint.read(at: path)
        }
    }
}
