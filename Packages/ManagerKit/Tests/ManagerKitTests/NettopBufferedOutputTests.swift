import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Echter Mitschnitt von nettop über eine Pipe (`Fixtures/nettop-buffered-run.json`, macOS 27.2): nettop gibt seine
/// Ausgabe nicht zeilenweise ab, sondern in Stücken von 16 KiB. Die ersten beiden Messungen eines Laufs kommen im
/// selben Stück an, später immer wieder zwei Kopfzeilen zusammen – der Eingang einer Kopfzeile sagt nichts über den
/// Zeitpunkt ihrer Messung (Bewertung 2026.11.7-1188, Mangel 2: Netzraten um Faktor 100–2000 überhöht).
@Suite struct NettopBufferedOutputTests {
    /// Der Mitschnitt: die Zeilen je Stück mit dessen Ankunft (Sekunden seit dem Start von nettop) und die Byte-Zähler
    /// aller Schnittstellen (`netstat -ib`, Empfangen + Senden) vor dem Start und nach jedem Stück.
    struct Recording: Decodable {
        struct Interfaces: Decodable {
            let at: Double
            let bytes: UInt64
        }

        struct Chunk: Decodable {
            let at: Double
            let lines: [String]
            let interfaces: Interfaces
        }

        let arguments: [String]
        let interval: Int
        let interfacesBeforeLaunch: Interfaces
        let chunks: [Chunk]

        static func load() throws -> Recording {
            let url = try #require(Bundle.module.url(forResource: "nettop-buffered-run", withExtension: "json",
                                                     subdirectory: "Fixtures"))
            return try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
        }

        /// Lesungen der Schnittstellen, älteste zuerst.
        var interfaceReadings: [Interfaces] { [interfacesBeforeLaunch] + chunks.map(\.interfaces) }

        /// Eingang jeder Kopfzeile, wenn nettop zur Zeit `base` startete.
        func headerArrivals(base: ContinuousClock.Instant) -> [ContinuousClock.Instant] {
            chunks.flatMap { chunk in
                chunk.lines.indices.filter { chunk.lines[$0] == NettopParser.header }
                    .map { base + .seconds(chunk.at) + .microseconds($0) }
            }
        }

        /// Je Messung die Lesung der Schnittstellen, wie `ActivityPipeline` sie nimmt: wenn der Block fertig ist, also
        /// nach dem Stück mit der nächsten Kopfzeile.
        func readingsAtCompletion(base: ContinuousClock.Instant) -> [InterfaceByteReading] {
            chunks.flatMap { chunk in
                Array(repeating: Self.reading(chunk.interfaces, base: base),
                      count: chunk.lines.filter { $0 == NettopParser.header }.count)
            }.dropFirst().map { $0 }
        }

        static func reading(_ interfaces: Interfaces, base: ContinuousClock.Instant) -> InterfaceByteReading {
            InterfaceByteReading(instant: base + .seconds(interfaces.at), bytes: [0: interfaces.bytes])
        }

        /// Höchste Gesamtrate, die die Schnittstellen für die Messungen `first…last` (nettops Takt ab dem Start)
        /// zulassen: alles, was sie zwischen der letzten Lesung vor der ersten und der ersten Lesung nach der letzten
        /// Messung übertragen haben, verteilt auf den Abstand der Messungen.
        func interfaceBound(fromBlock first: Int, toBlock last: Int) throws -> Double {
            let start = Double(first * interval)
            let end = Double(last * interval)
            let before = try #require(interfaceReadings.last { $0.at <= start })
            let after = try #require(interfaceReadings.first { $0.at >= end })
            return Double(after.bytes - before.bytes) / (end - start)
        }
    }

    /// Spielt den Mitschnitt ab: Jede Zeile kommt mit ihrem Stück an (je Zeile 1 µs Verarbeitung), danach endet nettop.
    final class ReplayStreamer: LineStreaming {
        private let recording: Recording
        private let clock: Mutex<ContinuousClock.Instant>
        let base: ContinuousClock.Instant

        init(_ recording: Recording, base: ContinuousClock.Instant) {
            self.recording = recording
            self.base = base
            clock = Mutex(base)
        }

        var now: ContinuousClock.Instant { clock.withLock { $0 } }

        func run(_ executable: String, _ arguments: [String], onLine: @Sendable (String) throws -> Void) async throws -> Int32 {
            #expect(arguments == recording.arguments)
            for chunk in recording.chunks {
                for (index, line) in chunk.lines.enumerated() {
                    clock.withLock { $0 = base + .seconds(chunk.at) + .microseconds(index) }
                    try onLine(line)
                }
            }
            return 0
        }
    }

    /// Die Messungen des Mitschnitts, wie `NettopSampler` sie liefert; alle Prozesse liefen schon vor dem Start.
    private func replay(_ recording: Recording) async throws -> (samples: [TimedNettopSample], base: ContinuousClock.Instant) {
        let streamer = ReplayStreamer(recording, base: ContinuousClock.now)
        let sampler = NettopSampler(streamer: streamer, interval: recording.interval,
                                    identity: { _ in NettopProcessIdentity(startTime: 1) },
                                    now: { streamer.now }, sleep: { _ in throw CancellationError() })
        let samples = Mutex<[TimedNettopSample]>([])
        await #expect(throws: CancellationError.self) {
            try await sampler.run { sample in samples.withLock { $0.append(sample) } }
        }
        return (samples.withLock { $0 }, streamer.base)
    }

    /// Empfangen + Senden aller Prozesse, die in beiden Messungen mit Zählern stehen und nicht neu begonnen haben.
    private func transferredBytes(from previous: NettopSample, to current: NettopSample) -> UInt64 {
        let before = Dictionary(previous.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return current.processes.reduce(0) { sum, process in
            guard let old = before[process.pid], let oldIn = old.bytesIn, let oldOut = old.bytesOut,
                  let newIn = process.bytesIn, let newOut = process.bytesOut, newIn >= oldIn, newOut >= oldOut
            else { return sum }
            return sum + (newIn - oldIn) + (newOut - oldOut)
        }
    }

    /// Jede Messung trägt den Zeitpunkt aus nettops Takt, nicht den Eingang ihrer Kopfzeile.
    @Test func samplesFollowNettopsIntervalDespiteBufferedOutput() async throws {
        let recording = try Recording.load()
        let (samples, _) = try await replay(recording)

        #expect(samples.count == 6)
        #expect(samples.allSatisfy { $0.sample.skippedLineCount == 0 })
        for (previous, current) in zip(samples, samples.dropFirst()) {
            #expect(current.capturedAt - previous.capturedAt == .seconds(recording.interval))
        }
    }

    /// Die erste Rate nach dem Start ist der Zuwachs der Zähler über ein Intervall – kein Sprung.
    @Test func firstRateAfterStartMatchesTransferredBytes() async throws {
        let recording = try Recording.load()
        let (samples, _) = try await replay(recording)
        try #require(samples.count >= 2)

        var tracker = TrafficTracker()
        let baseline = tracker.update(with: samples[0].sample, at: samples[0].capturedAt)
        let first = tracker.update(with: samples[1].sample, at: samples[1].capturedAt)

        #expect(baseline.history.isEmpty)
        let expected = Double(transferredBytes(from: samples[0].sample, to: samples[1].sample)) / Double(recording.interval)
        #expect(abs(first.total.total - expected) <= expected * 1e-9)
    }

    /// Gegenprobe gegen die Byte-Zähler der Schnittstellen im selben Mitschnitt: Die geglättete Gesamtrate liegt bei
    /// jeder Messung unter dem, was die Schnittstellen im Glättungsfenster übertragen haben.
    @Test func totalRateStaysBelowInterfaceCounters() async throws {
        let recording = try Recording.load()
        let (samples, _) = try await replay(recording)

        var tracker = TrafficTracker()
        for (index, sample) in samples.enumerated() {
            let report = tracker.update(with: sample.sample, at: sample.capturedAt)
            guard index > 0 else { continue }
            let bound = try recording.interfaceBound(fromBlock: max(0, index - TrafficTracker.smoothingWindow),
                                                     toBlock: index)
            #expect(report.total.total <= bound, "Messung \(index): \(report.total.total) B/s über \(bound) B/s")
        }
    }

    /// Gesamtraten einer Folge von Messungen; mit `readings` (vor dem Start, dann je Messung) samt Plausibilitätsdeckel.
    private func totals(_ samples: [TimedNettopSample], interval: Int, readings: (before: InterfaceByteReading,
                        atCompletion: [InterfaceByteReading])? = nil) -> [Double] {
        var tracker = TrafficTracker(sampleInterval: .seconds(interval))
        if let readings { tracker.record(readings.before) }
        return samples.enumerated().map { index, sample in
            if let readings { tracker.record(readings.atCompletion[index]) }
            return tracker.update(with: sample.sample, at: sample.capturedAt).total.total
        }
    }

    /// Mit den Schnittstellenzählern des Mitschnitts bleiben richtig gemessene Raten unverändert.
    @Test func interfaceCapLeavesMeasuredRatesUntouched() async throws {
        let recording = try Recording.load()
        let (samples, base) = try await replay(recording)
        let readings = (before: Recording.reading(recording.interfacesBeforeLaunch, base: base),
                        atCompletion: recording.readingsAtCompletion(base: base))

        #expect(totals(samples, interval: recording.interval, readings: readings)
            == totals(samples, interval: recording.interval))
    }

    /// Zweite Sicherung: Mit den früheren Zeitpunkten (Eingang der Kopfzeile) kappt der Deckel die Gesamtrate auf
    /// höchstens den Verkehr, den die Schnittstellen im ganzen Mitschnitt hatten, je 90 % eines Intervalls.
    @Test func interfaceCapBoundsMistimedSamples() async throws {
        let recording = try Recording.load()
        let (samples, base) = try await replay(recording)
        let arrivals = recording.headerArrivals(base: base)
        let mistimed = samples.enumerated().map { TimedNettopSample(sample: $1.sample, capturedAt: arrivals[$0]) }
        let readings = (before: Recording.reading(recording.interfacesBeforeLaunch, base: base),
                        atCompletion: recording.readingsAtCompletion(base: base))
        let all = recording.interfaceReadings
        let bound = Double(all[all.count - 1].bytes - all[0].bytes) / (0.9 * Double(recording.interval))

        #expect(totals(mistimed, interval: recording.interval).contains { $0 > bound })
        #expect(totals(mistimed, interval: recording.interval, readings: readings).allSatisfy { $0 <= bound })
    }
}
