import Foundation
import Security

/// Ergebnis der vollständigen Signaturprüfung eines App-Bundles oder Programms.
public enum DeepSignatureVerdict: Hashable, Sendable {
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

/// Tiefe Signaturprüfung im Hintergrund, mit Ergebnis-Cache pro Pfad und Fingerabdruck (`FileFingerprint`).
///
/// **Nie parallel, nie auf dem Main Actor**: Jede Prüfung läuft auf einer eigenen seriellen Dispatch-Queue
/// (QoS `utility`) – gleichzeitige Aufrufe von `verify(path:)` stehen dort an. Weil der Actor während einer
/// Prüfung nur auf deren Ergebnis wartet, beantwortet er `cachedVerdicts(for:)` auch dann sofort, wenn gerade eine
/// minutenlange Prüfung (z. B. Xcode) läuft; der kooperative Thread-Pool bleibt frei.
///
/// **Nie doppelt**: Läuft für einen Pfad (mit unverändertem Fingerabdruck) schon eine Prüfung, warten weitere
/// Aufrufe auf deren Ergebnis, statt sie erneut einzureihen.
///
/// **Cache**: Ein Ergebnis gilt, bis sich der Fingerabdruck des Ziels ändert (Update, Austausch, neue Signatur).
/// Eine Veränderung, die den Fingerabdruck nicht berührt (eine Ressource wird nachträglich überschrieben), fällt
/// erst nach der nächsten Änderung am Bundle auf. Pfade ohne lesbare Attribute werden nicht geprüft. Eine
/// Zeitüberschreitung (`DeepSignatureValidation.timedOut`) ergibt `unverifiable`, wird aber nie gecacht – sonst bliebe
/// die Prüfung nach einem einzigen Hänger dauerhaft blind (Review M1). Sie wird je Pfad und Fingerabdruck
/// `timeoutRetryDelay` lang gemerkt (Review N5): Ohne Änderung des Ziels prüft erst danach der nächste Aufruf erneut –
/// sonst belegte jede Runde dieselbe hängende App erneut die Warteschlange und einen Platz im Guard.
public actor DeepSignatureVerifier {
    /// So lange gilt eine Zeitüberschreitung je Fingerabdruck als Ergebnis „nicht prüfbar“.
    public static let timeoutRetryDelay: TimeInterval = 30 * 60

    private let validator: any SignatureValidating
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "de.cstrube.Grantry.deep-signature", qos: .utility)
    private var cache = FingerprintCache<DeepSignatureVerdict>()
    /// Zeitpunkt der letzten Zeitüberschreitung je Pfad, solange der Fingerabdruck gleich bleibt.
    private var timeouts = FingerprintCache<Date>()
    /// Laufende Prüfungen je Pfad, samt Fingerabdruck des Ziels bei ihrem Start.
    private var running: [String: RunningCheck] = [:]
    /// Anzahl der `verify(path:)`-Aufrufe (für Tests).
    private(set) var requestCount = 0

    private struct RunningCheck {
        let fingerprint: FileFingerprint
        let task: Task<DeepSignatureValidation, Never>
    }

    public init(validator: any SignatureValidating = SecuritySignatureValidator(), now: @escaping @Sendable () -> Date = Date.init) {
        self.validator = validator
        self.now = now
    }

    /// Bereits bekannte Ergebnisse für `paths`, sofern sich deren Ziel seitdem nicht verändert hat.
    public func cachedVerdicts(for paths: [String]) -> [String: DeepSignatureVerdict] {
        var verdicts: [String: DeepSignatureVerdict] = [:]
        for path in paths {
            guard let fingerprint = FileFingerprint(of: FileFingerprint.target(of: path)),
                  let verdict = cache.value(for: path, matching: fingerprint) else { continue }
            verdicts[path] = verdict
        }
        return verdicts
    }

    /// Ergebnis für `path`: aus dem Cache, aus einer bereits laufenden Prüfung desselben Ziels, sonst nach
    /// vollständiger Prüfung (in der Warteschlange hinter laufenden).
    public func verify(path: String) async -> DeepSignatureVerdict {
        requestCount += 1
        let target = FileFingerprint.target(of: path)
        guard let fingerprint = FileFingerprint(of: target) else {
            cache.removeValue(for: path)
            return .unverifiable
        }
        if let cached = cache.value(for: path, matching: fingerprint) { return cached }
        if let timedOutAt = timeouts.value(for: path, matching: fingerprint),
           now().timeIntervalSince(timedOutAt) < Self.timeoutRetryDelay {
            return DeepSignatureValidation.timedOut.verdict
        }
        if let check = running[path], check.fingerprint == fingerprint { return await check.task.value.verdict }

        let (validator, queue) = (validator, queue)
        let task = Task {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: validator.validation(ofPath: target)) }
            }
        }
        running[path] = RunningCheck(fingerprint: fingerprint, task: task)
        let validation = await task.value
        if running[path]?.task == task { running[path] = nil }
        // Mit dem Fingerabdruck von vor der Prüfung: Ändert sich das Ziel währenddessen, wird es neu geprüft.
        if validation.isConclusive {
            cache.store(validation.verdict, for: path, fingerprint: fingerprint)
            timeouts.removeValue(for: path)
        } else {
            timeouts.store(now(), for: path, fingerprint: fingerprint)
        }
        return validation.verdict
    }
}
