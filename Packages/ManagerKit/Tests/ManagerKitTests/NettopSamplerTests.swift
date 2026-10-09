import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1))) struct NettopSamplerTests {
    private let header = NettopParser.header
    private let instants = SteppedInstants()
    private let sleeps = RecordedSleeps()

    private func sampler(_ streamer: ScriptedLineStreamer, instants: SteppedInstants? = nil) -> NettopSampler {
        NettopSampler(streamer: streamer, now: { [instants = instants ?? self.instants] in instants.next() },
                      sleep: { [sleeps] in try await sleeps.sleep($0) })
    }

    /// Ein Lauf, der `count` Messungen liefert (eine Prozesszeile je Block) und dann endet.
    private func deliveringRun(samples count: Int, linesPerBlock: Int = 1) -> ScriptedLineStreamer.Run {
        let block = [header] + Array(repeating: "a.1,,1,2,", count: linesPerBlock)
        return .init(Array(Array(repeating: block, count: count).joined()) + [header])
    }

    @Test func callsNettopWithCSVArguments() {
        #expect(NettopSampler.executable == "/usr/bin/nettop")
        #expect(NettopSampler().arguments == ["-L", "0", "-s", "2", "-n", "-x", "-J", "state,bytes_in,bytes_out"])
    }

    /// Ein Block endet mit der nächsten Kopfzeile und trägt den Zeitpunkt seiner eigenen Kopfzeile.
    @Test func splitsOutputAtHeaders() async throws {
        let streamer = ScriptedLineStreamer([.init([
            header, "a.1,,10,20,", "tcp4 192.0.2.1:50000<->192.0.2.10:443,Established,10,20,",
            header, "b.2,,5,6,", header,
        ], ending: .hangUntilCancelled)])
        let (samples, continuation) = AsyncStream.makeStream(of: TimedNettopSample.self)
        let task = Task { [sampler = sampler(streamer)] in try await sampler.run { continuation.yield($0) } }

        var received: [TimedNettopSample] = []
        for await sample in samples {
            received.append(sample)
            if received.count == 2 { break }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(received.map { $0.sample.processes.map(\.shortName) } == [["a"], ["b"]])
        #expect(received[0].sample.processes[0].connections.count == 1)
        #expect(received[0].capturedAt == instants.base)
        #expect(received[1].capturedAt == instants.base + .seconds(3))
        #expect(streamer.terminatedRuns == 1)
        #expect(sleeps.durations.isEmpty)
    }

    /// Die Startzeit wird beim Eingang der Prozesszeile gelesen, nicht erst beim Abschluss des Blocks ein Intervall
    /// später – ein Prozess, der dazwischen endet, behält so seine Identität.
    @Test func capturesStartTimeWhenProcessLineArrives() throws {
        let running = Mutex<Set<Int32>>([7])
        let assembler = NettopSampleAssembler(startTime: { pid in running.withLock { $0.contains(pid) } ? 100 : nil })
        let now = ContinuousClock.now
        _ = try assembler.consume(header, at: now)
        _ = try assembler.consume("curl.7,,1,2,", at: now)
        _ = try assembler.consume("tcp4 192.0.2.1:50000<->192.0.2.10:443,Established,1,2,", at: now)
        _ = try assembler.consume("weg.8,,3,4,", at: now)
        running.withLock { $0 = [] }
        let sample = try #require(try assembler.consume(header, at: now + .seconds(2)))
        #expect(sample.sample.processes.map(\.startTime) == [100, nil])
    }

    /// Auch täuschende Namen brauchen die beim Zeileneingang erfasste Startzeit für die PID-Zuordnung.
    @Test func capturesStartTimesForHostileProcessNames() throws {
        let assembler = NettopSampleAssembler(startTime: { UInt64($0) * 100 })
        let now = ContinuousClock.now
        for line in [header, ",x.42,,1,2,", "tcp4 a<->b.43,,3,4,"] {
            _ = try assembler.consume(line, at: now)
        }
        let sample = try #require(try assembler.consume(header, at: now + .seconds(2)))
        #expect(sample.sample.processes.map(\.pid) == [42, 43])
        #expect(sample.sample.processes.map(\.startTime) == [4200, 4300])
    }

    @Test func restartsWithBackoffAndGivesUpAfterThreeFailures() async {
        let streamer = ScriptedLineStreamer([.init(ending: .exit(1)), .init(ending: .exit(0)), .init(ending: .exit(1))])
        await #expect(throws: NettopSamplerError.endedRepeatedly(count: 3)) {
            try await sampler(streamer).run { _ in }
        }
        #expect(streamer.startedRuns == 3)
        #expect(sleeps.durations == [.seconds(1), .seconds(2)])
    }

    /// Ein stabiler Lauf (≥ 5 Messungen) setzt den Backoff zurück; Läufe ohne Messung führen beim dritten in Folge
    /// zum Fehlerzustand.
    @Test func stableRunResetsBackoff() async {
        let streamer = ScriptedLineStreamer([
            .init(), .init(), deliveringRun(samples: NettopSampler.stableRunSamples), .init(), .init(), .init(),
        ])
        await #expect(throws: NettopSamplerError.endedRepeatedly(count: 3)) {
            try await sampler(streamer).run { _ in }
        }
        #expect(streamer.startedRuns == 6)
        #expect(sleeps.durations == [.seconds(1), .seconds(2), .seconds(1), .seconds(2), .seconds(4)])
    }

    /// Ein Lauf über mindestens 30 s gilt auch mit nur einer Messung als stabil.
    @Test func longRunResetsBackoff() async {
        let streamer = ScriptedLineStreamer([
            deliveringRun(samples: 1), deliveringRun(samples: 1), deliveringRun(samples: 1, linesPerBlock: 2),
            .init(), .init(), .init(),
        ])
        await #expect(throws: NettopSamplerError.endedRepeatedly(count: 3)) {
            try await sampler(streamer, instants: SteppedInstants(step: .seconds(10))).run { _ in }
        }
        #expect(sleeps.durations == [.seconds(1), .seconds(2), .seconds(1), .seconds(2), .seconds(4)])
    }

    /// Ein nettop, das je Lauf kurz Messungen liefert und endet, startet nicht endlos neu: Der Backoff wächst bis
    /// 30 s, nach `maximumConsecutiveRestarts` instabilen Läufen in Folge endet `run` im Fehlerzustand.
    @Test func shortDeliveringRunsBackOffAndGiveUp() async {
        let runs = Array(repeating: deliveringRun(samples: 1), count: NettopSampler.maximumConsecutiveRestarts)
        let streamer = ScriptedLineStreamer(runs)
        let delivered = Mutex(0)
        await #expect(throws: NettopSamplerError.endedRepeatedly(count: NettopSampler.maximumConsecutiveRestarts)) {
            try await sampler(streamer).run { _ in delivered.withLock { $0 += 1 } }
        }
        #expect(streamer.startedRuns == NettopSampler.maximumConsecutiveRestarts)
        #expect(delivered.withLock { $0 } == NettopSampler.maximumConsecutiveRestarts)
        #expect(sleeps.durations == [1, 2, 4, 8, 16, 30].map { .seconds($0) })
    }

    @Test func launchFailureEndsImmediately() async {
        let streamer = ScriptedLineStreamer([.init(ending: .launchFailure)])
        await #expect(throws: NettopSamplerError.launchFailed(reason: "No such file or directory")) {
            try await sampler(streamer).run { _ in }
        }
        #expect(sleeps.durations.isEmpty)
    }

    /// Fremde Ausgabe vor der ersten Kopfzeile oder eine unbekannte Kopfzeile beendet nettop und den Sampler.
    @Test func unknownFormatStopsNettop() async {
        for lines in [["Usage: nettop …", header], [",state,bytes_in,", "a.1,,1,", ",state,bytes_in,"]] {
            let streamer = ScriptedLineStreamer([.init(lines, ending: .hangUntilCancelled)])
            await #expect(throws: NettopSamplerError.unrecognizedFormat) {
                try await sampler(streamer).run { _ in }
            }
            #expect(streamer.terminatedRuns == 1)
        }
    }

    @Test func backoffDoublesUpToThirtySeconds() {
        #expect((1...7).map(NettopSampler.backoff(afterRestarts:)) == [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) })
    }
}
