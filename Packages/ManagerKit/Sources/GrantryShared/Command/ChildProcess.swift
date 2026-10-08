import Foundation
import Synchronization

/// Gemeinsame Bausteine für Kindprozesse (`ProcessCommandRunner`, `ProcessLineStreamer`): Prozessende abwarten,
/// beenden mit Gnadenfrist und Fristen ohne blockierendes Warten.
enum ChildProcess {
    /// Beendet den Prozess `pid`, falls er noch läuft: erst SIGTERM, nach `gracePeriod` SIGKILL; wartet auf das Ende.
    static func forceExit(pid: pid_t, exit: ExitSignal, gracePeriod: Duration) async {
        // `exit.status` ist die einzige Wahrheit über das Prozessende und wird unmittelbar vor jedem kill() geprüft.
        // Das verbleibende Fenster – Prozessende samt Neuvergabe der PID zwischen Prüfung und kill() – ist
        // mikrosekundenklein und setzt rund 100 000 Prozessstarts voraus; `Process.terminate()` trägt dasselbe Restrisiko.
        guard exit.status == nil else { return }
        kill(pid, SIGTERM)
        let exitedInTime = await withDeadline(gracePeriod) { await exit.wait() }
        if exitedInTime == nil, exit.status == nil {
            kill(pid, SIGKILL)
        }
        _ = await exit.wait()
    }

    /// Wie `forceExit`, aber in einem eigenen Task: Ein abgebrochener Aufrufer verkürzt weder die Gnadenfrist noch das
    /// Warten auf das Prozessende.
    static func forceExitUnlessCancelled(pid: pid_t, exit: ExitSignal, gracePeriod: Duration) async {
        await Task { await forceExit(pid: pid, exit: exit, gracePeriod: gracePeriod) }.value
    }

    /// Führt `operation` aus, bis sie fertig ist oder `timeout` verstreicht. Liefert `nil` bei Timeout oder Abbruch;
    /// die Operation wird dann abgebrochen und der Aufruf kehrt zurück, sobald sie den Abbruch verarbeitet hat.
    static func withDeadline<Value: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Meldet das Prozessende an beliebig viele Wartende. `wait()` ist abbrechbar und liefert dann `nil`.
final class ExitSignal: Sendable {
    private struct State {
        var status: Int32?
        var waiters: [UUID: AsyncStream<Int32>.Continuation] = [:]
    }

    private let state = Mutex(State())

    /// Exit-Status, sobald der Prozess beendet ist; vorher `nil`.
    var status: Int32? { state.withLock { $0.status } }

    func signal(_ status: Int32) {
        let waiters = state.withLock { state in
            state.status = status
            defer { state.waiters = [:] }
            return state.waiters
        }
        for waiter in waiters.values {
            waiter.yield(status)
            waiter.finish()
        }
    }

    /// Wartet auf den Exit-Status; `nil`, wenn der wartende Task vorher abgebrochen wurde.
    func wait() async -> Int32? {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        continuation.onTermination = { _ in self.removeWaiter(id) }
        let immediate: Int32? = state.withLock { state in
            if let status = state.status { return status }
            state.waiters[id] = continuation
            return nil
        }
        if let immediate {
            continuation.finish()
            return immediate
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    private func removeWaiter(_ id: UUID) {
        state.withLock { _ = $0.waiters.removeValue(forKey: id) }
    }
}

/// Liest eine Pipe ereignisgesteuert per `DispatchIO`, ohne einen Thread zu blockieren.
enum PipeReader {
    /// Daten, sobald sie anliegen (`lowWater` 1), bis EOF. Endet der lesende Task oder wird der Stream verworfen,
    /// schließt der Kanal die Pipe.
    static func chunks(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "\(GrantryIdentity.logSubsystem).PipeReader")
            let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
                try? handle.close()
            }
            channel.setLimit(lowWater: 1)
            continuation.onTermination = { _ in channel.close(flags: .stop) }
            channel.read(offset: 0, length: .max, queue: queue) { done, data, _ in
                if let data, !data.isEmpty {
                    continuation.yield(Self.data(copying: data))
                }
                if done { continuation.finish() }
            }
        }
    }

    /// Liest bis EOF. Liefert `nil`, wenn der Task vorher abgebrochen wurde; die Pipe wird in jedem Fall geschlossen.
    static func readToEnd(_ handle: FileHandle) async -> Data? {
        var data = Data()
        for await chunk in chunks(handle) {
            data.append(chunk)
        }
        return Task.isCancelled ? nil : data
    }

    /// Kopiert die (möglicherweise nicht zusammenhängenden) Regionen einer `DispatchData` in eine `Data`.
    private static func data(copying chunk: DispatchData) -> Data {
        var data = Data(capacity: chunk.count)
        chunk.enumerateBytes { buffer, _, _ in data.append(contentsOf: buffer) }
        return data
    }
}
