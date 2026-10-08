import Darwin
import Foundation
import GrantryShared
import os

/// Exklusive Sperre (`flock`) auf eine Datei im Ablageort: Wer sie hält, ist die einzige Instanz, die in diese Ablage
/// schreibt. Das System gibt sie frei, sobald der Prozess endet – auch nach einem Absturz.
///
/// Der Halter vermerkt in der Datei, ob er sich gerade beendet (`markTerminating()`). Eine neue Instanz kann dann auf
/// die Freigabe warten, statt an eine Instanz zu übergeben, die gleich verschwindet.
///
/// Weil die Sperrdatei gekürzt und beschrieben wird, darf sie nie auf eine fremde Datei umgelenkt werden können: Ordner
/// und Datei werden wie jede private Datei der App geöffnet und geprüft (`PrivateFile`, Schutz `.writeProtected`,
/// fehlende Ordner mit `0700`) – sonst könnte ein anderer Benutzer Einträge austauschen, die gehaltene Sperrdatei
/// löschen oder einen Marker fälschen. Ein Symlink irgendwo im Pfad → `POSIXError(.ELOOP)`. Die Datei wird mit
/// `O_NONBLOCK` gegen blockierende FIFOs geöffnet; erst nach der Prüfung wird gesperrt und geschrieben.
///
/// Der Marker ist nur eine Information für die nächste Instanz: Scheitert sein Schreiben, bleibt eine erhaltene Sperre
/// trotzdem gehalten (der Fehler wird protokolliert) – sonst liefe die App ohne Sperre weiter, und eine spätere Instanz
/// erhielte sie zusätzlich. Weil der Inhalt dann veraltet sein kann, gilt ein „terminating“-Marker nur, solange der
/// Prozess, der ihn schrieb, noch läuft (`InstanceLockMarker`).
///
/// Der Pfad muss daher symlinkfrei sein (nicht erst aufgelöst); ist er es nicht, scheitert die Sperre, statt einem
/// Link zu folgen.
public final class InstanceLock: Sendable, Equatable {
    /// Ergebnis eines Versuchs, die Sperre zu erhalten.
    public enum Acquisition: Equatable, Sendable {
        /// Gehalten, solange das `InstanceLock` lebt.
        case acquired(InstanceLock)
        /// Eine andere Instanz hält die Sperre; `byTerminatingInstance`, wenn sie sich gerade beendet.
        case held(byTerminatingInstance: Bool)
    }

    /// Grund, eine vorgefundene Sperrdatei oder ihren Ordner abzulehnen (Symlinks melden `POSIXError(.ELOOP)`).
    public typealias Refusal = PrivateFileRefusal

    private static let pollInterval: Duration = .milliseconds(50)
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "instance")

    private let descriptor: Int32
    private let markerWriter: MarkerWriter

    private init(descriptor: Int32, markerWriter: MarkerWriter) {
        self.descriptor = descriptor
        self.markerWriter = markerWriter
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func == (lhs: InstanceLock, rhs: InstanceLock) -> Bool { lhs === rhs }

    /// Versucht einmal, die Sperre zu erhalten; legt Datei und Ordner bei Bedarf an.
    /// - Throws: `Refusal` für eine unzulässige Sperrdatei oder einen nicht vertrauenswürdigen Ordner, sonst
    ///   `POSIXError`, wenn die Datei nicht geöffnet, gesperrt oder beschrieben werden kann (nicht bei belegter
    ///   Sperre) – `ELOOP` für einen Symlink im Pfad.
    public static func acquire(at url: URL) throws -> Acquisition {
        try acquire(at: url, markerWriter: .file)
    }

    /// `acquire(at:)` mit austauschbarem Schreiben des Markers (Tests).
    static func acquire(at url: URL, markerWriter: MarkerWriter) throws -> Acquisition {
        let descriptor = try openLockFile(at: url)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = BoundDirectory.posixError()
            let isTerminating = InstanceLockMarker(parsing: contents(of: descriptor))?.isFromTerminatingLivingProcess == true
            close(descriptor)
            guard error.code == .EWOULDBLOCK else { throw error }
            return .held(byTerminatingInstance: isTerminating)
        }
        let lock = InstanceLock(descriptor: descriptor, markerWriter: markerWriter)
        do {
            try lock.write(.running)
        } catch {
            // Nicht fatal: Die Sperre ist erhalten und bleibt es; nur die Information für andere Instanzen fehlt.
            logger.error("Instanzsperre erhalten, Marker nicht geschrieben: \(error.localizedDescription, privacy: .public)")
        }
        return .acquired(lock)
    }

    /// Wartet höchstens `timeout` auf die Sperre (blockiert den Aufrufer); `nil`, wenn sie belegt bleibt.
    public static func acquire(at url: URL, waitingUpTo timeout: Duration) throws -> InstanceLock? {
        try acquire(at: url, waitingUpTo: timeout, markerWriter: .file)
    }

    /// `acquire(at:waitingUpTo:)` mit austauschbarem Schreiben des Markers (Tests).
    static func acquire(at url: URL, waitingUpTo timeout: Duration, markerWriter: MarkerWriter) throws -> InstanceLock? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if case .acquired(let lock) = try acquire(at: url, markerWriter: markerWriter) { return lock }
            guard clock.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: pollInterval.timeInterval)
        }
    }

    /// Vermerkt, dass sich der Halter beendet; die Sperre bleibt bis zum Ende des Prozesses bestehen.
    /// - Throws: `POSIXError`, wenn die Sperrdatei nicht gekürzt oder beschrieben werden kann.
    public func markTerminating() throws {
        try write(.terminating)
    }

    /// Öffnet die Sperrdatei gebunden an ihren geprüften Ordner und prüft sie am Deskriptor (siehe Typbeschreibung).
    private static func openLockFile(at url: URL) throws -> Int32 {
        let directory = try trustedDirectory(
            at: url.deletingLastPathComponent().path(percentEncoded: false), creatingMissingWith: PrivateFile.directoryMode
        )
        let descriptor = openat(
            directory.descriptor, url.lastPathComponent,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, PrivateFile.fileMode
        )
        guard descriptor >= 0 else { throw BoundDirectory.posixError() }
        do {
            try PrivateFile.check(descriptor, protection: .writeProtected)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// `PrivateFile.trustedDirectory` – Tests prüfen so den echten Standardpfad, ohne etwas anzulegen.
    static func trustedDirectory(at path: String, creatingMissingWith creationMode: mode_t? = nil) throws -> BoundDirectory {
        try PrivateFile.trustedDirectory(at: path, creatingMissingWith: creationMode)
    }

    /// Ersetzt den Inhalt der Sperrdatei durch den Marker `state` dieses Prozesses.
    private func write(_ state: InstanceLockMarker.State) throws {
        try markerWriter.write(Array(InstanceLockMarker.current(state).text.utf8), descriptor)
    }

    private static func contents(of descriptor: Int32) -> String {
        String(decoding: (try? PrivateFile.read(descriptor, limit: 64)) ?? [], as: UTF8.self)
    }
}

/// Inhalt der Sperrdatei: Zustand des Halters samt PID und Startzeit des Prozesses, der ihn schrieb
/// (`<Zustand> <PID> <Startzeit>`).
///
/// PID und Startzeit zusammen bezeichnen einen Prozess eindeutig (`RunningProcess`): Ein Marker, dessen Schreiber nicht
/// mehr läuft – oder dessen PID inzwischen ein anderer Prozess trägt –, ist veraltet, etwa weil der jetzige Halter ihn
/// nicht überschreiben konnte. Nur ein „terminating“ eines noch laufenden Schreibers lässt eine neue Instanz warten;
/// ist sein Zustand nicht feststellbar, wird nicht gewartet (kein Hängen auf Verdacht).
///
/// Ältere Versionen schreiben `<Zustand> <PID>` ohne Startzeit. Beendet sich eine solche beim Update noch, während der
/// neue Build startet, muss dieser auf sie warten statt an sie zu übergeben. Ein solcher Marker gilt daher, wenn unter
/// der PID ein Prozess mit demselben Programmnamen wie dieser läuft (`proc_pidpath`); eine tote PID oder ein anderes
/// Programm unter der neu vergebenen PID zählen nicht.
struct InstanceLockMarker: Equatable, Sendable {
    enum State: String, Sendable {
        case running
        case terminating
    }

    let state: State
    let pid: pid_t
    /// Startzeit des Schreibers (`ProcessLiveness.running(startTime:)`); `0`, wenn sie nicht lesbar war – dann gilt der
    /// Marker nie als von einem laufenden Prozess; `nil` im älteren Format ohne Startzeit.
    let startTime: UInt64?

    private static let inspector = LibprocProcessInspector()
    /// Startzeit dieses Prozesses; ändert sich nicht.
    private static let ownStartTime: UInt64 = {
        if case .running(let startTime) = inspector.liveness(of: getpid()) { return startTime }
        return 0
    }()
    /// Programmname dieses Prozesses; ältere Marker zählen nur für einen Prozess gleichen Namens.
    private static let ownExecutableName = executableName(of: getpid())

    init(state: State, pid: pid_t, startTime: UInt64?) {
        self.state = state
        self.pid = pid
        self.startTime = startTime
    }

    /// `nil` für alles, was weder `<Zustand> <PID> <Startzeit>` noch das ältere `<Zustand> <PID>` ist.
    init?(parsing text: String) {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2 || fields.count == 3, let state = State(rawValue: String(fields[0])),
              let pid = pid_t(fields[1]), pid > 0 else { return nil }
        let startTime = fields.count == 3 ? UInt64(fields[2]) : nil
        guard fields.count == 2 || startTime != nil else { return nil }
        self.init(state: state, pid: pid, startTime: startTime)
    }

    /// Marker dieses Prozesses.
    static func current(_ state: State) -> InstanceLockMarker {
        InstanceLockMarker(state: state, pid: getpid(), startTime: ownStartTime)
    }

    var text: String { "\(state.rawValue) \(pid)" + (startTime.map { " \($0)" } ?? "") + "\n" }

    /// „terminating“, geschrieben von einem Prozess, der noch läuft: unter PID und Startzeit, im älteren Format unter
    /// der PID mit demselben Programmnamen wie dieser Prozess.
    var isFromTerminatingLivingProcess: Bool {
        guard state == .terminating, case .running(let current) = Self.inspector.liveness(of: pid) else { return false }
        guard let startTime else {
            return Self.ownExecutableName != nil && Self.executableName(of: pid) == Self.ownExecutableName
        }
        return startTime != 0 && current == startTime
    }

    private static func executableName(of pid: pid_t) -> String? {
        LibprocProcessInspector.executablePath(of: pid).map { URL(filePath: $0).lastPathComponent }
    }
}

/// Schreibt den Marker in die geöffnete Sperrdatei; austauschbar, damit Tests Schreibfehler vortäuschen können.
struct MarkerWriter: Sendable {
    let write: @Sendable (_ data: [UInt8], _ descriptor: Int32) throws -> Void

    static let file = file(truncatingWith: { ftruncate($0, $1) })

    /// Kürzt die Datei mit `truncate` (Signatur von `ftruncate`) und schreibt `data` vollständig ab Anfang; bei `EINTR`
    /// wird wiederholt, jeder andere Fehler wird geworfen.
    static func file(truncatingWith truncate: @escaping @Sendable (Int32, off_t) -> Int32) -> MarkerWriter {
        MarkerWriter { data, descriptor in
            while truncate(descriptor, 0) != 0 {
                guard errno == EINTR else { throw BoundDirectory.posixError() }
            }
            try PrivateFile.writeFully(data, to: descriptor)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
