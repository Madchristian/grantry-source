import Darwin
import Foundation

/// Laufender Prozess laut `sysctl` und libproc: Benutzer, Programmpfad (`proc_pidpath`) und Startzeit. Gemeinsamer Typ von App und
/// Helper für „Prozess beenden …“ (#128).
///
/// **Identität gegen PID-Wiederverwendung:** Eine PID allein bezeichnet keinen Prozess – nach seinem Ende vergibt
/// macOS sie neu, auch an dasselbe Programm desselben Benutzers. Erst PID **und** Startzeit sind eindeutig. Vor jedem
/// Signal vergleicht `ProcessTerminationPolicy` deshalb PID, Pfad, ggf. uid **und** `startTime`; weicht die Startzeit
/// ab, gilt der Prozess als „hat sich geändert“ und bekommt kein Signal. Das Signal selbst geht an `auditToken`
/// (`ProcessAuditToken`), damit auch zwischen Prüfung und Zustellung kein Nachfolger unter derselben PID getroffen wird.
public struct RunningProcess: Hashable, Sendable {
    public let pid: pid_t
    public let uid: UInt32
    public let executablePath: String
    /// Startzeit in Mikrosekunden seit 1970 (`p_starttime` aus `sysctl(KERN_PROC_PID)`).
    public let startTime: UInt64
    /// Prozessgeneration für das Signal; `nil`, wenn nicht lesbar (fremder Prozess ohne root) – dann sendet
    /// `PosixProcessSignaler` nicht (`identityUnknown`).
    public let auditToken: ProcessAuditToken?

    public init(pid: pid_t, uid: UInt32, executablePath: String, startTime: UInt64, auditToken: ProcessAuditToken? = nil) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.startTime = startTime
        self.auditToken = auditToken
    }
}

/// Ob unter einer PID ein Prozess läuft – allein aus der Prozesstabelle (`sysctl`), unabhängig von Audit-Token und
/// Programmpfad. Grundlage jedes **Exitnachweises** (#153): Dass `ProcessInspecting.process(_:)` keinen Prozess liefert,
/// heißt nur „Identität gerade nicht bestätigt“ (etwa ein `exec` zwischen den beiden Token-Lesungen, das die
/// `pidversion` ändert), nicht „beendet“.
public enum ProcessLiveness: Hashable, Sendable {
    /// Unter der PID läuft ein Prozess (kein Zombie) mit dieser Startzeit.
    case running(startTime: UInt64)
    /// Unter der PID läuft nachweislich nichts mehr: kein Eintrag oder ein Zombie (beendet, nicht geerntet).
    case absent
    /// Nicht feststellbar (`sysctl` gescheitert, ungültige Startzeit) – weder Lauf noch Ende belegt.
    case unknown
}

/// Liest einen laufenden Prozess.
public protocol ProcessInspecting: Sendable {
    /// Der Prozess mit bestätigter Identität (alle Angaben gehören zu derselben Prozessgeneration); `nil`, wenn er nicht
    /// (mehr) läuft **oder** seine Identität gerade nicht bestätigt werden kann. `nil` ist deshalb nie ein Exitnachweis –
    /// den liefert allein `liveness(of:)`.
    func process(_ pid: pid_t) -> RunningProcess?
    /// Lebendzustand der PID laut Prozesstabelle, ohne Audit-Token und Programmpfad.
    func liveness(of pid: pid_t) -> ProcessLiveness
}

extension ProcessInspecting {
    /// Nachweislich beendet: Unter der PID läuft nichts mehr oder ein Prozess mit anderer Startzeit (PID neu vergeben).
    /// Ein `exec` oder Benutzerwechsel unter derselben PID und Startzeit ist kein Ende, ebenso wenig ein nicht
    /// feststellbarer Zustand (`ProcessLiveness.unknown`).
    public func hasEnded(_ pid: pid_t, startedAt startTime: UInt64) -> Bool {
        switch liveness(of: pid) {
        case .absent: true
        case .running(let current): current != startTime
        case .unknown: false
        }
    }
}

/// `ProcessInspecting` über `sysctl` und libproc, alles auch als Benutzer für root-Prozesse lesbar – die App prüft
/// damit das Ende vom Helper beendeter Prozesse:
/// - uid, Status und Startzeit aus **einem** `sysctl(KERN_PROC_PID)` (`kinfo_proc`, wie `ps`), damit sie zum selben
///   Prozess gehören (`e_ucred.cr_uid`, `p_stat`, `p_starttime`);
/// - der Pfad aus `proc_pidpath`.
///
/// Zombies (beendet, noch nicht geerntet) gelten als beendet: Die Prüfung verwirft den Status `SZOMB`, und laut
/// Befund 5 des Plans scheitert für sie auch `proc_pidpath` (`ESRCH`), während `kill(pid, 0)` sie noch als vorhanden
/// meldet. Eine ungültige Startzeit macht den Prozess unlesbar (fail-closed).
///
/// Die Angaben stammen aus mehreren Aufrufen; damit sie zu **einem** Prozess gehören, wird das Audit-Token vor und
/// nach dem Lesen verglichen: Weicht es ab, wurde die PID zwischendurch neu vergeben oder der Prozess hat ein `exec`
/// ausgeführt, und `process(_:)` liefert `nil`. Ob er beendet ist, entscheidet davon unabhängig `liveness(of:)`. Ohne
/// lesbares Token (fremder Prozess als Benutzer) bleibt `auditToken` leer.
public struct LibprocProcessInspector: ProcessInspecting {
    /// `PROC_PIDPATHINFO_MAXSIZE` (`4 * MAXPATHLEN`); das Makro wird nicht nach Swift importiert.
    static let pathCapacity = 4 * Int(MAXPATHLEN)

    /// Eintrag der Prozesstabelle, soweit für Identität und Lebendzustand nötig.
    struct KernelEntry: Equatable, Sendable {
        let uid: UInt32
        /// `nil` bei ungültiger Startzeit.
        let startTime: UInt64?
        let isZombie: Bool
    }

    /// Ergebnis einer Abfrage der Prozesstabelle.
    enum KernelLookup: Equatable, Sendable {
        case found(KernelEntry)
        /// Kein Eintrag unter der PID.
        case missing
        /// Abfrage gescheitert – nichts belegt.
        case failed
    }

    private let kernel: @Sendable (pid_t) -> KernelLookup
    private let executablePath: @Sendable (pid_t) -> String?
    private let auditToken: @Sendable (pid_t) -> ProcessAuditToken?

    public init() {
        self.init(kernel: Self.kernelLookup, executablePath: Self.executablePath, auditToken: ProcessAuditToken.init(pid:))
    }

    /// Mit austauschbaren Abfragen – nur in Tests, um etwa ein `exec` zwischen zwei Token-Lesungen nachzubilden.
    init(
        kernel: @escaping @Sendable (pid_t) -> KernelLookup,
        executablePath: @escaping @Sendable (pid_t) -> String?,
        auditToken: @escaping @Sendable (pid_t) -> ProcessAuditToken?
    ) {
        self.kernel = kernel
        self.executablePath = executablePath
        self.auditToken = auditToken
    }

    public func process(_ pid: pid_t) -> RunningProcess? {
        guard pid > 0 else { return nil }
        let generation = auditToken(pid)
        guard case .found(let entry) = kernel(pid), !entry.isZombie, let startTime = entry.startTime,
              let path = executablePath(pid), auditToken(pid) == generation else { return nil }
        return RunningProcess(pid: pid, uid: entry.uid, executablePath: path, startTime: startTime, auditToken: generation)
    }

    public func liveness(of pid: pid_t) -> ProcessLiveness {
        guard pid > 0 else { return .absent }
        switch kernel(pid) {
        case .missing: return .absent
        case .failed: return .unknown
        case .found(let entry):
            if entry.isZombie { return .absent }
            return entry.startTime.map { .running(startTime: $0) } ?? .unknown
        }
    }

    /// Programmpfad laut `proc_pidpath`; `nil`, wenn der Prozess fehlt oder ein Zombie ist.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathCapacity)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `kinfo_proc` laut `sysctl(KERN_PROC_PID)`. Für eine fehlende PID meldet `sysctl` Erfolg mit Länge 0
    /// (`missing`); jeder andere Ausgang ohne vollständigen, passenden Eintrag ist `failed`.
    private static func kernelLookup(_ pid: pid_t) -> KernelLookup {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return errno == ESRCH ? .missing : .failed }
        if size == 0 { return .missing }
        guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return .failed }
        return .found(KernelEntry(
            uid: info.kp_eproc.e_ucred.cr_uid,
            startTime: microseconds(info.kp_proc.p_un.__p_starttime),
            isZombie: Int32(info.kp_proc.p_stat) == SZOMB
        ))
    }

    /// `time` in Mikrosekunden seit 1970; `nil` bei negativem, überlaufendem oder ungültigem Wert.
    static func microseconds(_ time: timeval) -> UInt64? {
        guard let seconds = UInt64(exactly: time.tv_sec), let micros = UInt64(exactly: time.tv_usec), micros < 1_000_000
        else { return nil }
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return nil }
        let (total, carry) = scaled.addingReportingOverflow(micros)
        return carry ? nil : total
    }
}
