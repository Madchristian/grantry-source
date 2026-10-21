import Foundation
import Security

/// Ergebnis der vollständigen Signaturprüfung eines App-Bundles oder Programms.
public enum DeepSignatureVerdict: Hashable, Sendable, Codable {
    /// Signatur, Hauptprogramm und versiegelte Ressourcen stimmen überein.
    case valid
    /// Signatur oder versiegelter Inhalt wurde nachträglich verändert; `status` ist der Fehlercode von
    /// Security.framework (z. B. `errSecCSResourceDirectoryFailed`, `errSecCSBadResource`), Klartext in
    /// `failureReason`.
    case invalid(status: Int32)
    /// Nicht beurteilbar: Pfad fehlt oder ist kein Code-Objekt, unsigniert (das bewerten andere Regeln) oder ein
    /// Fehler, der nichts über Manipulation aussagt.
    case unverifiable
    /// Nicht prüfbar, weil das Bundle Sonderdateien (FIFO, Socket, Gerät) enthält: Die Prüfung öffnet jede versiegelte
    /// Datei und könnte daran unbegrenzt hängen. Echte Apps enthalten keine – `InvalidSignatureRule` meldet es (mittel).
    case containsSpecialFiles

    public var isInvalid: Bool {
        if case .invalid = self { true } else { false }
    }

    /// Klartext zu `invalid(status:)` samt Fehlercode, etwa „Ressourcen des Bundles verändert (Fehler -67023)“;
    /// `nil` für andere Ergebnisse.
    public var failureReason: String? {
        guard case .invalid(let status) = self else { return nil }
        return "\(Self.tamperingReasons[status] ?? "unbekannter Fehler") (Fehler \(status))"
    }

    /// Fehlercodes, die auf veränderte Signatur oder veränderten versiegelten Inhalt hinweisen, mit Klartext nach
    /// den Kommentaren in `Security/CSCommon.h`.
    static let tamperingReasons: [OSStatus: String] = [
        errSecCSSignatureFailed: "Programm oder Signatur wurden verändert",  // -67061
        errSecCSResourcesNotSealed: "Ressourcen sind vorhanden, aber nicht durch die Signatur versiegelt",  // -67057
        errSecCSResourcesNotFound: "versiegelte Ressourcen fehlen",  // -67056
        errSecCSResourcesInvalid: "Verzeichnis der versiegelten Ressourcen ist ungültig",  // -67055
        // „a sealed resource is missing or invalid“ – auch bei nachträglich hinzugefügten Dateien.
        errSecCSBadResource: "versiegelte Datei fehlt, wurde verändert oder hinzugefügt",  // -67054
        errSecCSResourceRulesInvalid: "Regeln für die versiegelten Ressourcen sind ungültig",  // -67053
        errSecCSSignatureInvalid: "Signatur ist ungültig oder hat ein unbekanntes Format",  // -67045
        errSecCSInfoPlistFailed: "Info.plist oder Signatur wurden verändert",  // -67030
        // „invalid resource directory (directory or signature have been modified)“
        errSecCSResourceDirectoryFailed: "Ressourcen des Bundles verändert",  // -67023
        errSecCSBadNestedCode: "eingebetteter Code wurde verändert oder ist ungültig",  // -67021
        errSecCSUnsealedAppRoot: "unversiegelte Dateien im Hauptverzeichnis des Bundles",  // -67014
        errSecCSBadMainExecutable: "Hauptprogramm hat die Prüfung nicht bestanden",  // -67010
        errSecCSUnsealedFrameworkRoot: "unversiegelte Dateien im Hauptverzeichnis eines eingebetteten Frameworks",  // -67008
    ]
}

/// Ausgang einer Tiefenprüfung (Review M1, analog `SigningInspection`): ein Ergebnis oder eine Zeitüberschreitung bzw.
/// ein erschöpfter `BlockingCallGuard`. Eine Zeitüberschreitung sagt nichts über die Signatur und wird nie gemerkt.
public enum DeepSignatureValidation: Hashable, Sendable {
    case completed(DeepSignatureVerdict)
    case timedOut

    /// Das Ergebnis; nach einer Zeitüberschreitung `.unverifiable`.
    public var verdict: DeepSignatureVerdict {
        switch self {
        case .completed(let verdict): verdict
        case .timedOut: .unverifiable
        }
    }

    /// `true` für ein Ergebnis, das sich bis zur nächsten Änderung des Ziels merken lässt.
    public var isConclusive: Bool { self != .timedOut }
}

/// Führt die vollständige Signaturprüfung synchron aus. Kann bei großen Bundles Minuten dauern.
public protocol SignatureValidating: Sendable {
    func validate(path: String) -> DeepSignatureVerdict
    /// Wie `validate(path:)`, unterscheidet aber eine Zeitüberschreitung (`.timedOut`) vom echten Ergebnis – nur
    /// Letzteres darf der `DeepSignatureVerifier` cachen. Standard: `validate(path:)` gilt als abgeschlossen.
    func validation(ofPath path: String) -> DeepSignatureValidation
}

extension SignatureValidating {
    public func validation(ofPath path: String) -> DeepSignatureValidation {
        .completed(validate(path: path))
    }
}

/// Vollständige Prüfung über Security.framework: `SecStaticCodeCheckValidity` **ohne** `kSecCSBasicValidateOnly`,
/// also mit den Hashes von Hauptprogramm und allen versiegelten Ressourcen (wie `spctl --assess` bzw.
/// `codesign --verify`), dazu `kSecCSCheckAllArchitectures` (auch die nicht nativen Slices, die unter Rosetta
/// laufen könnten) und `noNetworkAccess` (keine Sperrlisten-Abfragen).
///
/// Auf dem Entwicklungs-Mac (2026-09) ergab das dieselben Befunde wie `spctl`: iCUE „invalid resource directory“
/// (`-67023`), Apps, die in ihr eigenes Bundle schreiben, „a sealed resource is missing or invalid“ (`-67054`);
/// alle übrigen Drittanbieter-Apps gültig. `kSecCSStrictValidate` bleibt aus, weil es auch veraltete, aber
/// unveränderte Signaturformate ablehnt. Laufzeit: kleine Apps < 0,1 s, Electron-Apps 1–10 s, Xcode ≈ 110 s,
/// Logic Pro ≈ 63 s.
///
/// **Hänger**: Die Prüfung öffnet jede versiegelte Datei. Vorab durchsucht der Validator daher den ganzen Bundle-Baum
/// per `lstat` (`FileType.specialFiles(inTreeAt:limits:)`, mit Grenzen für `stat` auf Symlink-Ziele) und meldet
/// Sonderdateien als `containsSpecialFiles`, statt zu prüfen; dazu die Vorprüfung wie bei `SecuritySigningInspector.staticCode(at:)` und eine großzügige Zeitgrenze
/// (`timeout`, `BlockingCallGuard.deepValidation`) – danach `.timedOut` („nicht prüfbar (Zeitüberschreitung)“ im
/// Protokoll), und die Warteschlange des `DeepSignatureVerifier` läuft weiter.
public struct SecuritySignatureValidator: SignatureValidating {
    /// Frist je Prüfung: gut das Fünffache der längsten gemessenen (Xcode ≈ 110 s).
    public static let defaultTimeout: Duration = .seconds(600)

    private let timeout: Duration
    private let callGuard: BlockingCallGuard

    public init() {
        self.init(timeout: Self.defaultTimeout)
    }

    init(timeout: Duration, callGuard: BlockingCallGuard = .deepValidation) {
        self.timeout = timeout
        self.callGuard = callGuard
    }

    private static let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures).union(.noNetworkAccess)

    /// Fehlercodes, die auf veränderte Signatur oder veränderten versiegelten Inhalt hinweisen. Alle übrigen (z. B.
    /// fehlende Leserechte) gelten als `unverifiable` – ein Befund der Stufe „hoch“ braucht einen klaren Beleg.
    static let tamperingStatuses = Set(DeepSignatureVerdict.tamperingReasons.keys)

    public func validate(path: String) -> DeepSignatureVerdict {
        validation(ofPath: path).verdict
    }

    public func validation(ofPath path: String) -> DeepSignatureValidation {
        let validation = callGuard.run(timeout: timeout) { Self.validationWithoutTimeLimit(path: path) } ?? .timedOut
        if validation == .timedOut {
            SecuritySigningInspector.logger.error("Tiefenprüfung von \(PathDisplay.abbreviatingHome(path), privacy: .public) nicht prüfbar (Zeitüberschreitung)")
        }
        return validation
    }

    /// Ohne Frist des Guards; die Suche nach Sonderdateien hat eigene Grenzen – erreicht sie eine, zählt das wie eine
    /// Zeitüberschreitung (nicht gecacht, `DeepSignatureVerifier.timeoutRetryDelay`).
    static func validationWithoutTimeLimit(
        path: String, limits: FileType.SpecialFileScanLimits = .standard
    ) -> DeepSignatureValidation {
        switch FileType.specialFiles(inTreeAt: path, limits: limits) {
        case .found: return .completed(.containsSpecialFiles)
        case .incomplete: return .timedOut
        case .clean: break
        }
        return .completed(SecuritySigningInspector.staticCode(at: path)
            .map { verdict(for: SecStaticCodeCheckValidity($0, flags, nil)) } ?? .unverifiable)
    }

    static func verdict(for status: OSStatus) -> DeepSignatureVerdict {
        if status == errSecSuccess { return .valid }
        return tamperingStatuses.contains(status) ? .invalid(status: status) : .unverifiable
    }
}

/// Wie gründlich `DeepSignatureVerifier.cachedVerdicts(for:revalidation:)` ein gespeichertes Ergebnis bestätigt (#259).
public enum DeepSignatureRevalidation: Sendable {
    /// Vollständige Metadaten des Code-Baums (`CodeTreeFingerprint.read`) – für Vollscans.
    case completeTree
    /// Nur billige Bundle-Metadaten (`CodeTreeFingerprint.stamp`) gegen den Stand der letzten Bestätigung durch
    /// `completeTree` oder `verify(path:)`; fehlt sie oder weichen die Metadaten ab, wie `completeTree`. Für die
    /// Teilscans alle 60 s: Eine in place überschriebene Ressource bei unverändertem Siegel erkennt erst der nächste
    /// Vollscan.
    case bundleMetadata
}

/// Serielle Tiefenprüfung außerhalb des kooperativen Pools. Wiederverwendung nur bei vollständig
/// gleichem Code-Baum vor und nach der Prüfung, optional über App-Neustarts hinweg; Teilscans dazwischen
/// bestätigen nur billige Bundle-Metadaten (`DeepSignatureRevalidation.bundleMetadata`, nur im Prozess).
/// Metadatenabfragen haben eine eigene Queue und bleiben auch während langer Prüfungen bedienbar.
/// Zeitüberschreitungen werden nicht persistiert; die Wiederholpause gilt nur für denselben Baum.
public actor DeepSignatureVerifier {
    public static let timeoutRetryDelay: TimeInterval = 30 * 60

    private let validator: any SignatureValidating
    private let now: @Sendable () -> Date
    private let cacheURL: URL?
    private let treeFingerprint: @Sendable (String) -> String?
    private let queue = DispatchQueue(label: "de.cstrube.Grantry.deep-signature", qos: .background)
    private let metadataQueue = DispatchQueue(label: "de.cstrube.Grantry.signature-metadata", qos: .utility)
    private var cache: DeepSignatureCache?
    private var timeouts: [String: (fingerprint: String, date: Date)] = [:]
    private var running: [String: RunningCheck] = [:]
    private var timedOutPaths: Set<String> = []
    /// Letztes bestätigtes Ergebnis je Pfad samt Bundle-Metadaten zum Zeitpunkt der Bestätigung.
    private var confirmations: [String: Confirmation] = [:]
    private(set) var requestCount = 0

    private struct CheckResult: Sendable {
        let validation: DeepSignatureValidation
        let unchanged: Bool
        /// Bundle-Metadaten nach der Prüfung.
        let stamp: String?
    }

    private struct Confirmation: Sendable {
        let stamp: String
        let verdict: DeepSignatureVerdict
    }

    private enum CacheLookup: Sendable {
        /// Bundle-Metadaten wie bei der letzten Bestätigung.
        case confirmed(DeepSignatureVerdict)
        /// Vollständiger Baum wie im Cache; `stamp` sind die aktuellen Bundle-Metadaten.
        case revalidated(DeepSignatureVerdict, stamp: String?)
        case stale
    }

    private struct RunningCheck {
        let target: String
        let fingerprint: String?
        let task: Task<CheckResult, Never>
    }

    public init(
        validator: any SignatureValidating = SecuritySignatureValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        cacheURL: URL? = nil
    ) {
        self.init(validator: validator, now: now, cacheURL: cacheURL, treeFingerprint: { CodeTreeFingerprint.read(at: $0) })
    }

    /// `treeFingerprint` ersetzt in Tests `CodeTreeFingerprint.read`, etwa um vollständige Traversierungen zu zählen.
    init(
        validator: any SignatureValidating = SecuritySignatureValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        cacheURL: URL? = nil,
        treeFingerprint: @escaping @Sendable (String) -> String?
    ) {
        self.validator = validator
        self.now = now
        self.cacheURL = cacheURL
        self.treeFingerprint = treeFingerprint
    }

    private func loadCache() async {
        guard cache == nil else { return }
        let url = cacheURL
        let loaded = await metadata { DeepSignatureCache.load(from: url) }
        if cache == nil { cache = loaded }
    }

    private func metadata<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            metadataQueue.async { continuation.resume(returning: body()) }
        }
    }

    /// Fristablauf beendet keinen nativen Aufruf. Bis zur erneuten erfolgreichen Prüfung bleibt das sichtbar.
    public func hasTimedOutChecks(for paths: Set<String>) -> Bool {
        !paths.isDisjoint(with: timedOutPaths)
    }

    /// Noch gültige Ergebnisse für `paths`. `completeTree` traversiert jeden Code-Baum mit Cache-Eintrag vollständig;
    /// `bundleMetadata` nur die Bäume, deren Bundle-Metadaten sich seit der letzten Bestätigung geändert haben (#259).
    public func cachedVerdicts(
        for paths: [String], revalidation: DeepSignatureRevalidation = .completeTree
    ) async -> [String: DeepSignatureVerdict] {
        await loadCache()
        let entries = cache?.entries ?? [:]
        let confirmed = revalidation == .bundleMetadata ? confirmations : [:]
        let treeFingerprint = treeFingerprint
        // Ein gemeinsamer Queue-Auftrag statt einer Dispatch-Runde je Datei.
        let lookups = await metadata {
            var lookups: [String: CacheLookup] = [:]
            for path in paths {
                let target = FileFingerprint.target(of: path)
                let stamp = CodeTreeFingerprint.stamp(at: target)
                if let confirmation = confirmed[path], let stamp, confirmation.stamp == stamp {
                    lookups[path] = .confirmed(confirmation.verdict)
                } else if let entry = entries[path], treeFingerprint(target) == entry.fingerprint {
                    lookups[path] = .revalidated(entry.verdict, stamp: stamp)
                } else {
                    lookups[path] = .stale
                }
            }
            return lookups
        }
        var verdicts: [String: DeepSignatureVerdict] = [:]
        for (path, lookup) in lookups {
            switch lookup {
            case .confirmed(let verdict):
                verdicts[path] = verdict
            case .revalidated(let verdict, let stamp):
                verdicts[path] = verdict
                confirm(verdict, for: path, stamp: stamp)
            case .stale:
                confirmations[path] = nil
            }
        }
        return verdicts
    }

    private func confirm(_ verdict: DeepSignatureVerdict, for path: String, stamp: String?) {
        confirmations[path] = stamp.map { Confirmation(stamp: $0, verdict: verdict) }
    }

    public func verify(path: String) async -> DeepSignatureVerdict {
        requestCount += 1
        await loadCache()
        let treeFingerprint = treeFingerprint
        let (target, exists, stamp, fingerprint) = await metadata {
            let target = FileFingerprint.target(of: path)
            return (target, FileType.linkStatus(of: target) != nil, CodeTreeFingerprint.stamp(at: target),
                    treeFingerprint(target))
        }
        guard exists else {
            cache?.entries[path] = nil
            confirmations[path] = nil
            timedOutPaths.remove(path)
            return .unverifiable
        }
        if let fingerprint, let entry = cache?.entries[path], entry.fingerprint == fingerprint {
            confirm(entry.verdict, for: path, stamp: stamp)
            return entry.verdict
        }
        if let fingerprint, let timeout = timeouts[path], timeout.fingerprint == fingerprint,
           now().timeIntervalSince(timeout.date) < Self.timeoutRetryDelay {
            // Teilscans fragen bis zum nächsten Vollscan nicht erneut nach (keine Traversierung je Minute).
            confirm(.unverifiable, for: path, stamp: stamp)
            return .unverifiable
        }
        if let check = running[path], check.target == target, check.fingerprint == fingerprint {
            let result = await check.task.value
            return result.unchanged ? result.validation.verdict : .unverifiable
        }

        let (validator, queue) = (validator, queue)
        let task = Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    let validation = validator.validation(ofPath: target)
                    let after = treeFingerprint(target)
                    // Ein unvollständig erfassbarer Baum darf geprüft, aber nie aus dem Cache freigegeben werden.
                    let unchanged = fingerprint == nil || (after == fingerprint && FileFingerprint.target(of: path) == target)
                    continuation.resume(returning: CheckResult(validation: validation, unchanged: unchanged,
                                                               stamp: CodeTreeFingerprint.stamp(at: target)))
                }
            }
        }
        running[path] = RunningCheck(target: target, fingerprint: fingerprint, task: task)
        let result = await task.value
        guard running[path]?.task == task else { return .unverifiable }
        running[path] = nil
        if !result.validation.isConclusive { timedOutPaths.insert(path) }
        guard result.unchanged else {
            cache?.entries[path] = nil
            confirmations[path] = nil
            return .unverifiable
        }
        // Auch unvollständig erfassbare Bäume und Zeitüberschreitungen: Teilscans starten sie nicht jede Minute neu,
        // erst der nächste Vollscan (`completeTree` verwirft die Bestätigung ohne Cache-Eintrag).
        confirm(result.validation.verdict, for: path, stamp: stamp == result.stamp ? stamp : nil)
        if result.validation.isConclusive { timedOutPaths.remove(path) }
        if let fingerprint, result.validation.isConclusive {
            if cache?.entries.count ?? 0 >= DeepSignatureCache.maximumEntries,
               cache?.entries[path] == nil, let evicted = cache?.entries.keys.first {
                cache?.entries[evicted] = nil
                confirmations[evicted] = nil
            }
            cache?.entries[path] = .init(fingerprint: fingerprint, verdict: result.validation.verdict)
            timeouts[path] = nil
            let saved = cache
            let url = cacheURL
            await metadata { saved?.save(to: url) }
        } else if let fingerprint {
            timeouts[path] = (fingerprint, now())
        }
        return result.validation.verdict
    }
}
