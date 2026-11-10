import Foundation

/// Zuordnung eines Dienstes zu einer Plist samt PID desselben `launchctl print`-Aufrufs.
struct LaunchdServiceState: Equatable, Sendable {
    let binding: LaunchdServiceBinding
    /// PID des laufenden Dienstes; `nil`, solange er nicht läuft oder die Ausgabe keine nennt.
    let pid: Int32?
}

/// Fragt per `launchctl print <domain>/<label>` ab, aus welcher Plist ein geladener Dienst stammt
/// (`LaunchdServiceBinding`, GrantryShared – dieselbe Auswertung nutzt der Helper für die Domain `system`).
struct LaunchdServiceProbe: Sendable {
    let runner: any CommandRunning

    /// Zuordnung des Dienstes `label` in `domain` zur Plist `plistPath`.
    ///
    /// - Throws: `LaunchdSourceError.launchctlFailed` bei Startfehlern und anderen Exit-Codes als 0 oder
    ///   `LaunchdServiceBinding.serviceNotFoundExitCode`; `CancellationError` unverändert.
    func binding(ofLabel label: String, in domain: String, toPlistAt plistPath: String) async throws -> LaunchdServiceBinding {
        try await state(ofLabel: label, in: domain, toPlistAt: plistPath).binding
    }

    /// Zuordnung wie `binding(ofLabel:in:toPlistAt:)` und dazu die PID des Dienstes, aus demselben Aufruf: Wer vor einem
    /// Signal den Prozess prüft, liest ihn so zum gleichen Zeitpunkt wie die Zuordnung.
    func state(ofLabel label: String, in domain: String, toPlistAt plistPath: String) async throws -> LaunchdServiceState {
        let arguments = LaunchdServiceBinding.printArguments(domain: domain, label: label)
        let result = try await runner.launchctl(arguments, domain: domain)
        guard let binding = LaunchdServiceBinding(printResult: result, plistPath: plistPath) else {
            throw LaunchdSourceError.failed(result, domain: domain, arguments: arguments)
        }
        return LaunchdServiceState(binding: binding,
                                   pid: result.succeeded ? LaunchdServiceBinding.servicePID(in: result.stdout) : nil)
    }
}

extension LaunchdServiceBinding {
    /// `launchctl print <domain>/<label>` → PID des Dienstes (`pid = …`), `nil` ohne gültige PID. Wie bei
    /// `servicePlistPath(in:)` zählt nur die erste Zeile auf oberster Ebene des Dienstblocks (genau ein Tab eingerückt).
    static func servicePID(in output: String) -> Int32? {
        let prefix = "\tpid = "
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }),
              let pid = Int32(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)), pid > 0 else {
            return nil
        }
        return pid
    }
}

extension CommandRunning {
    /// Führt `launchctl arguments` aus. Startfehler und Zeitüberschreitungen werden zu
    /// `LaunchdSourceError.launchctlFailed` ohne Exit-Code, `CancellationError` bleibt unverändert.
    func launchctl(_ arguments: [String], domain: String) async throws -> CommandResult {
        do {
            return try await run(LaunchdSource.launchctl, arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LaunchdSourceError.launchctlFailed(
                domain: domain, arguments: arguments, exitCode: nil, message: error.readableDescription
            )
        }
    }
}

extension CommandRunning {
    /// Geparste Standardausgabe von `launchctl arguments`. `CancellationError` wird unverändert weitergereicht, jeder
    /// andere Fehler, jeder Exit-Code ungleich 0 und eine vom Parser abgelehnte Ausgabe (`nil`) als
    /// `LaunchdSourceError.launchctlFailed`.
    func launchctl<Parsed>(_ arguments: [String], domain: String, parse: (String) -> Parsed?) async throws -> Parsed {
        let result = try await launchctl(arguments, domain: domain)
        if result.succeeded, let parsed = parse(result.stdout) { return parsed }
        throw LaunchdSourceError.failed(
            result, domain: domain, arguments: arguments, message: result.succeeded ? "unerwartetes Ausgabeformat" : nil
        )
    }
}

extension LaunchdSourceError {
    /// Gescheiterter Aufruf mit dem Exit-Code von `result` und `message` bzw. dessen `stderr`.
    static func failed(_ result: CommandResult, domain: String, arguments: [String], message: String? = nil) -> LaunchdSourceError {
        .launchctlFailed(
            domain: domain, arguments: arguments, exitCode: result.exitCode,
            message: message ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
