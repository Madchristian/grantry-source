import Foundation

/// Führt Befehle per `Process` aus.
///
/// - stdout und stderr werden parallel und ereignisgesteuert (`DispatchIO`) gelesen, damit volle Pipes weder den
///   Kindprozess noch einen Thread blockieren.
/// - `timeout` begrenzt die Gesamtdauer: Läuft der Prozess dann noch, erhält er SIGTERM und nach
///   `terminationGracePeriod` SIGKILL. Halten Nachfahren die Pipes über den Timeout hinaus offen, gilt die
///   Ausgabe als unvollständig und es wird ebenfalls `CommandError.timedOut` geworfen.
/// - Beendet wird nur der direkte Kindprozess. Von ihm gestartete Nachfahren (z. B. per `&` im Hintergrund)
///   erhalten kein Signal und können einen Timeout überleben.
/// - Ein Abbruch des aufrufenden Tasks beendet den Prozess auf dieselbe Weise – inklusive Gnadenfrist und
///   Warten auf das Prozessende – und wirft anschließend `CancellationError`.
/// - stdin ist `/dev/null`, damit kein Befehl auf Eingaben wartet.
public struct ProcessCommandRunner: CommandRunning {
    /// Wartezeit zwischen SIGTERM und SIGKILL beim Beenden nach Timeout.
    public let terminationGracePeriod: Duration

    /// Standard für `terminationGracePeriod`; ein Befehl kann seine Frist um bis zu diese Dauer überschreiten.
    public static let defaultTerminationGracePeriod: Duration = .seconds(2)

    public init(terminationGracePeriod: Duration = defaultTerminationGracePeriod) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Der Handler muss vor `run()` gesetzt sein, sonst geht ein sehr schnelles Prozessende verloren.
        let exit = ExitSignal()
        process.terminationHandler = { exit.signal($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(executable: executable, reason: error.localizedDescription)
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let output = await ChildProcess.withDeadline(timeout) { () -> CommandResult? in
            async let stdout = PipeReader.readToEnd(stdoutHandle)
            async let stderr = PipeReader.readToEnd(stderrHandle)
            guard let status = await exit.wait(), let stdout = await stdout, let stderr = await stderr else {
                return nil
            }
            return CommandResult(
                exitCode: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
        if let output { return output }

        // Das Aufräumen läuft in einem eigenen Task, damit ein abgebrochener Aufrufer weder die Gnadenfrist
        // noch das Warten auf das Prozessende verkürzt.
        await ChildProcess.forceExitUnlessCancelled(pid: process.processIdentifier, exit: exit,
                                                    gracePeriod: terminationGracePeriod)
        try Task.checkCancellation()
        throw CommandError.timedOut(executable: executable, seconds: timeout.seconds)
    }
}
