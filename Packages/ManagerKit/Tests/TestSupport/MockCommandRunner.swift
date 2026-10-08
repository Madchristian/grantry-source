import Synchronization
import GrantryShared

/// Liefert vordefinierte Ergebnisse je Befehlszeile und protokolliert Aufrufe.
public final class MockCommandRunner: CommandRunning {
    private let state: Mutex<(responses: [String: CommandResult], calls: [String])>

    public init(_ responses: [String: CommandResult] = [:]) {
        state = Mutex((responses, []))
    }

    public var calls: [String] { state.withLock { $0.calls } }

    public func stub(_ commandLine: String, _ result: CommandResult) {
        state.withLock { $0.responses[commandLine] = result }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        let line = ([executable] + arguments).joined(separator: " ")
        return state.withLock { state in
            state.calls.append(line)
            return state.responses[line] ?? CommandResult(exitCode: 127, stdout: "", stderr: "not stubbed: \(line)")
        }
    }
}
