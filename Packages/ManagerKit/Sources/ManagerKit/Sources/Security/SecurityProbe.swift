import Foundation

/// Liest die Fakten einer oder mehrerer Prüfungen aus einer gemeinsamen Quelle (etwa einer Plist) – so beruhen sie auf
/// demselben Stand. Probes sind voneinander unabhängig: Ein Fehler betrifft nur ihre Prüfungen.
public protocol SecurityProbe: Sendable {
    /// Prüfungen, deren Fakten `read(now:)` liefert.
    var kinds: [SecurityCheckKind] { get }
    /// Je Prüfung aus `kinds` die Fakten.
    func read(now: Date) async throws -> [SecurityFacts]
}

/// Befehl gescheitert und Ausgabe nicht auswertbar.
public enum SecurityProbeError: LocalizedError, Equatable {
    case commandFailed(command: String, exitCode: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let exitCode, let detail):
            "\(command) fehlgeschlagen (Exit \(exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

/// Probe über einen Befehl. Zuerst wird `stdout` ausgewertet – manche Werkzeuge melden Zustände mit Exit ≠ 0 –;
/// erst wenn das scheitert und der Exit-Code ≠ 0 ist, gilt der Befehl als gescheitert.
struct CommandSecurityProbe: SecurityProbe {
    static let timeout: Duration = .seconds(15)

    let kind: SecurityCheckKind
    let executable: String
    let arguments: [String]
    let parse: @Sendable (String) throws -> SecurityFacts
    let runner: any CommandRunning

    var kinds: [SecurityCheckKind] { [kind] }

    func read(now: Date) async throws -> [SecurityFacts] {
        let result = try await runner.run(executable, arguments, timeout: Self.timeout)
        do {
            return [try parse(result.stdout)]
        } catch {
            guard result.succeeded else { throw failure(of: result) }
            throw error
        }
    }

    /// Fehler mit Kurzform des Befehls (`csrutil status`) und `stderr`, ersatzweise `stdout`.
    private func failure(of result: CommandResult) -> SecurityProbeError {
        let command = ([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ")
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
        return .commandFailed(command: command, exitCode: result.exitCode, detail: detail)
    }
}

/// Probe über die SoftwareUpdate-Plist: Einstellungen und ausstehende Updates aus einem einzigen Lesevorgang.
struct SoftwareUpdateProbe: SecurityProbe {
    let readPreferences: @Sendable () throws -> Data

    var kinds: [SecurityCheckKind] { [.automaticUpdates, .pendingUpdates] }

    func read(now: Date) async throws -> [SecurityFacts] {
        let preferences = try SoftwareUpdatePreferences(data: readPreferences())
        return [
            .automaticUpdates(disabled: preferences.disabledKeys),
            .pendingUpdates(
                updates: preferences.pendingUpdates(firstSeenFallback: now), lastCheck: preferences.lastSuccessfulCheck
            ),
        ]
    }
}
