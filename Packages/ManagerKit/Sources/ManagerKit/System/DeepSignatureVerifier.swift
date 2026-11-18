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
///
/// Je Baum merkt der Verifier den Beginn seiner letzten Komplettprüfung (`completeCheckAges(for:)`, #649): vollständige
/// Traversierung wie im Cache, abgeschlossene Tiefenprüfung des unveränderten Baums oder ein fehlendes Ziel. Bundle-Stempel
/// zählen nicht; ein veränderter Baum verliert ihn, bis die Tiefenprüfung ihn wieder bestätigt. Gemessen auf der monotonen
/// Uhr `clock` (Standard `ContinuousClock`, läuft im Ruhezustand weiter), nicht auf der Wanduhr `now`, und nur im Prozess.
///
/// Die verteilte Komplettprüfung liest einen Baum in Blöcken bis zu einem CPU-Budget (`revalidateTree(at:cpuBudget:)`,
/// #662) und hält dafür höchstens einen angefangenen Baum.
public actor DeepSignatureVerifier {
    public static let timeoutRetryDelay: TimeInterval = 30 * 60

    private let validator: any SignatureValidating
    private let now: @Sendable () -> Date
    /// Monotone Zeit für die Prüfalter (#649).
    private let elapsed: ElapsedTime
    private let cacheURL: URL?
    private let treeFingerprint: @Sendable (String) -> String?
    private let queue = DispatchQueue(label: "de.cstrube.Grantry.deep-signature", qos: .background)
    /// Ohne eigene QoS: Jeder Auftrag trägt seine (`metadata(qos:_:)`), sonst setzte die Queue eine Untergrenze.
    private let metadataQueue = DispatchQueue(label: "de.cstrube.Grantry.signature-metadata")
    private var cache: DeepSignatureCache?
    private var timeouts: [String: (fingerprint: String, date: Date)] = [:]
    private var running: [String: RunningCheck] = [:]
    private var timedOutPaths: Set<String> = []
    /// Letztes bestätigtes Ergebnis je Pfad samt Bundle-Metadaten zum Zeitpunkt der Bestätigung.
    private var confirmations: [String: Confirmation] = [:]
    /// Beginn der letzten Komplettprüfung je Pfad in Sekunden von `elapsed` (#649), nur im Prozess.
    private var completeChecks: [String: TimeInterval] = [:]
    /// Durchlauf in Blöcken (#662).
    private let treeWalk: @Sendable (String) -> (any CodeTreeWalking)?
    /// Angefangene Komplettprüfung in Blöcken, höchstens eine (#662).
    private var partialCheck: (path: String, check: PartialTreeCheck)?
    /// Zählt je Pfad jede Bestätigung und jedes Verwerfen: Ein Block, der danach endet, ist überholt.
    private var generations: [String: Int] = [:]
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
        /// Vollständiger Baum wie im Cache, gelesen ab `checkedAt` (Sekunden von `elapsed`); `stamp` sind die aktuellen
        /// Bundle-Metadaten.
        case revalidated(DeepSignatureVerdict, stamp: String?, checkedAt: TimeInterval)
        case stale
    }

    private struct RunningCheck {
        let target: String
        let fingerprint: String?
        let task: Task<CheckResult, Never>
    }

    /// Angefangene Komplettprüfung: Durchlauf, kanonisches Ziel und Bundle-Stempel bei Beginn, Beginn des ersten Blocks
    /// (Sekunden von `elapsed`).
    private struct PartialTreeCheck: Sendable {
        let walk: any CodeTreeWalking
        let target: String
        let stamp: String?
        let checkedAt: TimeInterval
    }

    /// Ergebnis eines Blocks auf der Metadaten-Queue.
    private enum TreeBlock: Sendable {
        /// Kein Cache-Eintrag oder kein lesbarer Baum: nichts zu bestätigen.
        case stale
        /// Bundle-Stempel oder Ziel seit dem ersten Block verändert.
        case changed
        case partial(PartialTreeCheck, cpuTime: Duration)
        /// Zu Ende gelesen; `fingerprint` nur, wenn Ziel und Stempel noch die vom Beginn sind.
        case finished(PartialTreeCheck, fingerprint: String?, cpuTime: Duration)
    }

    /// - Parameters:
    ///   - now: Wanduhr (Wiederholpause nach Zeitüberschreitungen).
    ///   - clock: monotone Uhr der Prüfalter (`completeCheckAges(for:)`).
    public init(
        validator: any SignatureValidating = SecuritySignatureValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        clock: any Clock<Duration> = ContinuousClock(),
        cacheURL: URL? = nil
    ) {
        self.init(validator: validator, now: now, clock: clock, cacheURL: cacheURL,
                  treeFingerprint: { CodeTreeFingerprint.read(at: $0) }, treeWalk: { CodeTreeWalk(path: $0) })
    }

    /// `treeFingerprint` ersetzt in Tests `CodeTreeFingerprint.read`, etwa um vollständige Traversierungen zu zählen;
    /// `treeWalk` den Durchlauf in Blöcken. Ohne `treeWalk` liest ein Block den ganzen Baum über `treeFingerprint`.
    init(
        validator: any SignatureValidating = SecuritySignatureValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        clock: any Clock<Duration> = ContinuousClock(),
        cacheURL: URL? = nil,
        treeFingerprint: @escaping @Sendable (String) -> String?,
        treeWalk: (@Sendable (String) -> (any CodeTreeWalking)?)? = nil
    ) {
        self.validator = validator
        self.now = now
        elapsed = ElapsedTime(clock)
        self.cacheURL = cacheURL
        self.treeFingerprint = treeFingerprint
        self.treeWalk = treeWalk ?? { path in WholeTreeWalk(path: path, read: treeFingerprint) }
    }

    private func loadCache() async {
        guard cache == nil else { return }
        let url = cacheURL
        let loaded = await metadata { DeepSignatureCache.load(from: url) }
        if cache == nil { cache = loaded }
    }

    /// `body` auf der Metadaten-Queue mit Priorität `qos` (`.background` für die verteilte Revalidierung, #649).
    private func metadata<Value: Sendable>(
        qos: DispatchQoS = .utility, _ body: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            metadataQueue.async(qos: qos, flags: .enforceQoS) { continuation.resume(returning: body()) }
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
        await lookUp(paths, revalidation: revalidation, qos: .utility)
    }

    /// Ein Block der Komplettprüfung von `path` für die verteilte Revalidierung (#649, #662), mit Hintergrund-Priorität:
    /// liest den Baum, bis er zu Ende ist oder die Rechenzeit `cpuBudget` erreicht (`nil`: am Stück). Ein angefangener
    /// Baum setzt beim nächsten Aufruf fort, sofern Ziel und Bundle-Stempel unverändert sind; sonst verfällt er, gilt nicht
    /// als geprüft, und der nächste Aufruf beginnt von vorn. Zu Ende gelesen: das Urteil, wenn der vollständige Baum dem
    /// Cache entspricht (datiert auf den Beginn des ersten Blocks), sonst `nil` – dann braucht das Ziel `verify(path:)`.
    public func revalidateTree(at path: String, cpuBudget: Duration?) async -> TreeRevalidationStep {
        await loadCache()
        let hasEntry = cache?.entries[path] != nil
        let generation = generations[path, default: 0]
        let partial = partialCheck?.path == path ? partialCheck?.check : nil
        partialCheck = nil
        let (treeWalk, elapsed) = (treeWalk, elapsed)
        let block = await metadata(qos: .background) { () -> TreeBlock in
            let target = FileFingerprint.target(of: path)
            let stamp = CodeTreeFingerprint.stamp(at: target)
            let check: PartialTreeCheck
            if let partial {
                // Änderung zwischen zwei Blöcken: Der halb gelesene Baum ist kein Beleg mehr.
                guard partial.target == target, partial.stamp == stamp else { return .changed }
                check = partial
            } else {
                let checkedAt = elapsed.seconds
                guard hasEntry, let walk = treeWalk(target) else { return .stale }
                check = PartialTreeCheck(walk: walk, target: target, stamp: stamp, checkedAt: checkedAt)
            }
            let step = check.walk.advance(cpuBudget: cpuBudget)
            guard case .finished(let fingerprint) = step.progress else { return .partial(check, cpuTime: step.cpuTime) }
            let unchanged = FileFingerprint.target(of: path) == target && CodeTreeFingerprint.stamp(at: target) == check.stamp
            return .finished(check, fingerprint: unchanged ? fingerprint : nil, cpuTime: step.cpuTime)
        }
        switch block {
        case .stale, .changed:
            guard generations[path, default: 0] == generation else { return TreeRevalidationStep(outcome: .superseded) }
            forget(path)
            return TreeRevalidationStep(outcome: .finished(nil))
        case .partial(let check, let cpuTime):
            guard generations[path, default: 0] == generation else {
                return TreeRevalidationStep(outcome: .superseded, cpuTime: cpuTime)
            }
            partialCheck = (path, check)
            return TreeRevalidationStep(outcome: .partial, cpuTime: cpuTime)
        case .finished(let check, let fingerprint, let cpuTime):
            guard generations[path, default: 0] == generation else {
                return TreeRevalidationStep(outcome: .superseded, cpuTime: cpuTime)
            }
            guard let fingerprint, let entry = cache?.entries[path], entry.fingerprint == fingerprint else {
                forget(path)
                return TreeRevalidationStep(outcome: .finished(nil), cpuTime: cpuTime)
            }
            confirm(entry.verdict, for: path, stamp: check.stamp, checkedAt: check.checkedAt)
            return TreeRevalidationStep(outcome: .finished(entry.verdict), cpuTime: cpuTime)
        }
    }

    /// Alter der letzten Komplettprüfung je Pfad aus `paths` in Sekunden seit ihrem Beginn, auf der monotonen Uhr des
    /// Verifiers (unabhängig von der Wanduhr); ohne Eintrag gilt der Baum nicht als geprüft (#649). Ein Alter statt eines
    /// Zeitpunkts, damit Aufrufer mit eigener Uhr es richtig einordnen.
    public func completeCheckAges(for paths: [String]) -> [String: TimeInterval] {
        let now = elapsed.seconds
        return paths.reduce(into: [:]) { ages, path in ages[path] = completeChecks[path].map { now - $0 } }
    }

    private func lookUp(
        _ paths: [String], revalidation: DeepSignatureRevalidation, qos: DispatchQoS
    ) async -> [String: DeepSignatureVerdict] {
        await loadCache()
        let entries = cache?.entries ?? [:]
        let confirmed = revalidation == .bundleMetadata ? confirmations : [:]
        let (treeFingerprint, elapsed) = (treeFingerprint, elapsed)
        // Ein gemeinsamer Queue-Auftrag statt einer Dispatch-Runde je Datei.
        let lookups = await metadata(qos: qos) {
            var lookups: [String: CacheLookup] = [:]
            for path in paths {
                let target = FileFingerprint.target(of: path)
                let stamp = CodeTreeFingerprint.stamp(at: target)
                if let confirmation = confirmed[path], let stamp, confirmation.stamp == stamp {
                    lookups[path] = .confirmed(confirmation.verdict)
                    continue
                }
                let checkedAt = elapsed.seconds
                if let entry = entries[path], treeFingerprint(target) == entry.fingerprint {
                    lookups[path] = .revalidated(entry.verdict, stamp: stamp, checkedAt: checkedAt)
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
            case .revalidated(let verdict, let stamp, let checkedAt):
                verdicts[path] = verdict
                confirm(verdict, for: path, stamp: stamp, checkedAt: checkedAt)
            case .stale:
                forget(path)
            }
        }
        return verdicts
    }

    /// Bestätigt `verdict` für den ab `checkedAt` (Sekunden von `elapsed`) vollständig geprüften Baum `path`.
    private func confirm(_ verdict: DeepSignatureVerdict, for path: String, stamp: String?, checkedAt: TimeInterval) {
        confirmations[path] = stamp.map { Confirmation(stamp: $0, verdict: verdict) }
        completeChecks[path] = checkedAt
        settle(path)
    }

    /// Kein bestätigtes Ergebnis mehr für `path`: Teilscans übernehmen nichts, und der Baum gilt nicht als geprüft.
    private func forget(_ path: String) {
        confirmations[path] = nil
        completeChecks[path] = nil
        settle(path)
    }

    /// Neuer Stand für `path`: Ein angefangener Durchlauf und Blöcke, die noch laufen, sind überholt (#662).
    private func settle(_ path: String) {
        generations[path, default: 0] += 1
        if partialCheck?.path == path { partialCheck = nil }
    }

    public func verify(path: String) async -> DeepSignatureVerdict {
        requestCount += 1
        await loadCache()
        let treeFingerprint = treeFingerprint
        let checkedAt = elapsed.seconds
        let (target, exists, stamp, fingerprint) = await metadata {
            let target = FileFingerprint.target(of: path)
            return (target, FileType.linkStatus(of: target) != nil, CodeTreeFingerprint.stamp(at: target),
                    treeFingerprint(target))
        }
        guard exists else {
            cache?.entries[path] = nil
            forget(path)
            // Nichts zu prüfen: abschließend, kein Dauer-Kandidat der verteilten Revalidierung.
            completeChecks[path] = checkedAt
            timedOutPaths.remove(path)
            return .unverifiable
        }
        if let fingerprint, let entry = cache?.entries[path], entry.fingerprint == fingerprint {
            confirm(entry.verdict, for: path, stamp: stamp, checkedAt: checkedAt)
            return entry.verdict
        }
        if let fingerprint, let timeout = timeouts[path], timeout.fingerprint == fingerprint,
           now().timeIntervalSince(timeout.date) < Self.timeoutRetryDelay {
            // Teilscans fragen bis zum nächsten Vollscan nicht erneut nach (keine Traversierung je Minute).
            confirm(.unverifiable, for: path, stamp: stamp, checkedAt: checkedAt)
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
            forget(path)
            return .unverifiable
        }
        // Auch unvollständig erfassbare Bäume und Zeitüberschreitungen: Teilscans starten sie nicht jede Minute neu,
        // erst die nächste Komplettprüfung (`completeTree` verwirft die Bestätigung ohne Cache-Eintrag).
        confirm(result.validation.verdict, for: path, stamp: stamp == result.stamp ? stamp : nil, checkedAt: checkedAt)
        if result.validation.isConclusive { timedOutPaths.remove(path) }
        if let fingerprint, result.validation.isConclusive {
            if cache?.entries.count ?? 0 >= DeepSignatureCache.maximumEntries,
               cache?.entries[path] == nil, let evicted = cache?.entries.keys.first {
                cache?.entries[evicted] = nil
                forget(evicted)
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

/// Ergebnis eines Blocks der Komplettprüfung (`DeepSignatureVerifier.revalidateTree(at:cpuBudget:)`, #662).
public struct TreeRevalidationStep: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Budget erschöpft; der nächste Block setzt fort.
        case partial
        /// Baum zu Ende geprüft: das bestätigte Urteil, `nil` für einen veränderten oder nicht bestätigbaren Baum (die
        /// Tiefenprüfung folgt).
        case finished(DeepSignatureVerdict?)
        /// Während des Blocks hat ein Scan oder die Tiefenprüfung den Baum neu bewertet; dieser Block zählt nicht.
        case superseded
    }

    public let outcome: Outcome
    /// Rechenzeit des Blocks.
    public let cpuTime: Duration

    public init(outcome: Outcome, cpuTime: Duration = .zero) {
        self.outcome = outcome
        self.cpuTime = cpuTime
    }
}

/// Liest den ganzen Baum in einem Block über `read` (Tests, die nur `treeFingerprint` ersetzen).
private final class WholeTreeWalk: CodeTreeWalking, @unchecked Sendable {
    private let path: String
    private let read: @Sendable (String) -> String?
    private var result: String??

    init(path: String, read: @escaping @Sendable (String) -> String?) {
        self.path = path
        self.read = read
    }

    func advance(cpuBudget: Duration?) -> CodeTreeWalkStep {
        if let result { return CodeTreeWalkStep(progress: .finished(result), cpuTime: .zero) }
        let started = ThreadCPUTime.now
        let fingerprint = read(path)
        result = .some(fingerprint)
        return CodeTreeWalkStep(progress: .finished(fingerprint), cpuTime: ThreadCPUTime.now - started)
    }
}
