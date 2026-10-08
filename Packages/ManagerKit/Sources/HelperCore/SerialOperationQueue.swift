import GrantryShared
import Synchronization

/// Führt eingereihte asynchrone Operationen strikt nacheinander in Eingangsreihenfolge aus.
///
/// Anders als ein Actor ist die Warteschlange nicht reentrant: Eine Operation, die selbst `await`et
/// (z. B. auf `launchctl`), blockiert alle folgenden bis zu ihrem Ende. So können sich Prüfung und
/// Ausführung gleichzeitiger Anfragen auf dieselbe Plist nicht überschneiden.
///
/// Jede Operation zählt ab dem Einreihen bis zu ihrem Ende als Aktivität von `idleMonitor`.
final class SerialOperationQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)
    private let idleMonitor: IdleMonitor?

    init(idleMonitor: IdleMonitor? = nil) {
        self.idleMonitor = idleMonitor
    }

    /// Reiht `operation` hinter alle bisher eingereihten Operationen ein und kehrt sofort zurück.
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let activity = idleMonitor?.beginActivity()
        tail.withLock { tail in
            let previous = tail
            tail = Task {
                await previous?.value
                await operation()
                activity?.end()
            }
        }
    }
}
