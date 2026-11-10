import Darwin
import Foundation

/// Priorität eines Prozesses im Task-Manager (TM-9.3) – fünf feste Stufen wie Windows 11, als nice-Wert. Nie unter −10:
/// Werte bis −20 können das System aushungern („Echtzeit“ bietet Grantry bewusst nicht an).
public enum ProcessPriority: Int32, CaseIterable, Codable, Hashable, Sendable {
    case high = -10
    case aboveNormal = -5
    case normal = 0
    case belowNormal = 5
    case low = 10

    public var title: String {
        switch self {
        case .high: "Hoch"
        case .aboveNormal: "Höher als normal"
        case .normal: "Normal"
        case .belowNormal: "Niedriger als normal"
        case .low: "Niedrig"
        }
    }

    /// Die Stufe, deren nice-Wert `niceValue` am nächsten liegt, etwa für einen von außen gesetzten Wert wie 3 oder 19
    /// (Abstand 5 zwischen den Stufen: bei ganzen Zahlen gibt es keinen Gleichstand).
    public init(nearest niceValue: Int32) {
        self = Self.allCases.min { abs($0.rawValue - niceValue) < abs($1.rawValue - niceValue) }!
    }
}

/// Fehler beim Setzen der Priorität; die Meldung geht unverändert an die App.
public enum ProcessPriorityFailure: LocalizedError, Equatable {
    /// `ESRCH`: Der Prozess ist inzwischen beendet.
    case gone(pid_t)
    /// `EPERM`/`EACCES`: etwa eine höhere Priorität ohne root.
    case notPermitted(pid_t)
    case failed(pid_t, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .gone(let pid): "Prozess \(pid) läuft nicht mehr"
        case .notPermitted(let pid): "Keine Berechtigung, die Priorität von Prozess \(pid) zu ändern"
        case .failed(let pid, let code): "Priorität von Prozess \(pid) nicht änderbar (errno \(code))"
        }
    }
}

/// Liest und setzt die Priorität (nice) eines geprüften Prozesses; prüft nichts außer der PID (die Prüfungen macht
/// `ProcessTerminationPolicy`).
public protocol ProcessPrioritySetting: Sendable {
    func setPriority(_ priority: ProcessPriority, of process: RunningProcess) throws(ProcessPriorityFailure)
    /// Aktueller nice-Wert; `nil`, wenn nicht lesbar.
    func niceValue(of pid: pid_t) -> Int32?
}

/// `setpriority`/`getpriority` mit `PRIO_PROCESS`. Anders als beim Signal gibt es keine Variante mit Audit-Token: Der
/// Aufruf geht an die PID, unmittelbar nach der letzten Identitätsprüfung (akzeptierte Grenze, Plan TM9). Jede PID ≤ 1
/// ist **vor** dem Aufruf ausgeschlossen – `who == 0` hieße „der aufrufende Prozess“.
public struct PosixPrioritySetter: ProcessPrioritySetting {
    private let set: @Sendable (pid_t, Int32) -> Int32
    private let get: @Sendable (pid_t) -> (value: Int32, errno: Int32)

    public init() {
        self.init(set: { pid, value in setpriority(PRIO_PROCESS, id_t(pid), value) == 0 ? 0 : errno },
                  get: { pid in
                      errno = 0
                      let value = getpriority(PRIO_PROCESS, id_t(pid))
                      return (value, errno)
                  })
    }

    init(set: @escaping @Sendable (pid_t, Int32) -> Int32,
         get: @escaping @Sendable (pid_t) -> (value: Int32, errno: Int32)) {
        self.set = set
        self.get = get
    }

    public func setPriority(_ priority: ProcessPriority, of process: RunningProcess) throws(ProcessPriorityFailure) {
        let pid = process.pid
        guard pid > 1 else { throw .notPermitted(pid) }
        switch set(pid, priority.rawValue) {
        case 0: return
        case ESRCH: throw .gone(pid)
        case EPERM, EACCES: throw .notPermitted(pid)
        case let code: throw .failed(pid, errno: code)
        }
    }

    /// `getpriority` liefert −1 auch als gültigen Wert; ein Fehler zeigt sich nur in `errno`.
    public func niceValue(of pid: pid_t) -> Int32? {
        guard pid > 1 else { return nil }
        let result = get(pid)
        return result.errno == 0 ? result.value : nil
    }
}
