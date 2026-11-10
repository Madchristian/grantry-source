import Foundation

/// Ordnergrößen ab einer Wurzel für die Belegung (TM-15.2, #401; Spec 2026-11-08 § 5.4): allozierte Größe, Hardlinks
/// einmal, keine Symlinks, keine Volumegrenzen, Netzlaufwerke ausgelassen, nicht lesbare Ordner als nicht erfassbar mit
/// der Summe des Lesbaren. Je Ordner nur Summen und die größten Dateien. Nur lesend; das Ergebnis lebt nur im Speicher
/// (`OccupancyStore`).
///
/// Leistung (Spec § 4.4): höchstens zwei Leser-Threads mit QoS utility und gedrosselter E/A (`IOPOL_THROTTLE`),
/// abbrechbar über den Task, Fortschritt einmal je Sekunde (die Spec erlaubt viermal; jede Meldung zeichnet die Ansicht
/// neu, in der Abnahme 2026.11.10-1547 kostete das mit Bedienungshilfen rund 8 % eines Kerns, #530). Ein erneuter Scan
/// derselben Wurzel überspringt
/// unveränderte Ordner: Was sich seit dem letzten Scan geändert hat, meldet der FSEvents-Verlauf – auch gewachsene
/// Dateien, deren Ordner sein Änderungsdatum behält; das Änderungsdatum der Unterordner jedes neu gelesenen Ordners
/// sichert zusätzlich ab. Kann der Verlauf nichts Sicheres sagen, wird alles neu gelesen.
public struct OccupancyScanner: Sendable {
    public static let maximumReaders = 2
    public static let largestFileCount = 20
    public static let progressInterval: Duration = .seconds(1)

    /// Auflösen der Wurzel (wenige `lstat` und `open`) außerhalb des kooperativen Pools.
    private static let preparation = BlockingWorkQueue(label: "occupancy")

    private let fileSystem: any OccupancyFileSystem
    private let journal: any OccupancyChangeJournal
    /// Startet eine Stoppuhr für den Fortschritt (Uhr injiziert, in Tests ohne Wanduhr).
    private let startStopwatch: @Sendable () -> @Sendable () -> Duration
    private var excluded: Set<String>

    /// - Parameter excluded: Ordner (kanonische Pfade), die der Scan nicht betritt – etwa geschützte Orte ohne
    ///   Festplattenvollzugriff; sie gelten als nicht erfassbar.
    public init(excluding excluded: Set<String> = []) {
        self.init(fileSystem: LocalOccupancyFileSystem(), journal: FSEventsOccupancyJournal(), excluded: excluded)
    }

    init(
        fileSystem: any OccupancyFileSystem, journal: any OccupancyChangeJournal, clock: some Clock<Duration> = ContinuousClock(),
        excluded: Set<String> = []
    ) {
        self.fileSystem = fileSystem
        self.journal = journal
        startStopwatch = { OccupancyProgressReporter.stopwatch(clock) }
        self.excluded = excluded
    }

    /// Derselbe Scanner mit anderen Ausnahmen.
    public func excluding(_ excluded: Set<String>) -> OccupancyScanner {
        var scanner = self
        scanner.excluded = excluded
        return scanner
    }

    /// Scannt `path` (Standard der Ansicht: der Benutzerordner). Mit `previous` derselben Wurzel werden unveränderte
    /// Ordner übernommen. `progress` läuft auf einem Leser-Thread.
    /// - Throws: `OccupancyScanError` (Netzlaufwerk, Wurzel fehlt), `CancellationError` nach dem Abbruch des Tasks.
    public func scan(
        _ path: String, reusing previous: OccupancyTree? = nil,
        progress: @escaping @Sendable (OccupancyProgress) -> Void = { _ in }
    ) async throws -> OccupancyTree {
        try Task.checkCancellation()
        let fileSystem = fileSystem
        let root = try await Self.preparation.runThrowing { try fileSystem.root(at: path) }
        try Task.checkCancellation()
        let device = root.identity.device
        // Vor der Abfrage der Änderungen: Was währenddessen geschieht, meldet der nächste Scan.
        let mark = journal.mark(forDevice: device)
        var reusable: (record: OccupancyRecord, plan: OccupancyRescanPlan)?
        if let previous, previous.rootPath == root.path, previous.rootRecord.identity == root.identity,
           let previousMark = previous.mark,
           let changes = await journal.changes(since: previousMark, under: root.path, device: device) {
            reusable = (previous.rootRecord, OccupancyRescanPlan(changes))
        }
        try Task.checkCancellation()
        let elapsed = startStopwatch()
        let walk = OccupancyWalk(
            OccupancyWalk.Configuration(
                fileSystem: fileSystem, root: root, previous: reusable?.record, plan: reusable?.plan, mark: mark,
                excluded: excluded, largestFileCount: Self.largestFileCount
            ),
            progress: OccupancyProgressReporter(interval: Self.progressInterval, elapsed: elapsed, report: progress)
        )
        return try await walk.run(readers: Self.maximumReaders)
    }
}
