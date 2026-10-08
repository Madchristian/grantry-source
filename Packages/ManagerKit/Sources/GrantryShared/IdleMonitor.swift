import Synchronization

/// Meldet Leerlauf: `onIdle` wird aufgerufen, sobald `timeout` lang keine Aktivität lief.
///
/// Aktivitäten melden sich per `beginActivity()` an und per `Activity.end()` ab. Endet die letzte Aktivität, beginnt
/// die Frist neu; eine neue Aktivität bricht sie ab. `start()` setzt die Frist, ohne dass zuvor eine Aktivität lief.
/// Nach einer Meldung wird die Frist erst mit dem Ende der nächsten Aktivität wieder gesetzt.
///
/// `onIdle` läuft **unter der Sperre** des Monitors: Eine gleichzeitig beginnende Aktivität wartet, bis `onIdle`
/// zurückkehrt. Beendet `onIdle` den Prozess (Helper), kann so zwischen Prüfung und `exit` keine Aktivität mehr
/// beginnen. `onIdle` darf deshalb den Monitor nicht selbst aufrufen und muss rasch zurückkehren.
///
/// Verwendet vom Helper (Idle-Exit, Verbindungen und Operationen als Aktivitäten) und vom `HelperClient`
/// (Schließen einer unbenutzten Verbindung, Aufrufe als Aktivitäten).
public final class IdleMonitor: Sendable {
    /// Standard-Leerlaufzeit bis zum Beenden des Helpers: 5 Minuten.
    public static let defaultTimeout: Duration = .seconds(300)

    /// Eine laufende Aktivität. `end()` darf mehrfach aufgerufen werden, zählt aber nur einmal.
    public final class Activity: Sendable {
        private let ended = Mutex(false)
        private let onEnd: @Sendable () -> Void

        fileprivate init(onEnd: @escaping @Sendable () -> Void) { self.onEnd = onEnd }

        public func end() {
            let first = ended.withLock { ended in
                defer { ended = true }
                return !ended
            }
            if first { onEnd() }
        }
    }

    private struct State {
        var active = 0
        /// Kennung der zuletzt gesetzten Frist; ein Timer meldet nur, wenn seine noch aktuell ist.
        var generation = 0
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    /// Liefert (zum Aufrufzeitpunkt berechnet) ein Warten bis zum Ablauf der Frist.
    private let makeTimeout: @Sendable () -> @Sendable () async throws -> Void
    private let onIdle: @Sendable () -> Void

    public init<C: Clock>(
        timeout: Duration = defaultTimeout,
        clock: C,
        onIdle: @escaping @Sendable () -> Void
    ) where C.Duration == Duration {
        makeTimeout = {
            let deadline = clock.now.advanced(by: timeout)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
        self.onIdle = onIdle
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
    }

    /// Anzahl laufender Aktivitäten.
    public var activeCount: Int { state.withLock { $0.active } }

    /// Setzt die Frist, falls gerade nichts läuft und noch keine gesetzt ist.
    public func start() {
        state.withLock { state in
            guard state.active == 0, state.timer == nil else { return }
            arm(&state)
        }
    }

    /// Meldet eine Aktivität an und bricht eine laufende Frist ab.
    public func beginActivity() -> Activity {
        state.withLock { state in
            state.active += 1
            state.generation += 1
            state.timer?.cancel()
            state.timer = nil
        }
        return Activity { [weak self] in self?.activityEnded() }
    }

    private func activityEnded() {
        state.withLock { state in
            state.active -= 1
            if state.active == 0 { arm(&state) }
        }
    }

    private func arm(_ state: inout State) {
        state.generation += 1
        let generation = state.generation
        let timeout = makeTimeout()
        state.timer = Task { [weak self] in
            do { try await timeout() } catch { return }
            self?.timeoutElapsed(generation: generation)
        }
    }

    private func timeoutElapsed(generation: Int) {
        state.withLock { state in
            guard state.generation == generation, state.active == 0 else { return }
            state.timer = nil
            onIdle()
        }
    }
}
