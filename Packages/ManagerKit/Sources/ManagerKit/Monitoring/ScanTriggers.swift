import Foundation

/// Anlass eines Scans.
public enum ScanReason: Sendable, Equatable, CustomStringConvertible {
    /// Entprellte Dateiänderung in einem beobachteten Pfad; `path` löste die Serie aus (erstes Signal).
    case fileChange(path: String)
    /// Sicherheitsscan nach einer Ruhephase ohne andere Scans.
    case interval
    /// Vom Benutzer angefordert.
    case manual
    /// Erster Scan nach dem Start.
    case launch
    /// Nur die Quellen `sources` neu lesen (eigener Takt, `ScanTriggers.sourceIntervals`).
    case sourceRefresh(Set<SourceID>)

    /// Protokolltext, ausdrücklich statt per Reflexion (unter `-O` nicht verlässlich). Wird öffentlich protokolliert,
    /// daher steht der Benutzerordner als `~` (`description(home:)`).
    public var description: String { description(home: NSHomeDirectory()) }

    /// Protokolltext; ein Pfad in `home` beginnt mit `~` statt mit dem Benutzerordner samt Kontonamen.
    public func description(home: String) -> String {
        switch self {
        case .fileChange(let path): "Dateiänderung (\(PathDisplay.abbreviatingHome(path, home: home)))"
        case .interval: "Intervall"
        case .manual: "manuell"
        case .launch: "Start"
        case .sourceRefresh(let sources): "Quellen (\(sources.map(\.rawValue).sorted().joined(separator: ", ")))"
        }
    }
}

extension ScanReason {
    /// Fasst zwei wartende Auslöser zu einem Scan zusammen: Ein Vollscan schließt jeden Teilscan ein (der jüngere
    /// Vollscan-Grund gilt), Teilscans vereinigen ihre Quellen.
    public func merging(_ newer: ScanReason) -> ScanReason {
        switch (self, newer) {
        case let (.sourceRefresh(old), .sourceRefresh(new)): .sourceRefresh(old.union(new))
        case (_, .sourceRefresh): self
        default: newer
        }
    }

    /// Quellen eines Teilscans; `nil` für einen Vollscan.
    public var refreshedSources: Set<SourceID>? {
        if case .sourceRefresh(let sources) = self { sources } else { nil }
    }
}

/// Erzeugt Scan-Auslöser: entprellte Dateiänderungen, Intervall, manuell.
///
/// - `.launch` kommt als Erstes.
/// - Jedes Dateisignal startet die Entprellfrist neu; erst nach `debounce` Ruhe folgt genau ein `.fileChange` – mit dem
///   Pfad des ersten Signals der Serie.
///   Reißen die Signale nicht ab, kommt `.fileChange` spätestens `maxDelay` nach dem ersten Signal der Serie.
/// - `.interval` folgt, wenn `interval` lang kein anderer Auslöser kam; jeder ausgegebene Auslöser setzt die Frist zurück.
/// - `requestScan()` liefert sofort `.manual`, `requestScan(only:)` sofort `.sourceRefresh` (ohne die Intervallfrist
///   zurückzusetzen).
/// - Je Eintrag in `sourceIntervals` folgt im Takt dieser Quelle `.sourceRefresh([quelle])` – ein Teilscan, der die
///   Intervallfrist nicht zurücksetzt.
///
/// Auslöser während eines laufenden Scans zusammenzufassen ist Aufgabe des Konsumenten.
public actor ScanTriggers {
    private let watcher: any FileSystemWatching
    private let paths: [String]
    private let files: [String]
    private let shallowPaths: [String]
    private let debounce: Duration
    private let maxDelay: Duration
    private let interval: Duration
    private let sourceIntervals: [SourceID: Duration]
    private let clock: any Clock<Duration>

    private var continuation: AsyncStream<ScanReason>.Continuation?
    private var hasConsumer = false
    private var watchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var maxDelayTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?
    private var sourceTasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - paths: beobachtete Verzeichnisse.
    ///   - files: beobachtete Dateien; sie dürfen beim Start fehlen.
    ///   - shallowPaths: flach beobachtete Verzeichnisse (App-Ordner, siehe `FileSystemWatching`).
    ///   - sourceIntervals: eigener Takt je Quelle für Teilscans (`.sourceRefresh`).
    public init(
        watcher: any FileSystemWatching,
        paths: [String],
        files: [String] = [],
        shallowPaths: [String] = [],
        debounce: Duration = .seconds(2),
        maxDelay: Duration = .seconds(10),
        interval: Duration = .seconds(900),
        sourceIntervals: [SourceID: Duration] = [:],
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.watcher = watcher
        self.paths = paths
        self.files = files
        self.shallowPaths = shallowPaths
        self.debounce = debounce
        self.maxDelay = maxDelay
        self.interval = interval
        self.sourceIntervals = sourceIntervals
        self.clock = clock
    }

    /// Strom der Auslöser; genau ein Konsument. Jeder weitere Aufruf liefert einen sofort beendeten Strom.
    /// Beendet der Konsument den Strom, stoppen Überwachung und Zeitgeber.
    public func reasons() -> AsyncStream<ScanReason> {
        let (stream, continuation) = AsyncStream<ScanReason>.makeStream()
        guard !hasConsumer else {
            continuation.finish()
            return stream
        }
        hasConsumer = true
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        emit(.launch)
        sourceTasks = sourceIntervals.map { source, period in
            Task { [clock] in
                while !Task.isCancelled {
                    do { try await clock.sleep(for: period) } catch { return }
                    self.refresh(source)
                }
            }
        }
        watchTask = Task { [watcher, paths, files, shallowPaths] in
            for await path in watcher.changes(in: paths, files: files, shallowPaths: shallowPaths) {
                self.fileChanged(path)
            }
        }
        return stream
    }

    /// Fordert sofort einen Scan an (ohne Entprellung).
    public func requestScan() {
        emit(.manual)
    }

    /// Fordert sofort einen Teilscan der Quellen `sources` an; setzt wie der Quellentakt die Intervallfrist nicht
    /// zurück. Ohne Quellen geschieht nichts.
    public func requestScan(only sources: Set<SourceID>) {
        guard !sources.isEmpty else { return }
        continuation?.yield(.sourceRefresh(sources))
    }

    /// Pfad des ersten Signals der laufenden Serie; `nil` ohne Serie.
    private var burstOrigin: String?

    private func fileChanged(_ path: String) {
        let origin = burstOrigin ?? path
        burstOrigin = origin
        debounceTask?.cancel()
        debounceTask = schedule(.fileChange(path: origin), after: debounce)
        if maxDelayTask == nil {
            maxDelayTask = schedule(.fileChange(path: origin), after: maxDelay)
        }
    }

    /// Teilscan einer Quelle; setzt die Intervallfrist bewusst nicht zurück (der Sicherheitsscan bleibt fällig).
    private func refresh(_ source: SourceID) {
        requestScan(only: [source])
    }

    private func emit(_ reason: ScanReason) {
        guard let continuation else { return }
        continuation.yield(reason)
        if case .fileChange = reason { endFileBurst() }
        intervalTask?.cancel()
        intervalTask = schedule(.interval, after: interval)
    }

    /// Die Serie ist mit dem `.fileChange` abgegolten; das nächste Signal beginnt eine neue.
    private func endFileBurst() {
        debounceTask?.cancel()
        maxDelayTask?.cancel()
        debounceTask = nil
        maxDelayTask = nil
        burstOrigin = nil
    }

    private func schedule(_ reason: ScanReason, after delay: Duration) -> Task<Void, Never> {
        Task { [clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            self.timerFired(reason)
        }
    }

    /// Läuft im Task des Zeitgebers: Wurde er inzwischen abgebrochen (neues Signal, Rücksetzen), verfällt er.
    private func timerFired(_ reason: ScanReason) {
        guard !Task.isCancelled else { return }
        emit(reason)
    }

    private func stop() {
        continuation = nil
        endFileBurst()
        for task in [watchTask, intervalTask].compactMap(\.self) + sourceTasks { task.cancel() }
        watchTask = nil
        intervalTask = nil
        sourceTasks = []
    }
}
