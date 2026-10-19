import Foundation

/// Stand des Segments „Prozesse“ (#221).
public struct ProcessOverview: Hashable, Sendable {
    public let memory: MemoryStatus
    public let agentTrees: AgentTreeScan
    public let simulators: [BootedSimulator]
    /// Simulatoren nicht lesbar (`simctl` gescheitert); die übrigen Angaben gelten trotzdem.
    public let simulatorError: String?
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

    public func scan() async throws -> ProcessOverview {
        let (entries, trees, memory) = try await Self.queue.runThrowing { [table, detector] in
            let entries = try table.entries()
            return (entries, detector.scan(entries), MemoryStatus.current(processCount: entries.count))
        }
        do {
            let booted = try await simulators.booted(entries: entries)
            return ProcessOverview(memory: memory, agentTrees: trees, simulators: booted, simulatorError: nil)
        } catch {
            return ProcessOverview(memory: memory, agentTrees: trees, simulators: [], simulatorError: error.readableDescription)
        }
    }

    /// Nur die verwaisten Agenten-Bäume – ohne `simctl` und Speicherstatus, für den Hinweis im Hintergrund (#224).
    public func scanAgentTrees() async throws -> AgentTreeScan {
        try await Self.queue.runThrowing { [table, detector] in detector.scan(try table.entries()) }
    }
}
