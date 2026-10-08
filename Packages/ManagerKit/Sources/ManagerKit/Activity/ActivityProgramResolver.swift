import Foundation
import Synchronization

/// Ordnet Prozessen der Netzwerkaktivität ihr Programm zu: Pfad über `proc_pidpath`, Signatur über denselben
/// `SigningInspecting` wie die Lauscher (`CachingSigningInspector`), Einstufung über `NetworkProgram`. Ein nicht
/// auflösbarer Pfad (beendet, `kernel_task`) bleibt `nil` – die Anzeige nimmt dann nettops Kurznamen.
///
/// **Nie blockierend:** `programs(for:ended:)` liest nur Pfad und `FileFingerprint` (Systemaufrufe ohne Wartezeit) und
/// bekannte Signaturen. Neue Pfade prüft eine eigene serielle `DispatchQueue` nacheinander – die Prüfung kann über
/// `BlockingCallGuard` bis zu ihrer Frist warten und darf weder den kooperativen Pool noch das Lesen von nettop
/// aufhalten. Bis dahin trägt das Programm `SigningInfo.unknown` und steht in `ResolvedPrograms.pendingSignatures`; die
/// nächste Messung bringt die fertige Signatur. Endet eine Prüfung mit Zeitüberschreitung, wird ihr Pfad
/// `inspectionRetryDelay` lang nicht erneut eingereiht – sonst belastete er alle 2 s den mit Snapshot-Scans und
/// Lauschern geteilten `BlockingCallGuard.signing`; seine Prozesse tragen so lange `SigningInfo.unknown` und warten
/// nicht. `cancelPendingInspections()` verwirft noch nicht begonnene Prüfungen
/// (Ansicht geschlossen).
///
/// **Signatur je Prozess:** Ein Prozess behält die Signatur, die er einmal bekommen hat. Ein neuer Prozess übernimmt
/// eine gespeicherte Signatur seines Pfads nur, wenn der Fingerabdruck der Datei bei seinem Auftauchen noch zu dem der
/// Prüfung passt – sonst (Update am selben Pfad, während der alte Prozess noch ausgegraut oder parallel läuft) wird neu
/// geprüft. Ein Prozess, der beim Start einer Prüfung seines Pfads wartete und dessen Fingerabdruck nicht zum geprüften
/// passt (Datei zwischendurch geändert, Fingerabdruck erst später lesbar), bekommt `SigningInfo.unknown` – er wartet
/// nicht endlos.
///
/// **Programmwechsel (`exec`):** Der Pfad laufender Prozesse wird je Messung neu gelesen. Wechselt er bei gleichem
/// `ProcessKey`, gelten neue Zuordnung und neuer Fingerabdruck, die Signatur wird neu ermittelt. Ein beendeter Prozess
/// (Pfad nicht mehr lesbar oder ausgegraut) behält sein letztes Programm.
///
/// **Grenze pfadbasierter Prüfung:** Der Fingerabdruck stammt vom Zeitpunkt, an dem der Prozess zuerst gemeldet wurde,
/// nicht vom Prozessstart. Wird das Bundle eines laufenden Prozesses ersetzt, bevor er hier auftaucht, zeigt er die
/// Signatur der Datei auf der Platte, nicht die des geladenen Codes.
public final class ActivityProgramResolver: Sendable {
    /// Programme einer Messung; `pendingSignatures`: Prozesse, deren Signatur noch geprüft wird.
    public struct ResolvedPrograms: Hashable, Sendable {
        public let programs: [ProcessKey: NetworkProgram]
        public let pendingSignatures: Set<ProcessKey>
    }

    /// Ein gemeldeter Prozess: Pfad (`nil`: nicht auflösbar), Fingerabdruck beim Auftauchen und – sobald zugeordnet –
    /// seine Signatur.
    private struct Process {
        let path: String?
        let fingerprint: FileFingerprint?
        var signing: SigningInfo?
    }

    /// So lange wird ein Pfad nach einer Zeitüberschreitung seiner Prüfung nicht erneut eingereiht.
    public static let inspectionRetryDelay: Duration = .seconds(60)

    private struct State {
        var processes: [ProcessKey: Process] = [:]
        /// Geprüfte Signatur je Pfad samt Fingerabdruck zur Prüfung; nur für Pfade gemeldeter Prozesse, damit das
        /// Wörterbuch nicht wächst.
        var signatures = FingerprintCache<SigningInfo>()
        var queued: [String] = []
        /// Pfade, deren Prüfung die Frist überschritt, bis zum Zeitpunkt der nächsten Prüfung.
        var retryAfter: [String: ContinuousClock.Instant] = [:]
        /// Pfad der laufenden Prüfung – er wird währenddessen nicht erneut eingereiht.
        var inspecting: String?
        var isDraining = false
    }

    private let executablePath: @Sendable (Int32) -> String?
    private let fingerprint: @Sendable (String) -> FileFingerprint?
    private let inspector: any SigningInspecting
    private let now: @Sendable () -> ContinuousClock.Instant
    private let queue: DispatchQueue
    private let state = Mutex(State())

    /// - Parameters:
    ///   - fingerprint: Fingerabdruck der Programmdatei (Symlinks aufgelöst), `nil`, wenn nicht lesbar.
    ///   - now: Uhr für `inspectionRetryDelay`, in Tests ersetzbar.
    public init(
        executablePath: @escaping @Sendable (Int32) -> String? = { LibprocProcessInspector.executablePath(of: $0) },
        fingerprint: @escaping @Sendable (String) -> FileFingerprint? = ActivityProgramResolver.fingerprint(ofProgramAt:),
        inspector: any SigningInspecting = CachingSigningInspector(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.executablePath = executablePath
        self.fingerprint = fingerprint
        self.inspector = inspector
        self.now = now
        queue = DispatchQueue(label: "\(ManagerKit.logSubsystem).activity-signing", qos: .utility)
    }

    /// Fingerabdruck des Programms an `path` mit aufgelösten Symlinks – wie in `CachingSigningInspector`.
    public static func fingerprint(ofProgramAt path: String) -> FileFingerprint? {
        FileFingerprint(of: FileFingerprint.target(of: path))
    }

    /// Programme zu `keys`; Prozesse ohne auflösbaren Pfad fehlen. Neue Pfade werden zur Prüfung eingereiht; Prozesse
    /// und Signaturen nicht mehr gemeldeter Pfade entfallen. Für `ended` (ausgegraute Prozesse) wird der Pfad nicht neu
    /// gelesen – ihre PID kann schon einem anderen Prozess gehören.
    public func programs(for keys: [ProcessKey], ended: Set<ProcessKey> = []) -> ResolvedPrograms {
        let known = state.withLock { $0.processes }
        var processes: [ProcessKey: Process] = [:]
        for key in keys {
            processes[key] = ended.contains(key) ? known[key] ?? discover(key) : current(key, known: known[key])
        }
        let now = now()
        let (resolved, startsDraining) = state.withLock { state -> (ResolvedPrograms, Bool) in
            let paths = Set(processes.values.compactMap(\.path))
            state.signatures.retainValues(for: paths)
            state.retryAfter = state.retryAfter.filter { paths.contains($0.key) && $0.value > now }
            var programs: [ProcessKey: NetworkProgram] = [:]
            var pending: Set<ProcessKey> = []
            for key in keys {
                guard var process = processes[key], let path = process.path else { continue }
                if process.signing == nil, let fingerprint = process.fingerprint {
                    process.signing = state.signatures.value(for: path, matching: fingerprint)
                    processes[key] = process
                }
                programs[key] = NetworkProgram(executablePath: path, signing: process.signing ?? .unknown)
                if process.signing == nil, state.retryAfter[path] == nil {
                    pending.insert(key)
                    if state.inspecting != path, !state.queued.contains(path) { state.queued.append(path) }
                }
            }
            state.processes = processes
            let startsDraining = !state.isDraining && !state.queued.isEmpty
            if startsDraining { state.isDraining = true }
            return (ResolvedPrograms(programs: programs, pendingSignatures: pending), startsDraining)
        }
        if startsDraining { queue.async { self.drain() } }
        return resolved
    }

    /// Verwirft eingereihte, noch nicht begonnene Prüfungen; eine laufende endet regulär.
    public func cancelPendingInspections() {
        state.withLock { $0.queued.removeAll() }
    }

    /// Wartet suspendierend, bis die Prüfwarteschlange leer ist (Tests).
    func waitForInspections() async {
        while state.withLock({ $0.isDraining }) {
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
    }

    /// Pfad und Fingerabdruck eines neu gemeldeten Prozesses (außerhalb der Sperre).
    private func discover(_ key: ProcessKey) -> Process {
        process(at: key.pid > 0 ? executablePath(key.pid) : nil)
    }

    /// Ein laufender Prozess mit frisch gelesenem Pfad (außerhalb der Sperre): unverändert oder nicht mehr lesbar –
    /// der bekannte Eintrag; gewechselt (`exec`) oder unbekannt – neu ermittelt.
    private func current(_ key: ProcessKey, known: Process?) -> Process {
        guard let known else { return discover(key) }
        guard key.pid > 0, let path = executablePath(key.pid), path != known.path else { return known }
        return process(at: path)
    }

    private func process(at path: String?) -> Process {
        Process(path: path, fingerprint: path.flatMap(fingerprint))
    }

    /// Prüft eingereihte Pfade nacheinander auf `queue`; vor jeder Prüfung wird die Warteschlange neu gelesen, damit
    /// `cancelPendingInspections()` zwischen zwei Prüfungen greift. Der Fingerabdruck wird vor der Prüfung gelesen. Das
    /// Ergebnis gilt für die Prozesse, die beim Start der Prüfung auf diesen Pfad warteten und ihn noch tragen (nach
    /// einem `exec` nicht mehr): bei gleichem Fingerabdruck
    /// (auch beide nicht lesbar) die geprüfte Signatur, sonst `SigningInfo.unknown`. Später aufgetauchte Prozesse warten
    /// auf die nächste Prüfung. Eine Zeitüberschreitung wird als Signatur nicht gemerkt; der Pfad wird erst nach
    /// `inspectionRetryDelay` erneut eingereiht; noch eingereihte Einträge des Pfads entfallen, gesperrte werden beim
    /// Entnehmen übergangen. So belegt ein Pfad höchstens einen Platz in `BlockingCallGuard.signing`.
    private func drain() {
        while let (path, waiting) = nextInspection(at: now()) {
            let inspected = fingerprint(path)
            guard case .completed(let signing) = inspector.inspection(ofPath: path) else {
                let retry = now() + Self.inspectionRetryDelay
                state.withLock { state in
                    state.inspecting = nil
                    state.retryAfter[path] = retry
                    state.queued.removeAll { $0 == path }
                }
                continue
            }
            state.withLock { state in
                state.inspecting = nil
                if let inspected { state.signatures.store(signing, for: path, fingerprint: inspected) }
                for key in waiting {
                    guard let process = state.processes[key], process.path == path, process.signing == nil else {
                        continue
                    }
                    state.processes[key]?.signing = process.fingerprint == inspected ? signing : .unknown
                }
            }
        }
    }

    /// Entnimmt den nächsten nicht gesperrten Pfad samt der Prozesse, die auf ihn warten, und markiert ihn als laufend;
    /// `nil` (und Ende des Abarbeitens), wenn keiner mehr eingereiht ist.
    private func nextInspection(at now: ContinuousClock.Instant) -> (String, Set<ProcessKey>)? {
        state.withLock { state in
            while !state.queued.isEmpty {
                let path = state.queued.removeFirst()
                if let retry = state.retryAfter[path], retry > now { continue }
                state.inspecting = path
                let waiting = state.processes.filter { $0.value.path == path && $0.value.signing == nil }.keys
                return (path, Set(waiting))
            }
            state.isDraining = false
            return nil
        }
    }
}

/// Ein Anzeigestand der Netzwerkaktivität: Raten und Verbindungen samt zugeordneten Programmen.
public struct ActivityFrame: Hashable, Sendable {
    public let report: TrafficReport
    public let programs: [ProcessKey: NetworkProgram]
    /// Prozesse, deren Signatur noch geprüft wird: Ihr Programm trägt vorläufig `SigningInfo.unknown`, die Anzeige
    /// zeigt noch kein Signatur-Label.
    public let pendingSignatures: Set<ProcessKey>
    /// Adressen der Gegenstellen aller angezeigten Verbindungen, auch ausgegrauter – deren Hostnamen bleiben stehen.
    /// Wie `activeRemoteAddresses` einmal beim Erzeugen berechnet, also in `ActivityPipeline` außerhalb des Main
    /// Actors.
    public let remoteAddresses: Set<String>
    /// Adressen der Gegenstellen offener Verbindungen – nur sie werden per Reverse-DNS nachgeschlagen.
    public let activeRemoteAddresses: Set<String>

    public init(report: TrafficReport, programs: [ProcessKey: NetworkProgram], pendingSignatures: Set<ProcessKey> = []) {
        self.report = report
        self.programs = programs
        self.pendingSignatures = pendingSignatures
        let connections = report.processes.flatMap(\.connections)
        remoteAddresses = Set(connections.compactMap(\.connection.remote.address))
        activeRemoteAddresses = Set(connections.filter { !$0.isGone }.compactMap(\.connection.remote.address))
    }

    public static let empty = ActivityFrame(report: .empty, programs: [:])
}

/// Verarbeitet die Messungen eines Laufs nacheinander: `TrafficTracker` und Programmzuordnung. Blockiert nicht –
/// Signaturprüfungen laufen in `ActivityProgramResolver` auf eigener Queue.
final class ActivityPipeline: Sendable {
    private let tracker: Mutex<TrafficTracker>
    private let programs: ActivityProgramResolver

    init(tracker: TrafficTracker, programs: ActivityProgramResolver) {
        self.tracker = Mutex(tracker)
        self.programs = programs
    }

    func frame(for sample: TimedNettopSample) -> ActivityFrame {
        let report = tracker.withLock { $0.update(with: sample.sample, at: sample.capturedAt) }
        let resolved = programs.programs(for: report.processes.map(\.key),
                                         ended: Set(report.processes.filter(\.isGone).map(\.key)))
        return ActivityFrame(report: report, programs: resolved.programs, pendingSignatures: resolved.pendingSignatures)
    }
}
