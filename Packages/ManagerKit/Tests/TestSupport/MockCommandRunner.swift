import Synchronization
import GrantryShared

/// Liefert vordefinierte Ergebnisse je Befehlszeile und protokolliert Aufrufe.
public final class MockCommandRunner: CommandRunning {
    private let environments = Mutex<[[String: String]?]>([])
    public var recordedEnvironments: [[String: String]?] { environments.withLock { $0 } }

    private let state: Mutex<(responses: [String: CommandResult], calls: [String])>

    public init(_ responses: [String: CommandResult] = [:]) {
        state = Mutex((responses, []))
    }

    public var calls: [String] { state.withLock { $0.calls } }

    public func stub(_ commandLine: String, _ result: CommandResult) {
        state.withLock { $0.responses[commandLine] = result }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await run(executable, arguments, timeout: timeout, environment: nil)
    }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration,
                    environment: [String: String]?) async throws -> CommandResult {
        environments.withLock { $0.append(environment) }
        let line = ([executable] + arguments).joined(separator: " ")
        return state.withLock { state in
            state.calls.append(line)
            return state.responses[line] ?? CommandResult(exitCode: 127, stdout: "", stderr: "not stubbed: \(line)")
        }
    }
}
