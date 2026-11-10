import Foundation

/// Last eines Prozesses in einem Takt.
public struct ProcessLoad: Hashable, Sendable {
    /// Anteil **eines** Kerns (1 = ein voller Kern); `nil`, wenn nicht gemessen.
    public let coreShare: Double?
    /// Name nach der Regel des Wachbuchs; `nil`, wenn nicht lesbar.
    public let subject: WatchbookSubject?

    public init(coreShare: Double?, subject: WatchbookSubject?) {
        self.coreShare = coreShare
        self.subject = subject
    }
}

/// Die Prozesslast eines Takts als Messpunkt der Regel „Dauerlast je Prozess“.
public struct ProcessLoadSample: Hashable, Sendable {
    public let time: Date
    /// Je Prozess (PID plus Startzeit) seine Last; `nil`, wenn die Prozessliste in diesem Takt nicht gemessen wurde.
    /// Ein fehlender Prozess läuft nicht (mehr) und zählt als ruhig.
    public let processes: [ProcessKey: ProcessLoad]?

    public init(time: Date, processes: [ProcessKey: ProcessLoad]?) {
        self.time = time
        self.processes = processes
    }

    /// Aus einem Takt des Task-Managers: `cpuLoad` ist dort ein Anteil aller Kerne und wird auf einen Kern umgerechnet.
    /// Ohne Prozessliste oder ohne Kernzahl gilt der Takt als nicht gemessen.
    /// - Parameter minimumCoreShare: Nur Prozesse **über** dieser Last behalten (Lagezeile, 15 Minuten im Speicher). Mit
    ///   der Schwelle der Regel ist das für `FindingRules` gleichwertig – ein fehlender Prozess zählt wie einer darunter
    ///   als ruhig –, aber statt Hunderter Einträge je Takt meist keiner. Ein Prozess ohne gemessene Last zählt dann
    ///   ebenfalls als ruhig statt als Lücke.
    public init(time: Date, snapshot: TaskManagerSnapshot, currentUID: UInt32, above minimumCoreShare: Double? = nil) {
        let cores = snapshot.cpu?.cores.count ?? 0
        guard !snapshot.unavailable.contains(.processes), !snapshot.processes.isEmpty, cores > 0 else {
            self.init(time: time, processes: nil)
            return
        }
        var processes: [ProcessKey: ProcessLoad] = [:]
        for process in snapshot.processes {
            let coreShare = process.cpuLoad.map { $0 * Double(cores) }
            if let minimumCoreShare, (coreShare ?? 0) <= minimumCoreShare { continue }
            processes[process.key] = ProcessLoad(
                coreShare: coreShare,
                subject: WatchbookSubject(processNamed: process.name, uid: process.uid, currentUID: currentUID))
        }
        self.init(time: time, processes: processes)
    }
}
