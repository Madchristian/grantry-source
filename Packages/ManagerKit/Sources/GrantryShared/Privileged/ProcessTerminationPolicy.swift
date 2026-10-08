import Darwin
import Foundation

/// Verstoß gegen die Regeln für „Prozess beenden …“; die Meldung geht unverändert an die App.
public enum ProcessTerminationViolation: LocalizedError, Equatable {
    /// PID ≤ 1, eigene PID oder PID des Aufrufers.
    case protectedProcess(pid_t)
    /// Der Helper kann den Aufrufer nicht feststellen (`NSXPCConnection.current()` ohne Verbindung); fail-closed.
    case callerUnknown
    /// Programm im Grantry-Bundle (App oder Helper).
    case grantryProcess(String)
    /// Das zu schützende Grantry-Bundle ist unbekannt (`helper()` ohne bestimmbares Bundle); fail-closed.
    case ownBundleUnknown
    /// Programmpfad, Benutzer oder Startzeit passen nicht mehr (PID inzwischen anders belegt).
    case processChanged(pid_t)
    case appleSigned(String)
    case signatureUnknown(String)
    /// Der Prozess hat keinen lauschenden Socket (`ListeningRequirement`).
    case notListening(String)
    /// Die Prozessgeneration (`RunningProcess.auditToken`) ist nicht lesbar; ohne sie geht kein Signal (fail-closed).
    case identityUnknown(pid_t)
    /// Der Auftrag hat bis zum Signal länger als erlaubt gebraucht – in der Warteschlange des Helpers oder in der
    /// Prüfung (`HelperService.terminationRequestLifetime`).
    case requestExpired(pid_t)
    /// `EPERM` von `kill`.
    case notPermitted(pid_t)
    case signalFailed(pid_t, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .protectedProcess(let pid): "Prozess \(pid) ist geschützt und wird nicht beendet"
        case .callerUnknown: "Aufrufer nicht feststellbar – Aktion abgebrochen"
        case .grantryProcess(let name): "Grantry beendet sich nicht selbst: \(name)"
        case .ownBundleUnknown: "Grantry-Bundle nicht bestimmbar – Aktion abgebrochen"
        case .processChanged(let pid): "Prozess \(pid) hat sich geändert – Aktion abgebrochen"
        case .identityUnknown(let pid): "Identität von Prozess \(pid) nicht sicher bestimmbar – Aktion abgebrochen"
        case .requestExpired(let pid): "Auftrag für Prozess \(pid) abgelaufen – kein Signal gesendet"
        case .appleSigned(let name): "Apple-Programme beendet der Helper nicht: \(name)"
        case .signatureUnknown(let name):
            "Signatur von \(name) nicht prüfbar – etwa weil das Programm seit dem Start aktualisiert wurde. "
                + "Nach einem Neustart des Dienstes erneut versuchen."
        case .notListening(let name): "\(name) lauscht nicht im Netzwerk – Grantry beendet nur Prozesse lauschender Dienste"
        case .notPermitted(let pid): "Keine Berechtigung, Prozess \(pid) zu beenden"
        case .signalFailed(let pid, let code): "Signal an Prozess \(pid) gescheitert (errno \(code))"
        }
    }
}

/// Prüft unmittelbar vor einem Signal, ob der Prozess noch derselbe ist und beendet werden darf (Spec §4/§5). App
/// (eigene Prozesse, `app()`) und Helper (`helper()`) nutzen dieselben Regeln; maßgeblich ist die Prüfung im Helper.
///
/// Reihenfolge: (1) PID > 1, weder eigene noch Aufrufer-PID, Grantry-Bundle bekannt; (2) Prozess läuft mit demselben
/// Programm (kanonisch), ggf. demselben Benutzer und ggf. derselben Startzeit – ein nachweislich beendeter ist `.gone`
/// (Erfolg ohne Signal), einer mit nicht bestätigter Identität `identityUnknown`; (3) das Programm liegt nicht im Grantry-Bundle; (4) mit `appleSignature` nur nicht Apple-signierte
/// Programme; (5) mit `listening` nur Prozesse, die gerade lauschen (bzw. SIGKILL nach erlaubtem SIGTERM,
/// `ListeningRequirement`); (6) die Identität wird erneut bestätigt (`inspector.process(pid) == process`), weil
/// Signatur- und Socket-Prüfung Dutzende Millisekunden dauern können – abweichend `processChanged`, inzwischen
/// nachweislich beendet `.gone`, nicht bestätigt `identityUnknown`. Erst danach zählt ein fehlender Lauscher (`notListening`), damit ein beendeter oder ersetzter Prozess als
/// solcher gemeldet wird.
///
/// Meldungen nennen das Programm laut Inspektor (letzter Pfadbestandteil, `DisplayText.singleLine`), nie den Text
/// des Aufrufers.
///
/// Die Startzeit (`RunningProcess.startTime`) schließt PID-Wiederverwendung zwischen Klick und Prüfung aus, auch wenn
/// derselbe Benutzer dasselbe Programm neu gestartet hat. Das zurückgegebene `.running(process)` trägt die
/// Prozessgeneration (`auditToken`), an die der Signalgeber das Signal bindet – zwischen der letzten Bestätigung und der
/// Zustellung kann so kein Nachfolger unter derselben PID getroffen werden (#153).
public struct ProcessTerminationPolicy: Sendable {
    public enum Target: Equatable, Sendable {
        case running(RunningProcess)
        case gone
    }

    private let inspector: any ProcessInspecting
    private let appleSignature: (any AppleSignatureChecking)?
    private let listening: ListeningRequirement?
    private let ownPID: pid_t
    /// `nil`: unbekannt – `validate` lehnt dann alles ab (`ownBundleUnknown`).
    private let protectedBundlePaths: [String]?

    /// - Parameters:
    ///   - listening: `nil` prüft nicht, ob der Prozess lauscht; `app()` und `helper()` setzen die Prüfung immer.
    ///   - protectedBundlePaths: Bundles, deren Programme nie beendet werden; `nil` heißt „nicht bestimmbar“, dann
    ///     lehnt `validate` jede Anfrage ab (fail-closed, siehe `helper(executablePath:)`).
    public init(
        inspector: any ProcessInspecting = LibprocProcessInspector(),
        appleSignature: (any AppleSignatureChecking)? = nil,
        listening: ListeningRequirement? = nil,
        ownPID: pid_t = getpid(),
        protectedBundlePaths: [String]?
    ) {
        self.inspector = inspector
        self.appleSignature = appleSignature
        self.listening = listening
        self.ownPID = ownPID
        self.protectedBundlePaths = protectedBundlePaths
    }

    /// - Parameters:
    ///   - requiredUID: erwarteter Benutzer; `nil` prüft ihn nicht.
    ///   - startTime: erwartete `RunningProcess.startTime`; `nil` prüft sie nicht.
    ///   - callerPID: PID des Aufrufers (Helper), ist geschützt.
    ///   - force: SIGKILL statt SIGTERM (Ausnahme der `ListeningRequirement`).
    public func validate(
        pid: pid_t, executablePath: String, requiredUID: UInt32? = nil, startTime: UInt64? = nil, callerPID: pid_t? = nil,
        force: Bool = false
    ) throws(ProcessTerminationViolation) -> Target {
        guard pid > 1, pid != ownPID, pid != callerPID else { throw .protectedProcess(pid) }
        guard let protectedBundlePaths else { throw .ownBundleUnknown }
        guard let process = inspector.process(pid) else { return try vanished(pid) }
        guard FilePath.canonical(process.executablePath) == FilePath.canonical(executablePath),
              requiredUID.map({ $0 == process.uid }) ?? true,
              startTime.map({ $0 == process.startTime }) ?? true else { throw .processChanged(pid) }
        let name = Self.displayName(of: process.executablePath)
        guard !protectedBundlePaths.contains(where: { Self.isInBundle(process.executablePath, bundlePath: $0) }) else {
            throw .grantryProcess(name)
        }
        switch appleSignature?.verdict(pid: pid, executablePath: process.executablePath) {
        case .apple?: throw .appleSigned(name)
        case .unknown?: throw .signatureUnknown(name)
        case .notApple?, nil: break
        }
        let mayTerminate = listening?.permits(process, force: force) ?? true
        guard let confirmed = inspector.process(pid) else { return try vanished(pid) }
        guard confirmed == process else { throw .processChanged(pid) }
        guard mayTerminate else { throw .notListening(name) }
        listening?.noteAccepted(process, force: force)
        return .running(process)
    }

    /// Kein Prozess mit bestätigter Identität: `.gone` nur mit Exitnachweis (unter der PID läuft nachweislich nichts);
    /// läuft dort noch etwas oder ist der Zustand nicht feststellbar – etwa ein exec zwischen den Token-Lesungen –,
    /// `identityUnknown` (#153, Codex-Runde 3). So meldet weder App noch Helper „bereits beendet“ ohne Signal für einen
    /// Prozess, der weiterläuft.
    private func vanished(_ pid: pid_t) throws(ProcessTerminationViolation) -> Target {
        guard inspector.liveness(of: pid) == .absent else { throw .identityUnknown(pid) }
        return .gone
    }

    /// Programmname für Meldungen und Log: letzter Pfadbestandteil, einzeilig ohne Steuerzeichen.
    public static func displayName(of executablePath: String) -> String {
        DisplayText.singleLine((executablePath as NSString).lastPathComponent)
    }

    /// Äußerstes `.app` um ein Programm (`…/Grantry.app/Contents/MacOS/GrantryHelper` → `…/Grantry.app`).
    public static func enclosingAppBundle(ofExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// `path` liegt (kanonisch, ganze Pfadbestandteile) in `bundlePath`.
    public static func isInBundle(_ path: String, bundlePath: String) -> Bool {
        let bundle = FilePath.canonical(bundlePath)
        let candidate = FilePath.canonical(path)
        return candidate == bundle || candidate.hasPrefix(bundle + "/")
    }
}

extension ProcessTerminationPolicy {
    /// In der App: eigene, lauschende Prozesse ohne Signaturprüfung (Apple-signierte Interpreter sind beendbar),
    /// Grantry geschützt.
    ///
    /// - Parameter listening: nur in Tests abweichend.
    public static func app(
        bundlePath: String = Bundle.main.bundlePath, listening: ListeningRequirement = ListeningRequirement()
    ) -> Self {
        Self(listening: listening, protectedBundlePaths: [bundlePath])
    }

    /// Im Helper: nur lauschende Prozesse, Apple-Programme gesperrt, geschützt ist das Bundle, in dem der Helper liegt. Liegt `executablePath`
    /// in keinem `.app` (oder fehlt), schützt die Policy nicht still nichts, sondern lehnt jede Anfrage mit
    /// `ownBundleUnknown` ab (fail-closed).
    ///
    /// - Parameter inspector: liest die Prozesse; nur in Tests ein Fake.
    public static func helper(
        executablePath: String? = Bundle.main.executablePath, inspector: any ProcessInspecting = LibprocProcessInspector()
    ) -> Self {
        Self(
            inspector: inspector,
            appleSignature: SecurityAppleSignatureCheck(),
            listening: ListeningRequirement(),
            protectedBundlePaths: executablePath.flatMap(enclosingAppBundle(ofExecutable:)).map { [$0] }
        )
    }
}
