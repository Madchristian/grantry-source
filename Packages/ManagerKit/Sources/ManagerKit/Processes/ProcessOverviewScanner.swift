import Foundation

/// Stand des Segments „Prozesse“ (#221).
public struct ProcessOverview: Hashable, Sendable {
    public let memory: MemoryStatus
    public let agentTrees: AgentTreeScan
    public let simulators: [BootedSimulator]
    /// Simulatoren nicht lesbar (`simctl` gescheitert); die übrigen Angaben gelten trotzdem.
    public let simulatorError: String?
}

/// Schritte von `ProcessOverviewScanner.scan(onStep:)` für die Fortschrittsleiste (#270), in Ausführungsreihenfolge.
public enum ProcessScanStep: String, CaseIterable, Sendable {
    /// Prozesstabelle, verwaiste Agenten-Bäume und Speicherstatus.
    case processTable
    /// Gebootete Simulatoren (`simctl`).
    case simulators
}

/// Liest Prozesstabelle, verwaiste Agenten-Bäume, Speicherstatus und gebootete Simulatoren auf Knopfdruck (`scan()`);
/// im Hintergrund nur die Agenten-Bäume für den Hinweis (`scanAgentTrees()`, #224). Die synchronen Systemabfragen
/// (Prozesstabelle, kanonische Arbeitsordner) laufen auf einer eigenen Queue (`BlockingWorkQueue`), nicht im Swift-Pool;
/// beide Wege teilen sie, laufen also nie gleichzeitig.
public struct ProcessOverviewScanner: Sendable {
    static let queue = BlockingWorkQueue(label: "process-scan")

    private let table: any ProcessTableReading
    private let detector: OrphanAgentTreeDetector
    private let simulators: BootedSimulatorReader

    public init() {
        self.init(table: LibprocProcessTable(), detector: OrphanAgentTreeDetector(), simulators: BootedSimulatorReader())
    }

    init(table: any ProcessTableReading, detector: OrphanAgentTreeDetector, simulators: BootedSimulatorReader) {
        self.table = table
        self.detector = detector
        self.simulators = simulators
    }

    /// - Parameter onStep: erhält je erledigtem `ProcessScanStep` genau einen Abschluss; nach einem Fehler der
    ///   Prozesstabelle keinen mehr.
    /// - Throws: `CancellationError`, wenn der Scan nach der Prozesstabelle abgebrochen ist; `simctl` startet dann nicht
    ///   mehr (#611). Die Abfrage der Prozesstabelle selbst läuft bis zu ihrem Ende.
    public func scan(onStep: ScanStepHandler<ProcessScanStep>? = nil) async throws -> ProcessOverview {
        let (entries, trees, memory) = try await Self.queue.runThrowing { [table, detector] in
            let entries = try table.entries()
            return (entries, detector.scan(entries), MemoryStatus.current(processCount: entries.count))
        }
        try Task.checkCancellation()
        await onStep?(.completed(.processTable, succeeded: true))
        let overview: ProcessOverview
        do {
            let booted = try await simulators.booted(entries: entries)
            overview = ProcessOverview(memory: memory, agentTrees: trees, simulators: booted, simulatorError: nil)
        } catch {
            overview = ProcessOverview(memory: memory, agentTrees: trees, simulators: [],
                                       simulatorError: error.readableDescription)
        }
        await onStep?(.completed(.simulators, succeeded: overview.simulatorError == nil))
        return overview
    }

    /// Nur die verwaisten Agenten-Bäume – ohne `simctl` und Speicherstatus, für den Hinweis im Hintergrund (#224).
    public func scanAgentTrees() async throws -> AgentTreeScan {
        try await Self.queue.runThrowing { [table, detector] in detector.scan(try table.entries()) }
    }
}
