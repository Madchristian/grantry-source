import Foundation
import Synchronization

/// Merkt sich die Ergebnisse eines `SigningInspecting` pro Pfad, solange der `FileFingerprint` des Ziels gleich bleibt
/// – wie `AppResolver`: Ein aktualisiertes oder ausgetauschtes Programm wird neu geprüft. Symlinks werden aufgelöst;
/// Pfade ohne lesbare Attribute werden jedes Mal geprüft und nicht gespeichert, ebenso Zeitüberschreitungen
/// (`SigningInspection.timedOut`, Review M1) – der nächste Scan prüft erneut.
///
/// Die Prüfung selbst läuft außerhalb der Sperre; prüfen zwei Aufrufer denselben neuen Pfad gleichzeitig, gewinnt
/// der letzte Eintrag – beide Ergebnisse sind gleichwertig.
public final class CachingSigningInspector: SigningInspecting {
    private let inspector: any SigningInspecting
    private let cache = Mutex(FingerprintCache<SigningInfo>())

    public init(inspector: any SigningInspecting = SecuritySigningInspector()) {
        self.inspector = inspector
    }

    public func inspect(path: String) -> SigningInfo {
        inspection(ofPath: path).info
    }

    public func inspection(ofPath path: String) -> SigningInspection {
        let target = FileFingerprint.target(of: path)
        guard let fingerprint = FileFingerprint(of: target) else {
            cache.withLock { $0.removeValue(for: path) }
            return inspector.inspection(ofPath: target)
        }
        if let cached = cache.withLock({ $0.value(for: path, matching: fingerprint) }) { return .completed(cached) }
        let inspection = inspector.inspection(ofPath: target)
        if case .completed(let info) = inspection {
            cache.withLock { $0.store(info, for: path, fingerprint: fingerprint) }
        }
        return inspection
    }
}
