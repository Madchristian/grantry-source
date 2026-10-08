import Synchronization

/// Signal, das genau einmal ausgelöst wird: `wait()` kehrt zurück, sobald `fire()` aufgerufen wurde (auch schon
/// vorher) oder der wartende Task abgebrochen wird.
final class OneShotSignal: Sendable {
    private struct State {
        var isFired = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    var isFired: Bool { state.withLock(\.isFired) }

    /// Löst das Signal aus und lässt alle Wartenden weiter; weitere Aufrufe bleiben wirkungslos.
    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isFired = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    /// Wartet auf `fire()`; kehrt bei Abbruch des Tasks ohne Fehler zurück.
    func wait() async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Unter der Sperre: Ein Abbruch vor der Registrierung wird hier gesehen, einer danach vom Handler.
                let resumesAtOnce = state.withLock { state in
                    guard !state.isFired, !Task.isCancelled else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumesAtOnce { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}
