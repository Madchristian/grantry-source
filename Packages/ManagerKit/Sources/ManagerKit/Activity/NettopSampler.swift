import Foundation
import Synchronization

/// Fehlerzustände von `NettopSampler.run(onSample:)`.
public enum NettopSamplerError: Error, Equatable, Sendable {
    /// nettop ließ sich nicht starten (fehlt, keine Ausführungsrechte) – ein Neustart hilft nicht.
    case launchFailed(reason: String)
    /// Kopfzeile unbekannt (`NettopParser.Error.unrecognizedFormat`); ein Neustart hilft nicht.
    case unrecognizedFormat
    /// nettop endete `count`-mal in Folge ohne Messung oder ohne stabil zu laufen.
    case endedRepeatedly(count: Int)
}

/// Startet `nettop` als langlebigen Unterprozess und liefert jede Messung (Spec §2/§3).
///
/// - Aufruf `nettop -L 0 -s <interval> -n -x -J state,bytes_in,bytes_out`.
/// - Ein Block ist vollständig, sobald die Kopfzeile des nächsten kommt – er erscheint also eine Intervalllänge nach
///   seinem Beginn; `TimedNettopSample.capturedAt` ist der Zeitpunkt seiner Kopfzeile. Den letzten, womöglich
///   unvollständigen Block beim Prozessende verwirft der Sampler.
/// - Endet nettop, startet der Sampler ihn nach 1 s, 2 s, 4 s … (höchstens 30 s) neu. Nur ein stabiler Lauf
///   (mindestens `stableRunDuration` oder `stableRunSamples` Messungen) setzt den Backoff auf die erste Stufe zurück;
///   sonst wächst er mit jedem Neustart.
/// - `run` endet mit `endedRepeatedly` beim dritten Lauf ohne Messung in Folge (nettop defekt – schnell melden) oder
///   beim siebten instabilen Lauf in Folge (liefert zwar kurz, endet aber immer wieder; jede Backoff-Stufe bis 30 s
///   wird dabei einmal durchlaufen). Start- und Formatfehler beenden `run` sofort.
/// - Abbruch des Aufrufers beendet nettop (`LineStreaming`) und wirft `CancellationError`.
public struct NettopSampler: Sendable {
    public static let executable = "/usr/bin/nettop"
    /// Läufe ohne Messung in Folge bis zum Fehlerzustand.
    public static let maximumConsecutiveFailures = 3
    /// Instabile Läufe in Folge bis zum Fehlerzustand: 1 + Anzahl der Backoff-Stufen (1, 2, 4, 8, 16, 30 s).
    public static let maximumConsecutiveRestarts = 7
    public static let maximumBackoff: Duration = .seconds(30)
    /// Ein Lauf gilt als stabil, wenn er so lange lief …
    static let stableRunDuration: Duration = .seconds(30)
    /// … oder so viele Messungen lieferte.
    static let stableRunSamples = 5

    private let streamer: any LineStreaming
    private let interval: Int
    private let startTime: @Sendable (Int32) -> UInt64?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - interval: Sekunden zwischen zwei Messungen (`-s`).
    ///   - startTime: Startzeit eines Prozesses in µs seit 1970 (`ProcessTraffic.startTime`); `nil`, wenn nicht lesbar.
    ///   - now, sleep: Uhr und Wartezeit, in Tests ersetzbar.
    public init(
        streamer: any LineStreaming = ProcessLineStreamer(),
        interval: Int = 2,
        startTime: @escaping @Sendable (Int32) -> UInt64? = NettopSampler.libprocStartTime,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        precondition(interval > 0, "nettop-Intervall muss positiv sein")
        self.streamer = streamer
        self.interval = interval
        self.startTime = startTime
        self.now = now
        self.sleep = sleep
    }

    /// Startzeit laut Prozesstabelle (`LibprocProcessInspector.liveness(of:)`), µs seit 1970.
    public static func libprocStartTime(_ pid: Int32) -> UInt64? {
        guard case .running(let startTime) = LibprocProcessInspector().liveness(of: pid) else { return nil }
        return startTime
    }

    public var arguments: [String] {
        ["-L", "0", "-s", String(interval), "-n", "-x", "-J", "state,bytes_in,bytes_out"]
    }

    /// Wartezeit vor dem Neustart nach `restarts` instabilen Läufen in Folge: 1 s, 2 s, 4 s …, höchstens 30 s.
    static func backoff(afterRestarts restarts: Int) -> Duration {
        min(.seconds(1 << min(max(restarts - 1, 0), 5)), maximumBackoff)
    }

    /// Läuft, bis der Task abgebrochen wird (`CancellationError`) oder ein Fehlerzustand eintritt
    /// (`NettopSamplerError`); kehrt nie normal zurück.
    public func run(onSample: @Sendable (TimedNettopSample) -> Void) async throws {
        var emptyRuns = 0
        var restarts = 0
        while true {
            let assembler = NettopSampleAssembler(startTime: startTime)
            do {
                _ = try await streamer.run(Self.executable, arguments) { line in
                    if let sample = try assembler.consume(line, at: now()) { onSample(sample) }
                }
            } catch CommandError.launchFailed(_, let reason) {
                throw NettopSamplerError.launchFailed(reason: reason)
            } catch is NettopParser.Error {
                throw NettopSamplerError.unrecognizedFormat
            }
            try Task.checkCancellation()
            let summary = assembler.summary
            emptyRuns = summary.samples == 0 ? emptyRuns + 1 : 0
            restarts = summary.isStable ? 1 : restarts + 1
            if emptyRuns >= Self.maximumConsecutiveFailures {
                throw NettopSamplerError.endedRepeatedly(count: emptyRuns)
            }
            if restarts >= Self.maximumConsecutiveRestarts {
                throw NettopSamplerError.endedRepeatedly(count: restarts)
            }
            try await sleep(Self.backoff(afterRestarts: restarts))
        }
    }
}

/// Ein Block der nettop-Ausgabe mit dem Zeitpunkt seiner ersten Zeile und den beim Eingang der Prozesszeilen gelesenen
/// Startzeiten (nach PID).
struct NettopBlock: Hashable, Sendable {
    let text: String
    let startedAt: ContinuousClock.Instant
    var startTimes: [Int32: UInt64] = [:]
}

/// Schneidet nettops Zeilen ausschließlich an der exakten `NettopParser.header` in Blöcke. Zeilen vor der ersten
/// Kopfzeile bilden einen eigenen Block, den der Parser als unbekanntes Format ablehnt. Ein Block über `maximumLines`
/// wird ohne Kopfzeile abgegeben, damit eine fremde Ausgabe den Speicher nicht füllt.
struct NettopBlockSplitter {
    static let maximumLines = 20_000

    private var lines: [String] = []
    private var startedAt: ContinuousClock.Instant?
    private var startTimes: [Int32: UInt64] = [:]

    /// Nimmt eine Zeile auf – bei einer Prozesszeile mit der Startzeit ihres Prozesses (`process`); liefert den vorigen
    /// Block, sobald eine Kopfzeile den nächsten beginnt.
    mutating func append(_ line: String, at instant: ContinuousClock.Instant,
                         process: (pid: Int32, startTime: UInt64)? = nil) -> NettopBlock? {
        guard !line.isEmpty else { return nil }
        if line == NettopParser.header {
            let finished = flush()
            lines = [line]
            startedAt = instant
            return finished
        }
        if startedAt == nil { startedAt = instant }
        lines.append(line)
        if let process { startTimes[process.pid] = process.startTime }
        return lines.count > Self.maximumLines ? flush() : nil
    }

    private mutating func flush() -> NettopBlock? {
        defer {
            lines = []
            startedAt = nil
            startTimes = [:]
        }
        guard let startedAt, !lines.isEmpty else { return nil }
        return NettopBlock(text: lines.joined(separator: "\n"), startedAt: startedAt, startTimes: startTimes)
    }
}

/// Was ein beendeter nettop-Lauf geliefert hat.
struct NettopRunSummary: Equatable, Sendable {
    /// Gelieferte Messungen.
    var samples = 0
    /// Abstand zwischen erster und letzter Zeile.
    var duration: Duration = .zero

    var isStable: Bool {
        samples >= NettopSampler.stableRunSamples || duration >= NettopSampler.stableRunDuration
    }
}

/// Zerlegt und parst die Zeilen eines nettop-Laufs; merkt sich, was er geliefert hat.
///
/// Die Startzeit eines Prozesses wird beim Eingang seiner Zeile gelesen: Ein Block ist erst mit der nächsten Kopfzeile
/// fertig, ein Intervall später – endet der Prozess dazwischen, wäre sie dann nicht mehr lesbar.
final class NettopSampleAssembler: Sendable {
    private struct State {
        var splitter = NettopBlockSplitter()
        var samples = 0
        var firstLineAt: ContinuousClock.Instant?
        var lastLineAt: ContinuousClock.Instant?
    }

    private let startTime: @Sendable (Int32) -> UInt64?
    private let state = Mutex(State())

    init(startTime: @escaping @Sendable (Int32) -> UInt64?) {
        self.startTime = startTime
    }

    var summary: NettopRunSummary {
        state.withLock { state in
            guard let first = state.firstLineAt, let last = state.lastLineAt else { return NettopRunSummary() }
            return NettopRunSummary(samples: state.samples, duration: last - first)
        }
    }

    /// Die fertige Messung, sobald `line` einen Block abschließt; wirft `NettopParser.Error` bei unbekanntem Format.
    func consume(_ line: String, at instant: ContinuousClock.Instant) throws -> TimedNettopSample? {
        guard !line.isEmpty else { return nil }
        let process = NettopParser.processID(ofLine: line[...]).flatMap { pid in
            startTime(pid).map { (pid: pid, startTime: $0) }
        }
        let block = try state.withLock { state in
            if state.firstLineAt == nil {
                // Ein unbekanntes Format sofort ablehnen, auch wenn nie eine gültige Kopfzeile folgt.
                guard line == NettopParser.header else { throw NettopParser.Error.unrecognizedFormat }
                state.firstLineAt = instant
            }
            state.lastLineAt = instant
            return state.splitter.append(line, at: instant, process: process)
        }
        guard let block else { return nil }
        let sample = try NettopParser.parse(block: block.text).identifying(with: block.startTimes)
        state.withLock { $0.samples += 1 }
        return TimedNettopSample(sample: sample, capturedAt: block.startedAt)
    }
}
