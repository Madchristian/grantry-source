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
    /// stdout oder stderr überschritt `limit` Bytes; das Lesen endete dort und der Befehl wurde beendet.
    case outputTooLarge(executable: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let reason): "\(executable) konnte nicht gestartet werden: \(reason)"
        case .timedOut(let executable, let seconds):
            "\(executable) lieferte nach \(Duration.seconds(seconds).formattedSeconds) kein Ergebnis"
        case .outputTooLarge(let executable, let limit):
            "\(executable) lieferte mehr als \(limit.formatted(.byteCount(style: .binary))) Ausgabe und wurde abgebrochen"
        }
    }
}

/// Abstraktion für externe Befehle (`launchctl`, `tccutil`, `sfltool`), in Tests ersetzbar.
public protocol CommandRunning: Sendable {
    /// Führt `executable` mit `arguments` aus und wartet höchstens `timeout` auf Prozessende und vollständige Ausgabe.
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult
    /// `nil` erbt die Umgebung; ein Dictionary ersetzt sie vollständig (auch ein leeres).
    func run(_ executable: String, _ arguments: [String], timeout: Duration,
             environment: [String: String]?) async throws -> CommandResult
    /// Wie `run(_:_:timeout:)`, liest stdout und stderr aber je höchstens `outputLimit` Bytes (für Befehle mit Root-
    /// Rechten, deren Ausgabe nicht beliebig groß werden darf).
    /// - Throws: `CommandError.outputTooLarge`, sobald eine der Ausgaben die Grenze überschreitet.
    func run(_ executable: String, _ arguments: [String], timeout: Duration,
             outputLimit: Int) async throws -> CommandResult
}

extension CommandRunning {
    /// Bestehende Implementierungen bleiben kompatibel; explizite Umgebungen niemals stillschweigend ignorieren.
    public func run(_ executable: String, _ arguments: [String], timeout: Duration,
                    environment: [String: String]?) async throws -> CommandResult {
        guard environment == nil else {
            throw CommandError.launchFailed(executable: executable, reason: "Explizite Umgebung wird nicht unterstützt")
        }
        return try await run(executable, arguments, timeout: timeout)
    }

    /// Ersatz-Runner (Tests) prüfen die Grenze erst nach dem Lauf; `ProcessCommandRunner` begrenzt schon das Lesen.
    public func run(_ executable: String, _ arguments: [String], timeout: Duration,
                    outputLimit: Int) async throws -> CommandResult {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.stdout.utf8.count <= outputLimit, result.stderr.utf8.count <= outputLimit else {
            throw CommandError.outputTooLarge(executable: executable, limit: outputLimit)
        }
        return result
    }

    /// Führt den Befehl mit dem Standard-Timeout von 30 Sekunden aus.
    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, timeout: .seconds(30))
    }
}
