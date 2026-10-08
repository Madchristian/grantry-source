import Darwin
import Foundation
import Synchronization
import Testing

/// Benannte Pipe (FIFO) als Fixture: Wer sie blockierend zum Lesen öffnet, wartet, bis ein Schreiber kommt.
enum FIFOFixture {
    /// Ab wann ein Lauf als „hängt an der FIFO“ gilt. Ein echtes Hängen endet nie; die Grenze muss nur über der
    /// Laufzeit unter Last liegen – die Messungen laufen mit QoS `utility`, und auf einem CI-Runner mit drei Kernen
    /// konkurrieren sie mit rund 2400 gleichzeitig gestarteten Tests (dort dauerte ein Scan mehr als 5 s).
    static let hangLimit: Duration = .seconds(30)

    static func make(in directory: URL, named name: String = "fifo") throws -> URL {
        let url = directory.appending(path: name)
        guard mkfifo(url.path, 0o644) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return url
    }

    /// Führt den synchronen `body` auf einem eigenen Thread aus und wartet höchstens `limit`. Hängt `body` an `fifo`,
    /// wird ein Fehler erfasst und die Pipe durch kurzes Öffnen zum Schreiben freigegeben (der Leser bekommt EOF),
    /// damit der Test endet.
    /// - Returns: das Ergebnis von `body`, `nil` nach Zeitüberschreitung.
    static func completes<T: Sendable>(
        within limit: Duration = hangLimit, unblocking fifo: URL,
        sourceLocation: SourceLocation = #_sourceLocation, _ body: @escaping @Sendable () -> T
    ) async -> T? {
        await completes(within: limit, unblocking: fifo, sourceLocation: sourceLocation) { completion in
            Thread.detachNewThread { completion.finish(body()) }
        }
    }

    /// Wie oben für asynchronen Code (z. B. `scan()`, `resolve(path:)`): `body` läuft als eigener Task.
    static func completes<T: Sendable>(
        within limit: Duration = hangLimit, unblocking fifo: URL,
        sourceLocation: SourceLocation = #_sourceLocation, _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await completes(within: limit, unblocking: fifo, sourceLocation: sourceLocation) { completion in
            Task.detached { completion.finish(await body()) }
        }
    }

    /// Wartet suspendierend – nie blockierend – auf `start`s Ergebnis. Ein blockierendes Warten auf einem Thread des
    /// kooperativen Pools würde bei wenigen Kernen (CI-Runner) genau die Tasks aussperren, auf die es wartet.
    private static func completes<T: Sendable>(
        within limit: Duration, unblocking fifo: URL, sourceLocation: SourceLocation,
        start: (Completion<T>) -> Void
    ) async -> T? {
        let completion = Completion<T>()
        start(completion)
        if let value = await completion.value(within: limit) { return value }
        Issue.record("blockiert an \(fifo.lastPathComponent) länger als \(limit)", sourceLocation: sourceLocation)
        let unblocker = Thread {
            while !completion.isFinished {
                let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
                if writer >= 0 { close(writer) }
                usleep(100_000)
            }
        }
        unblocker.start()
        _ = await completion.value(within: nil)
        return nil
    }

    /// Ergebnis eines Laufs, auf das genau ein Aufrufer suspendierend wartet; die Frist läuft auf einem eigenen Thread,
    /// weder im kooperativen Pool noch in den globalen Dispatch-Queues.
    private final class Completion<T: Sendable>: Sendable {
        private struct State {
            var value: T?
            var isFinished = false
            var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
            var nextID = 0
        }

        private let state = Mutex(State())

        var isFinished: Bool { state.withLock { $0.isFinished } }

        func finish(_ value: T) {
            let waiter = state.withLock { state in
                state.value = value
                state.isFinished = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.continuation.resume()
        }

        /// Das Ergebnis, sobald es vorliegt; `nil`, wenn `limit` (sofern gesetzt) vorher abläuft.
        func value(within limit: Duration?) async -> T? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let id: Int? = state.withLock { state in
                    guard !state.isFinished else { return nil }
                    defer { state.nextID += 1 }
                    state.waiter = (state.nextID, continuation)
                    return state.nextID
                }
                guard let id else { return continuation.resume() }
                guard let limit else { return }
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: limit / .seconds(1))
                    self.giveUp(waiter: id)
                }
            }
            return state.withLock { $0.value }
        }

        /// Beendet das Warten von `waiter` ohne Ergebnis – außer es ist schon vorbei.
        private func giveUp(waiter id: Int) {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard state.waiter?.id == id else { return nil }
                defer { state.waiter = nil }
                return state.waiter?.continuation
            }
            waiter?.resume()
        }
    }
}
