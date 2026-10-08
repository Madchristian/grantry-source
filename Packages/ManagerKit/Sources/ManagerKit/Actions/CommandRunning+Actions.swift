import Foundation

extension CommandRunning {
    /// Führt einen Befehl einer Aktion aus; ein Exit-Code ungleich 0 wird zu `ActionError.commandFailed`.
    ///
    /// Meldung ohne `failureMessage`: `<Befehl> fehlgeschlagen (Exit <n>): <Detail>`; mit `failureMessage`:
    /// `<failureMessage>: <Befehl> (Exit <n>): <Detail>`. Detail ist `stderr`, ersatzweise `stdout`; ist beides leer,
    /// entfällt `: <Detail>`.
    func runChecked(_ executable: String, _ arguments: [String], failureMessage: String? = nil) async throws {
        let result = try await run(executable, arguments)
        guard result.succeeded else {
            let command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
            let detail = result.failureDetail
            let suffix = "(Exit \(result.exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
            throw ActionError.commandFailed(
                failureMessage.map { "\($0): \(command) \(suffix)" } ?? "\(command) fehlgeschlagen \(suffix)"
            )
        }
    }
}

extension CommandResult {
    /// Meldung zu einem Fehlschlag: `stderr`, ersatzweise `stdout`, jeweils ohne Leerraum am Rand; leer, wenn beides
    /// leer ist.
    var failureDetail: String {
        let stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
    }
}
