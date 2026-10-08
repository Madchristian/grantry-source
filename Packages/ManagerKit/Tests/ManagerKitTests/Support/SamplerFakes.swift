import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Spielt je Aufruf von `run` einen vorbereiteten Lauf ab, statt nettop zu starten. Ein hängender Lauf wartet
/// suspendierend (`Gate`) auf den Abbruch – kein Thread des kooperativen Pools wird blockiert.
final class ScriptedLineStreamer: LineStreaming {
    enum Ending: Sendable {
        case exit(Int32)
        case launchFailure
        case hangUntilCancelled
    }

    struct Run: Sendable {
        var lines: [String]
        var ending: Ending

        init(_ lines: [String] = [], ending: Ending = .exit(0)) {
            self.lines = lines
            self.ending = ending
        }
    }

    private struct State {
        var runs: [Run]
        var started = 0
        var terminated = 0
    }

    private let state: Mutex<State>
    private let hang = Gate()

    init(_ runs: [Run]) {
        state = Mutex(State(runs: runs))
    }

    /// Gestartete Läufe.
    var startedRuns: Int { state.withLock { $0.started } }
    /// Läufe, die durch Abbruch oder einen Fehler im Zeilen-Handler beendet wurden.
    var terminatedRuns: Int { state.withLock { $0.terminated } }

    func run(_ executable: String, _ arguments: [String], onLine: @Sendable (String) throws -> Void) async throws -> Int32 {
        let run: Run? = state.withLock { state in
            state.started += 1
            return state.runs.isEmpty ? nil : state.runs.removeFirst()
        }
        guard let run else {
            Issue.record("Kein vorbereiteter Lauf mehr")
            return 1
        }
        if case .launchFailure = run.ending {
            throw CommandError.launchFailed(executable: executable, reason: "No such file or directory")
        }
        do {
            for line in run.lines {
                try Task.checkCancellation()
                try onLine(line)
            }
            switch run.ending {
            case .exit(let status): return status
            case .launchFailure: return 1
            case .hangUntilCancelled:
                try await hang.wait()
                return 0
            }
        } catch {
            state.withLock { $0.terminated += 1 }
            throw error
        }
    }
}

/// Liefert bei jedem Aufruf einen um `step` späteren Zeitpunkt (der erste ist `base`).
final class SteppedInstants: Sendable {
    let base = ContinuousClock.now
    private let step: Duration
    private let count = Mutex(0)

    init(step: Duration = .seconds(1)) {
        self.step = step
    }

    func next() -> ContinuousClock.Instant {
        let index = count.withLock { count in
            defer { count += 1 }
            return count
        }
        return base + step * index
    }
}

/// Zeichnet Wartezeiten auf, ohne zu warten.
final class RecordedSleeps: Sendable {
    private let log = Mutex<[Duration]>([])

    var durations: [Duration] { log.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        log.withLock { $0.append(duration) }
    }
}
