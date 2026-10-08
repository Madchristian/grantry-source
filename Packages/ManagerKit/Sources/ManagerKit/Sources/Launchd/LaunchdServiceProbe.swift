import Foundation

/// Fragt per `launchctl print <domain>/<label>` ab, aus welcher Plist ein geladener Dienst stammt
/// (`LaunchdServiceBinding`, GrantryShared – dieselbe Auswertung nutzt der Helper für die Domain `system`).
struct LaunchdServiceProbe: Sendable {
    let runner: any CommandRunning

    /// Zuordnung des Dienstes `label` in `domain` zur Plist `plistPath`.
    ///
    /// - Throws: `LaunchdSourceError.launchctlFailed` bei Startfehlern und anderen Exit-Codes als 0 oder
    ///   `LaunchdServiceBinding.serviceNotFoundExitCode`; `CancellationError` unverändert.
    func binding(ofLabel label: String, in domain: String, toPlistAt plistPath: String) async throws -> LaunchdServiceBinding {
        let arguments = LaunchdServiceBinding.printArguments(domain: domain, label: label)
        let result = try await runner.launchctl(arguments, domain: domain)
        guard let binding = LaunchdServiceBinding(printResult: result, plistPath: plistPath) else {
            throw LaunchdSourceError.failed(result, domain: domain, arguments: arguments)
        }
        return binding
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

extension LaunchdSourceError {
    /// Gescheiterter Aufruf mit dem Exit-Code von `result` und `message` bzw. dessen `stderr`.
    static func failed(_ result: CommandResult, domain: String, arguments: [String], message: String? = nil) -> LaunchdSourceError {
        .launchctlFailed(
            domain: domain, arguments: arguments, exitCode: result.exitCode,
            message: message ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
