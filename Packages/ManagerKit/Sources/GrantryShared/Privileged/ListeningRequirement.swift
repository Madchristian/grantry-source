import Darwin
import Synchronization

/// Grantry beendet nur Prozesse, die gerade lauschen (Nicht-Ziel der Spec: „Prozesse ohne Lauscher beenden“). So kann
/// auch ein kompromittierter Client über den Helper keine beliebigen Nicht-Apple-Prozesse beenden, sondern nur solche
/// mit lauschendem Socket. Ein Referenztyp: Kopien einer `ProcessTerminationPolicy` teilen das Gedächtnis.
///
/// Ausnahme für SIGKILL: Viele Dienste schließen auf SIGTERM zuerst ihren Lauscher und warten dann auf offene
/// Verbindungen. Damit „Sofort beenden (SIGKILL)“ sie trotzdem trifft, bleibt ein Prozess, dem diese Regel ein SIGTERM
/// erlaubt hat, für SIGKILL zulässig – nur derselbe `RunningProcess` (gleiche PID **und** Startzeit); eine neu vergebene
/// PID ist ein anderer Prozess. Der Kreis bleibt damit bei Prozessen, die beim ersten Signal lauschten. Gemerkt werden
/// die letzten `capacity` Prozesse.
public final class ListeningRequirement: Sendable {
    static let capacity = 64

    private let checker: any ListeningProcessChecking
    /// Prozesse mit erlaubtem SIGTERM, ältester zuerst.
    private let acceptedForTermination = Mutex<[RunningProcess]>([])

    public init(checker: any ListeningProcessChecking = LibprocSocketEnumerator()) {
        self.checker = checker
    }

    /// Der Prozess lauscht, oder er bekommt SIGKILL nach einem erlaubten SIGTERM.
    func permits(_ process: RunningProcess, force: Bool) -> Bool {
        if force, acceptedForTermination.withLock({ $0.contains(process) }) { return true }
        return checker.isListening(process.pid)
    }

    /// Merkt sich einen Prozess, dem ein SIGTERM erlaubt wurde.
    func noteAccepted(_ process: RunningProcess, force: Bool) {
        guard !force else { return }
        acceptedForTermination.withLock { accepted in
            accepted.removeAll { $0 == process }
            accepted.append(process)
            if accepted.count > Self.capacity { accepted.removeFirst(accepted.count - Self.capacity) }
        }
    }
}
