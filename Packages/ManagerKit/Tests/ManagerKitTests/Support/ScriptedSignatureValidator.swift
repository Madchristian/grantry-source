import Foundation
import Synchronization
@testable import ManagerKit

/// Validator mit vorgegebenen Ergebnissen je Pfad (sonst `.valid`). Zählt Aufrufe und gleichzeitig laufende
/// Prüfungen und merkt sich, ob eine Prüfung je auf dem Main Thread lief. Mit `holding` blockiert jede Prüfung, bis
/// der Test sie über `release()` freigibt; `starts` meldet jeden Beginn mit dem geprüften Pfad.
final class ScriptedSignatureValidator: SignatureValidating {
    private struct Counters {
        var calls: [String] = []
        var running = 0
        var maxRunning = 0
        var ranOnMainThread = false
    }

    let starts: AsyncStream<String>
    private let started: AsyncStream<String>.Continuation
    private let verdicts: [String: DeepSignatureVerdict]
    /// Pfade, deren nächste Prüfungen (je Eintrag eine) mit Zeitüberschreitung enden.
    private let timeouts: Mutex<[String]>
    private let duration: TimeInterval
    private let permits: DispatchSemaphore?
    private let counters = Mutex(Counters())

    /// - Parameters:
    ///   - duration: Wie lange jede Prüfung mindestens dauert (Sekunden) – macht Überlappungen sichtbar.
    ///   - holding: `true` hält jede Prüfung an, bis `release()` sie freigibt.
    ///   - timeouts: Je Eintrag endet die nächste Prüfung dieses Pfads mit `.timedOut`.
    init(
        verdicts: [String: DeepSignatureVerdict] = [:], timeouts: [String] = [], duration: TimeInterval = 0,
        holding: Bool = false
    ) {
        self.verdicts = verdicts
        self.timeouts = Mutex(timeouts)
        self.duration = duration
        permits = holding ? DispatchSemaphore(value: 0) : nil
        (starts, started) = AsyncStream<String>.makeStream()
    }

    /// Geprüfte Pfade in Aufrufreihenfolge.
    var calls: [String] { counters.withLock { $0.calls } }
    /// Höchstzahl gleichzeitig laufender Prüfungen – 1 heißt: nie parallel.
    var maxConcurrentChecks: Int { counters.withLock { $0.maxRunning } }
    var ranOnMainThread: Bool { counters.withLock { $0.ranOnMainThread } }

    /// Gibt eine angehaltene (oder die nächste) Prüfung frei.
    func release() { permits?.signal() }

    func validate(path: String) -> DeepSignatureVerdict {
        validation(ofPath: path).verdict
    }

    func validation(ofPath path: String) -> DeepSignatureValidation {
        counters.withLock { counters in
            counters.calls.append(path)
            counters.running += 1
            counters.maxRunning = max(counters.maxRunning, counters.running)
            counters.ranOnMainThread = counters.ranOnMainThread || Thread.isMainThread
        }
        defer { counters.withLock { $0.running -= 1 } }
        started.yield(path)
        permits?.wait()
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        let timesOut = timeouts.withLock { timeouts in
            guard let index = timeouts.firstIndex(of: path) else { return false }
            timeouts.remove(at: index)
            return true
        }
        return timesOut ? .timedOut : .completed(verdicts[path] ?? .valid)
    }
}
