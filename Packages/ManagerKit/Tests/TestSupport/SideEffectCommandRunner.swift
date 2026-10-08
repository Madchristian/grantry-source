import Synchronization
import GrantryShared

/// Reicht an `base` durch und führt nach einer Antwort einmalig eine passende Nebenwirkung aus – bildet einen Prozess
/// nach, der während eines launchctl-Aufrufs das Dateisystem (oder launchd) verändert.
public final class SideEffectCommandRunner: CommandRunning {
    public typealias Effect = @Sendable () throws -> Void

    private let base: MockCommandRunner
    /// Ausstehende Nebenwirkungen in Reihenfolge; je Aufruf feuert die erste zur Befehlszeile passende.
    private let pending: Mutex<[(commandLine: String, effect: Effect)]>

    public convenience init(_ base: MockCommandRunner, on commandLine: String, _ sideEffect: @escaping Effect) {
        self.init(base, script: [(commandLine, sideEffect)])
    }

    /// Nebenwirkungen in Reihenfolge, jede höchstens einmal. Kommt eine Befehlszeile mehrfach vor, gilt der erste
    /// Eintrag für ihren ersten Aufruf, der zweite für den zweiten usw.
    public init(_ base: MockCommandRunner, script: [(commandLine: String, effect: Effect)]) {
        self.base = base
        pending = Mutex(script)
    }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        let result = try await base.run(executable, arguments, timeout: timeout)
        let line = ([executable] + arguments).joined(separator: " ")
        let effect = pending.withLock { pending in
            pending.firstIndex { $0.commandLine == line }.map { pending.remove(at: $0).effect }
        }
        try effect?()
        return result
    }
}
