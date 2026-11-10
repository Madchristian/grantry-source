import Darwin
import Foundation
import Testing
@testable import ManagerKit

/// Opt-in gegen das echte `/usr/bin/nettop` (`MANAGERKIT_LIVE=1`), nie in der CI: Format, Prozesszuordnung, dass
/// nach dem Abbruch kein nettop zurückbleibt, und die Gegenprobe der Raten. Nacheinander, denn jeder Test zählt die
/// nettop-Kindprozesse dieses Testprozesses.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"), .timeLimit(.minutes(1)), .serialized)
struct NettopLiveTests {
    @Test func samplerReadsRealNettopAndLeavesNoProcessBehind() async throws {
        let sampler = NettopSampler()
        let (samples, continuation) = AsyncStream.makeStream(of: TimedNettopSample.self)
        let task = Task { try await sampler.run { continuation.yield($0) } }

        var received: [TimedNettopSample] = []
        for await sample in samples {
            received.append(sample)
            if received.count == 3 { break }
        }
        #expect(!Self.nettopChildren().isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(Self.nettopChildren().isEmpty, "nettop muss nach dem Abbruch beendet sein")
        try #require(received.count == 3)
        // CPU-schonendes nettop muss im CSV-Modus weiterhin im angeforderten 2-s-Takt liefern.
        // Spielraum für Start und Scheduling; ein verdoppeltes Intervall ist keine gültige Abtastung.
        for (previous, current) in zip(received, received.dropFirst()) {
            let interval = current.capturedAt - previous.capturedAt
            #expect(interval >= .seconds(1) && interval < .seconds(3))
        }
        // nettop listet kernel_task auf macOS 27.2 nicht mehr; launchd (PID 1) hat immer lauschende Sockets.
        let launchd = received.first?.sample.processes.first { $0.pid == 1 }
        #expect(launchd?.shortName == "launchd")
        #expect(received.allSatisfy { $0.sample.skippedLineCount == 0 })

        var tracker = TrafficTracker()
        _ = tracker.update(with: received[0].sample, at: received[0].capturedAt)
        let report = tracker.update(with: received[1].sample, at: received[1].capturedAt)
        let programs = ActivityProgramResolver().programs(for: report.processes.map(\.key)).programs
        print("Prozesse: \(report.processes.count), mit Programm: \(programs.count), gesamt ↓ \(TrafficFormat.rate(report.total.download)) ↑ \(TrafficFormat.rate(report.total.upload))")
        #expect(programs.count > report.processes.count / 2)
    }

    /// Gegenprobe gegen das System (Bewertung 2026.11.7-1188, Mangel 2): Grantrys Raten über sechs Messungen – Sampler,
    /// Tracker und Schnittstellendeckel wie in `ActivityPipeline` – gegen die Byte-Zähler aller Schnittstellen
    /// (`netstat -ib`, samt lo0, denn nettop zählt auch Loopback-Sockets) und gegen `nettop -d` im selben Zeitraum.
    /// Druckt die Werte; vor der Korrektur der Messzeitpunkte lagen Grantrys Raten um Faktor 100–2000 darüber.
    @Test func ratesMatchInterfaceCountersAndNettopDeltas() async throws {
        let steps = 6
        let interfacesBefore = try Self.netstatBytes()
        let started = ContinuousClock.now
        async let reference = Self.nettopDeltas(samples: steps + 1)

        var tracker = TrafficTracker()
        if let reading = InterfaceByteReading.current() { tracker.record(reading) }
        let sampler = NettopSampler()
        let (samples, continuation) = AsyncStream.makeStream(of: TimedNettopSample.self)
        let task = Task { try await sampler.run { continuation.yield($0) } }
        var reports: [TrafficReport] = []
        var window: (first: ContinuousClock.Instant, last: ContinuousClock.Instant)?
        for await sample in samples {
            if let reading = InterfaceByteReading.current() { tracker.record(reading) }
            let report = tracker.update(with: sample.sample, at: sample.capturedAt)
            window = (window?.first ?? sample.capturedAt, sample.capturedAt)
            if !report.history.isEmpty { reports.append(report) }
            if reports.count == steps { break }
        }
        task.cancel()
        let interfacesAfter = try Self.netstatBytes()
        let netstatSeconds = (ContinuousClock.now - started).seconds
        let nettopDelta = try await reference
        let measured = try #require(window)

        let grantryRates = reports.map(\.total.total)
        let grantryMean = grantryRates.reduce(0, +) / Double(grantryRates.count)
        let transferred = try #require(reports.last).processes.reduce(UInt64(0)) { $0 + $1.transferred.total }
        let grantryBytesRate = Double(transferred) / (measured.last - measured.first).seconds
        let netstatRate = Double(interfacesAfter.all - interfacesBefore.all) / netstatSeconds
        let netstatExternalRate = Double(interfacesAfter.withoutLoopback - interfacesBefore.withoutLoopback) / netstatSeconds
        let nettopRate = Double(nettopDelta.values.reduce(0, +)) / Double(steps * sampler.interval)
        let grantryByProcess = Dictionary(try #require(reports.last).processes.map {
            ("\($0.shortName).\($0.key.pid)", Double($0.transferred.total) / (measured.last - measured.first).seconds)
        }, uniquingKeysWith: +)
        print("Gegenprobe Netzraten über \(steps) Messungen à \(sampler.interval) s (B/s):")
        print("  Grantry Gesamtrate je Messung: \(grantryRates.map { Int($0) })")
        print("  Grantry Mittel \(Int(grantryMean)), aus übertragenen Bytes \(Int(grantryBytesRate))")
        print("  nettop -d Summe \(Int(nettopRate))")
        print("  netstat -ib alle Schnittstellen \(Int(netstatRate)), ohne lo0 \(Int(netstatExternalRate))")
        for (name, bytes) in nettopDelta.sorted(by: { $0.value > $1.value }).prefix(5) {
            let rate = Double(bytes) / Double(steps * sampler.interval)
            print("  \(name): nettop -d \(Int(rate)), Grantry \(Int(grantryByProcess[name] ?? 0))")
        }

        // Spielraum: Die ersten Messungen glätten über weniger Schritte, die Fenster der drei Quellen liegen leicht
        // versetzt. Ein Fehler in Größenordnungen wie vor der Korrektur fällt trotzdem auf.
        #expect(grantryMean <= 2 * netstatRate + 20_000)
        #expect(grantryMean <= 2 * nettopRate + 20_000)
        #expect(grantryBytesRate <= netstatRate * netstatSeconds / (measured.last - measured.first).seconds)
    }

    /// Empfangen + Senden aller Schnittstellen laut `netstat -ib`, samt und ohne lo0.
    private static func netstatBytes() throws -> (all: UInt64, withoutLoopback: UInt64) {
        let output = try Self.output(of: "/usr/sbin/netstat", ["-ib"])
        var all: UInt64 = 0
        var loopback: UInt64 = 0
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ")
            guard fields.count >= 10, fields[2].hasPrefix("<Link#"),
                  let received = UInt64(fields[fields.count - 5]), let sent = UInt64(fields[fields.count - 2])
            else { continue }
            all += received + sent
            if fields[0] == "lo0" { loopback += received + sent }
        }
        return (all, all - loopback)
    }

    /// Bytes je Prozess (`Name.PID`) laut `nettop -d` über `samples - 1` Intervalle: Die erste Messung ist der Stand
    /// seit Prozessbeginn, die weiteren sind Zuwächse.
    private static func nettopDeltas(samples: Int) async throws -> [String: UInt64] {
        let output = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try Self.output(of: NettopSampler.executable,
                                    ["-L", String(samples), "-d", "-s", "2", "-n", "-x", "-P", "-J", "bytes_in,bytes_out"])
                })
            }
        }
        var deltas: [String: UInt64] = [:]
        var block = 0
        for line in output.split(separator: "\n") {
            if line == ",bytes_in,bytes_out," {
                block += 1
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard block > 1, fields.count >= 4, let received = UInt64(fields[fields.count - 3]),
                  let sent = UInt64(fields[fields.count - 2]) else { continue }
            deltas[fields.dropLast(3).joined(separator: ","), default: 0] += received + sent
        }
        return deltas
    }

    /// Standardausgabe eines Programms; die Standardeingabe bleibt eine offene Pipe (nettop dreht sonst bei EOF).
    private static func output(of executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? input.fileHandleForWriting.close()
        return String(decoding: data, as: UTF8.self)
    }

    /// Direkte Kindprozesse dieses Testprozesses, die `/usr/bin/nettop` ausführen.
    private static func nettopChildren() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 512)
        _ = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.filter { $0 > 0 && LibprocProcessInspector.executablePath(of: $0) == NettopSampler.executable }
    }
}
