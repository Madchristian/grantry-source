import Synchronization

/// Hält Aufrufer an, bis der Test sie freigibt: `wait()` suspendiert, bis ein `open()` es einlöst – auch ein `open()`,
/// das vor dem `wait()` kam. Jedes `open()` löst genau ein `wait()` ein (ältestes zuerst). Ein Abbruch des wartenden
/// Tasks wirft `CancellationError`.
public final class Gate: Sendable {
    private struct State {
        var permits = 0
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Lässt den ältesten Wartenden weiter oder merkt die Freigabe für das nächste `wait()` vor.
    public func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard let oldest = state.waiters.keys.min() else {
                state.permits += 1
                return nil
            }
            return state.waiters.removeValue(forKey: oldest)
        }
        waiter?.resume()
    }

    public func wait() async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Unter der Sperre: Ein Abbruch vor der Registrierung wird hier gesehen, einer danach vom Handler.
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    guard state.permits == 0 else {
                        state.permits -= 1
                        return .success(())
                    }
                    state.waiters[id] = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
