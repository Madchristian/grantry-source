import Foundation

/// `LineStreaming` per `Process`: stdout ereignisgesteuert über `DispatchIO` (kein blockierter Thread), stderr
/// auf `/dev/null`, stdin bleibt ohne Eingaben offen. Beendet wird – wie bei `ProcessCommandRunner` – nur der direkte Kindprozess.
///
/// Stirbt die App, ohne den Aufruf abzubrechen, schließt das System die Pipe; der Kindprozess erhält beim nächsten
/// Schreiben SIGPIPE und endet ebenfalls.
public struct ProcessLineStreamer: LineStreaming {
    /// Wartezeit zwischen SIGTERM und SIGKILL beim Beenden.
    public let terminationGracePeriod: Duration

    public init(terminationGracePeriod: Duration = .seconds(1)) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(
        _ executable: String, _ arguments: [String], onLine: @Sendable (String) throws -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // nettop dreht bei sofortigem EOF (/dev/null) in einer CPU-intensiven Schleife.
        // Die leere Pipe bleibt bis zum Prozessende offen; defer hält beide Handles auch über await hinweg am Leben.
        let stdinPipe = Pipe()
        defer {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForReading.close()
        }
        process.standardInput = stdinPipe
        process.standardError = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // Der Handler muss vor `run()` gesetzt sein, sonst geht ein sehr schnelles Prozessende verloren.
        let exit = ExitSignal()
        process.terminationHandler = { exit.signal($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(executable: executable, reason: error.localizedDescription)
        }

        let pid = process.processIdentifier
        do {
            var splitter = LineSplitter()
            for await chunk in PipeReader.chunks(stdoutPipe.fileHandleForReading) {
                try Task.checkCancellation()
                for line in splitter.append(chunk) {
                    try onLine(line)
                }
            }
            try Task.checkCancellation()
            if let rest = splitter.finish() { try onLine(rest) }
        } catch {
            await ChildProcess.forceExitUnlessCancelled(pid: pid, exit: exit, gracePeriod: terminationGracePeriod)
            throw error
        }
        if let status = await exit.wait() { return status }
        await ChildProcess.forceExitUnlessCancelled(pid: pid, exit: exit, gracePeriod: terminationGracePeriod)
        throw CancellationError()
    }
}
