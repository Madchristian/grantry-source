import Darwin
import Foundation
import Testing
@testable import ManagerKit

/// Opt-in gegen das echte `/usr/bin/nettop` (`MANAGERKIT_LIVE=1`), nie in der CI: Format, Prozesszuordnung und dass
/// nach dem Abbruch kein nettop zurückbleibt.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"), .timeLimit(.minutes(1)))
struct NettopLiveTests {
    @Test func samplerReadsRealNettopAndLeavesNoProcessBehind() async throws {
        let sampler = NettopSampler(interval: 1)
        let (samples, continuation) = AsyncStream.makeStream(of: TimedNettopSample.self)
        let task = Task { try await sampler.run { continuation.yield($0) } }

        var received: [TimedNettopSample] = []
        for await sample in samples {
            received.append(sample)
            if received.count == 2 { break }
        }
        #expect(!Self.nettopChildren().isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(Self.nettopChildren().isEmpty, "nettop muss nach dem Abbruch beendet sein")
        try #require(received.count == 2)
        let kernel = received.first?.sample.processes.first { $0.pid == 0 }
        #expect(kernel?.shortName == "kernel_task")
        #expect(received.allSatisfy { $0.sample.skippedLineCount == 0 })

        var tracker = TrafficTracker()
        _ = tracker.update(with: received[0].sample, at: received[0].capturedAt)
        let report = tracker.update(with: received[1].sample, at: received[1].capturedAt)
        let programs = ActivityProgramResolver().programs(for: report.processes.map(\.key)).programs
        print("Prozesse: \(report.processes.count), mit Programm: \(programs.count), gesamt ↓ \(TrafficFormat.rate(report.total.download)) ↑ \(TrafficFormat.rate(report.total.upload))")
        #expect(programs.count > report.processes.count / 2)
    }

    /// Direkte Kindprozesse dieses Testprozesses, die `/usr/bin/nettop` ausführen.
    private static func nettopChildren() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 512)
        _ = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.filter { $0 > 0 && LibprocProcessInspector.executablePath(of: $0) == NettopSampler.executable }
    }
}
