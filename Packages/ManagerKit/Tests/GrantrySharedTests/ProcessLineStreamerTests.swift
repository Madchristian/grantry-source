import Foundation
import Synchronization
import Testing
@testable import GrantryShared

@Suite(.timeLimit(.minutes(1))) struct ProcessLineStreamerTests {
    private struct Stop: Error {}

    @Test func deliversLinesInOrderAndExitStatus() async throws {
        let lines = Mutex<[String]>([])
        let status = try await ProcessLineStreamer().run("/bin/sh", ["-c", "printf 'a\\nb\\n'; printf c; exit 3"]) { line in
            lines.withLock { $0.append(line) }
        }
        #expect(status == 3)
        #expect(lines.withLock { $0 } == ["a", "b", "c"])
    }

    @Test func reportsLaunchFailure() async {
        let error = await #expect(throws: CommandError.self) {
            try await ProcessLineStreamer().run("/nonexistent/binary", []) { _ in }
        }
        guard case .launchFailed(let executable, _)? = error else {
            Issue.record("Erwartet launchFailed, erhalten: \(String(describing: error))")
            return
        }
        #expect(executable == "/nonexistent/binary")
    }

    /// Ein stilles Kind erhält weder Eingaben noch EOF und bleibt beim Warten auf stdin abbrechbar.
    @Test func keepsStandardInputOpenUntilCancellation() async throws {
        let lines = Mutex<[String]>([])
        let finished = Mutex(false)
        let (pids, continuation) = AsyncStream.makeStream(of: pid_t.self)
        let task = Task {
            defer {
                finished.withLock { $0 = true }
                continuation.finish()
            }
            return try await ProcessLineStreamer().run(
                "/bin/sh", ["-c", "echo $$; if IFS= read -r line; then echo input; else echo eof; fi"]
            ) { line in
                if let pid = pid_t(line) { continuation.yield(pid) }
                else { lines.withLock { $0.append(line) } }
            }
        }
        defer { task.cancel() }
        let pid = try #require(await pids.first { _ in true })
        // Das Kind hat begonnen; ein sofortiges EOF darf es nicht aus `read` aufwecken.
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines.withLock { $0 }.isEmpty)
        #expect(!finished.withLock { $0 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1, "Auch das auf stdin wartende Kind muss beendet sein")
    }

    /// Abbruch beendet auch einen Prozess, der SIGTERM ignoriert (SIGKILL nach der Gnadenfrist), und kehrt erst nach
    /// seinem Ende zurück.
    @Test func cancellationTerminatesChild() async throws {
        let streamer = ProcessLineStreamer(terminationGracePeriod: .milliseconds(300))
        let (pids, continuation) = AsyncStream.makeStream(of: pid_t.self)
        let task = Task {
            try await streamer.run("/bin/sh", ["-c", "trap '' TERM; echo $$; while :; do echo x; sleep 0.1; done"]) { line in
                if let pid = pid_t(line) { continuation.yield(pid) }
            }
        }
        let pid = try #require(await pids.first { _ in true })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1, "Prozess \(pid) muss beendet sein, wenn run() zurückkehrt")
    }

    @Test func throwingHandlerTerminatesChild() async throws {
        let pid = Mutex<pid_t?>(nil)
        await #expect(throws: Stop.self) {
            try await ProcessLineStreamer().run("/bin/sh", ["-c", "echo $$; while :; do echo x; sleep 0.1; done"]) { line in
                if let value = pid_t(line) { pid.withLock { $0 = value } } else { throw Stop() }
            }
        }
        let child = try #require(pid.withLock { $0 })
        #expect(kill(child, 0) == -1)
    }

    @Test func splitterJoinsLinesAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("ab".utf8)) == [])
        #expect(splitter.append(Data("c\nde\n\nf".utf8)) == ["abc", "de", ""])
        #expect(splitter.finish() == "f")
        #expect(splitter.finish() == nil)
    }

    /// Eine Zeile ohne Zeilenende über dem Limit wird genau am Limit abgeschnitten; der Rest bleibt für die nächste.
    @Test func splitterCutsOverlongLines() {
        var splitter = LineSplitter()
        let lines = splitter.append(Data(repeating: 0x61, count: LineSplitter.maximumLineLength + 1))
        #expect(lines.map(\.count) == [LineSplitter.maximumLineLength])
        #expect(splitter.finish() == "a")
    }

    @Test func splitterCutsOverlongLinesWithinOneChunk() {
        var splitter = LineSplitter()
        let limit = LineSplitter.maximumLineLength
        let chunk = Data(repeating: 0x61, count: limit) + Data("\n".utf8)
            + Data(repeating: 0x62, count: limit + 2) + Data("\nc".utf8)
        #expect(splitter.append(chunk).map(\.count) == [limit, limit, 2])
        #expect(splitter.finish() == "c")
    }
}
