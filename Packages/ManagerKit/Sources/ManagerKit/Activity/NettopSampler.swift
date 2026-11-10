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
/// - Aufruf `nettop -L 0 -s <interval> -n -x -J interface,state,bytes_in,bytes_out -c`.
/// - Ein Block ist vollständig, sobald die Kopfzeile des nächsten kommt; den letzten, womöglich unvollständigen Block
///   beim Prozessende verwirft der Sampler.
/// - `TimedNettopSample.capturedAt` stammt aus nettops Takt (`NettopSchedule`), nicht aus dem Eingang der Kopfzeile:
///   In die Pipe schreibt nettop gepuffert in Stücken von 16 KiB, zwei Kopfzeilen kommen oft im selben Stück an
///   (Mitschnitt in den Tests, `NettopBufferedOutputTests`). Ihr Abstand wäre dann Mikrosekunden statt eines Intervalls.
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
    /// Sekunden zwischen zwei Messungen (`-s`).
    public let interval: Int
    private let identity: @Sendable (Int32) -> NettopProcessIdentity?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - interval: Sekunden zwischen zwei Messungen (`-s`).
    ///   - identity: Startzeit (µs seit 1970) und Benutzer eines Prozesses (`ProcessTraffic.startTime`, `.uid`); `nil`,
    ///     wenn nicht lesbar.
    ///   - now, sleep: Uhr und Wartezeit, in Tests ersetzbar.
    public init(
        streamer: any LineStreaming = ProcessLineStreamer(),
        interval: Int = 2,
        identity: @escaping @Sendable (Int32) -> NettopProcessIdentity? = NettopSampler.libprocIdentity,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        precondition(interval > 0, "nettop-Intervall muss positiv sein")
        self.streamer = streamer
        self.interval = interval
        self.identity = identity
        self.now = now
        self.sleep = sleep
    }

    /// Nur mit Startzeit, ohne Benutzer (Tests).
    public init(
        streamer: any LineStreaming = ProcessLineStreamer(),
        interval: Int = 2,
        startTime: @escaping @Sendable (Int32) -> UInt64?,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(streamer: streamer, interval: interval,
                  identity: { pid in startTime(pid).map { NettopProcessIdentity(startTime: $0) } }, now: now, sleep: sleep)
    }

    /// Startzeit und Benutzer laut **einer** Abfrage der Prozesstabelle (`LibprocProcessInspector.identity(of:)`).
    public static func libprocIdentity(_ pid: Int32) -> NettopProcessIdentity? {
        LibprocProcessInspector().identity(of: pid).map { NettopProcessIdentity(startTime: $0.startTime, uid: $0.uid) }
    }

    public var arguments: [String] {
        // -c reduziert nettops Zeichenaufwand; CSV-Takt (-s) und die identitätsrelevante Interface-Spalte bleiben erhalten.
        ["-L", "0", "-s", String(interval), "-n", "-x", "-J", "interface,state,bytes_in,bytes_out", "-c"]
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
            let schedule = NettopSchedule(start: now(), interval: .seconds(interval))
            let assembler = NettopSampleAssembler(identity: identity, schedule: schedule)
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

/// Messzeitpunkte eines nettop-Laufs: nettop misst ab seinem Start im festen Takt (`-s`, auf macOS 27.2 auf wenige
/// Millisekunden genau), Messung `n` also zur Zeit `start + n × interval`. Früher als beim Eingang ihrer Kopfzeile kann
/// sie nicht gemessen sein; das begrenzt den Zeitpunkt, falls nettop schneller liefern sollte.
struct NettopSchedule: Sendable {
    /// Unmittelbar vor dem Start von nettop.
    let start: ContinuousClock.Instant
    let interval: Duration

    func instant(ofSample index: Int, headerArrivedAt arrival: ContinuousClock.Instant) -> ContinuousClock.Instant {
        min(start + interval * index, arrival)
    }
}

/// Startzeit und Benutzer eines Prozesses, gelesen beim Eingang seiner nettop-Zeile.
public struct NettopProcessIdentity: Hashable, Sendable {
    /// µs seit 1970.
    public let startTime: UInt64
    /// `nil`, wenn nicht gelesen (Tests).
    public let uid: UInt32?

    public init(startTime: UInt64, uid: UInt32? = nil) {
        self.startTime = startTime
        self.uid = uid
    }
}

/// Ein Block der nettop-Ausgabe mit dem Eingang seiner ersten Zeile und den beim Eingang der Prozesszeilen gelesenen
/// Startzeiten und Benutzern (nach PID).
struct NettopBlock: Hashable, Sendable {
    let text: String
    let startedAt: ContinuousClock.Instant
    var identities: [Int32: NettopProcessIdentity] = [:]
}

/// Schneidet nettops Zeilen ausschließlich an der exakten `NettopParser.header` in Blöcke. Zeilen vor der ersten
/// Kopfzeile bilden einen eigenen Block, den der Parser als unbekanntes Format ablehnt. Ein Block über `maximumLines`
/// wird ohne Kopfzeile abgegeben, damit eine fremde Ausgabe den Speicher nicht füllt.
struct NettopBlockSplitter {
    static let maximumLines = 20_000

    private var lines: [String] = []
    private var startedAt: ContinuousClock.Instant?
    private var identities: [Int32: NettopProcessIdentity] = [:]

    /// Nimmt eine Zeile auf – bei einer Prozesszeile mit Startzeit und Benutzer ihres Prozesses (`process`); liefert den
    /// vorigen Block, sobald eine Kopfzeile den nächsten beginnt.
    mutating func append(_ line: String, at instant: ContinuousClock.Instant,
                         process: (pid: Int32, identity: NettopProcessIdentity)? = nil) -> NettopBlock? {
        guard !line.isEmpty else { return nil }
        if line == NettopParser.header {
            let finished = flush()
            lines = [line]
            startedAt = instant
            return finished
        }
        if startedAt == nil { startedAt = instant }
        lines.append(line)
        if let process { identities[process.pid] = process.identity }
        return lines.count > Self.maximumLines ? flush() : nil
    }

    private mutating func flush() -> NettopBlock? {
        defer {
            lines = []
            startedAt = nil
            identities = [:]
        }
        guard let startedAt, !lines.isEmpty else { return nil }
        return NettopBlock(text: lines.joined(separator: "\n"), startedAt: startedAt, identities: identities)
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
/// Startzeit und Benutzer eines Prozesses werden beim Eingang seiner Zeile gelesen: Ein Block ist erst mit der nächsten Kopfzeile
/// fertig, ein Intervall später – endet der Prozess dazwischen, wäre sie dann nicht mehr lesbar.
final class NettopSampleAssembler: Sendable {
    private struct State {
        var splitter = NettopBlockSplitter()
        /// Gelieferte Messungen – zugleich die Nummer des nächsten Blocks, denn ein unlesbarer Block beendet den Lauf.
        var samples = 0
        var firstLineAt: ContinuousClock.Instant?
        var lastLineAt: ContinuousClock.Instant?
    }

    private let identity: @Sendable (Int32) -> NettopProcessIdentity?
    private let schedule: NettopSchedule
    private let state = Mutex(State())

    init(identity: @escaping @Sendable (Int32) -> NettopProcessIdentity?, schedule: NettopSchedule) {
        self.identity = identity
        self.schedule = schedule
    }

    /// Nur mit Startzeit, ohne Benutzer, Takt ab jetzt (Tests).
    convenience init(startTime: @escaping @Sendable (Int32) -> UInt64?) {
        self.init(identity: { pid in startTime(pid).map { NettopProcessIdentity(startTime: $0) } },
                  schedule: NettopSchedule(start: .now, interval: .seconds(2)))
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
            identity(pid).map { (pid: pid, identity: $0) }
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
        let sample = try NettopParser.parse(block: block.text).identifying(with: block.identities)
        let index = state.withLock { state in
            defer { state.samples += 1 }
            return state.samples
        }
        return TimedNettopSample(sample: sample,
                                 capturedAt: schedule.instant(ofSample: index, headerArrivedAt: block.startedAt))
    }
}
