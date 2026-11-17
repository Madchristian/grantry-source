import Foundation
import Synchronization
@testable import ManagerKit

/// Zählt vollständige Baum-Traversierungen (`CodeTreeFingerprint.read`) je Pfad für `DeepSignatureVerifier`;
/// `incomplete` simuliert einen nicht vollständig erfassbaren Baum (`nil`). Jede Traversierung wird mit Zeitpunkt
/// (`now`) und Priorität des lesenden Threads festgehalten.
final class CountingTreeFingerprint: Sendable {
    struct Read: Sendable {
        let path: String
        let date: Date
        let qos: qos_class_t
    }

    private let log = Mutex<[Read]>([])
    private let incomplete: Bool
    private let now: @Sendable () -> Date

    init(incomplete: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.incomplete = incomplete
        self.now = now
    }

    var count: Int { log.withLock(\.count) }
    var reads: [Read] { log.withLock { $0 } }

    /// Zeitpunkte der Traversierungen von `path`.
    func dates(of path: String) -> [Date] { reads.filter { $0.path == path }.map(\.date) }

    /// Fingerabdruck über den kanonischen Pfad: `FileFingerprint.target` macht aus einem Testordner unter `/private/var`
    /// den Pfad über den Ordner-Symlink `/var`, über den die Auflösung interner Links nicht läuft (sie gelten dann als
    /// extern). Echte Apps (`/Applications`, `~/Applications`) liegen nicht unter verlinkten Ordnern.
    static let canonical: @Sendable (String) -> String? = { path in
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return CodeTreeFingerprint.read(at: String(cString: resolved))
    }

    var reader: @Sendable (String) -> String? {
        { [self] path in
            log.withLock { $0.append(Read(path: path, date: now(), qos: qos_class_self())) }
            return incomplete ? nil : CodeTreeFingerprint.read(at: path)
        }
    }
}
