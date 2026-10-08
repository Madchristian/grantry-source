import Foundation

/// Ergebnis eines Kommandozeilenaufrufs.
public struct CommandResult: Hashable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Fehler beim Starten oder Beenden eines externen Befehls. Ein Exit-Code ungleich 0 ist kein Fehler,
/// sondern Teil des `CommandResult`.
public enum CommandError: LocalizedError, Equatable {
    case launchFailed(executable: String, reason: String)
    /// Der Befehl lieferte innerhalb von `seconds` kein vollständiges Ergebnis; er wurde beendet.
    case timedOut(executable: String, seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let reason): "\(executable) konnte nicht gestartet werden: \(reason)"
        case .timedOut(let executable, let seconds):
            "\(executable) lieferte nach \(Duration.seconds(seconds).formattedSeconds) kein Ergebnis"
        }
    }
}

/// Abstraktion für externe Befehle (`launchctl`, `tccutil`, `sfltool`), in Tests ersetzbar.
public protocol CommandRunning: Sendable {
    /// Führt `executable` mit `arguments` aus und wartet höchstens `timeout` auf Prozessende und vollständige Ausgabe.
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult
}

extension CommandRunning {
    /// Führt den Befehl mit dem Standard-Timeout von 30 Sekunden aus.
    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, timeout: .seconds(30))
    }
}
