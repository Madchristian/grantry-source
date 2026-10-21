import Foundation
import ManagerKit
import Observation
import os

/// Zustand des Segments „Prozesse“ (#221): Scan auf Knopfdruck, Auswahl, Beenden nach Bestätigung, SIGKILL nur nach
/// zweiter Bestätigung, Ergebnis und Protokoll (`CleanupLog`, geteilt mit „Speicher“). Lebt im `AppModel`; automatisch
/// wird nie etwas beendet.
@MainActor
@Observable
final class ProcessCleanupModel {
    enum Phase: Equatable {
        case idle, scanning, scanned, cleaning
    }

    nonisolated private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "process-cleanup")

    private(set) var phase: Phase = .idle
    private(set) var overview: ProcessOverview?
    private(set) var scanError: String?
    /// IDs aus `treeSelectionID(_:)` und `simulatorSelectionID(_:)`.
    var selection: Set<String> = []
    private(set) var lastOutcomes: [ProcessCleanupOutcome] = []
    /// Leiste über der Prozessliste (#270): Schritte sind die `ProcessScanStep`s.
    let scanProgress = SegmentScanProgress()

    @ObservationIgnored private let scanner: ProcessOverviewScanner
    @ObservationIgnored private let cleaner: ProcessCleaner
    @ObservationIgnored private let log: CleanupLog
    @ObservationIgnored private var task: Task<Void, Never>?

    init(scanner: ProcessOverviewScanner = ProcessOverviewScanner(), cleaner: ProcessCleaner = ProcessCleaner(),
         log: CleanupLog) {
        self.scanner = scanner
        self.cleaner = cleaner
        self.log = log
    }

    static func treeSelectionID(_ tree: AgentProcessTree) -> String { "tree:" + tree.id }
    static func simulatorSelectionID(_ simulator: BootedSimulator) -> String { "simulator:" + simulator.id }

    var selectedTrees: [AgentProcessTree] {
        overview?.agentTrees.orphans.filter { selection.contains(Self.treeSelectionID($0)) } ?? []
    }

    var selectedSimulators: [BootedSimulator] {
        overview?.simulators.filter { selection.contains(Self.simulatorSelectionID($0)) } ?? []
    }

    /// Ausgänge mit Überlebenden des SIGTERM: Angebot „Sofort beenden (SIGKILL) …“.
    var forceOffer: [ProcessCleanupOutcome] { lastOutcomes.filter { !$0.survivors.isEmpty } }

    /// Liest neu. Verwaiste Agenten-Bäume sind vorausgewählt, Simulatoren nicht (sie können gerade benutzt werden).
    func scan() {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        let step = scanProgress.begin(steps: ProcessScanStep.allCases.map(\.rawValue))
        task = Task { [weak self, scanner] in
            let result: Result<ProcessOverview, any Error>
            do {
                result = .success(try await scanner.scan { await step($0.map(\.rawValue)) })
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            switch result {
            case .success(let overview):
                let previous = Set(self.overview.map { $0.agentTrees.orphans.map(Self.treeSelectionID) } ?? [])
                self.overview = overview
                self.scanError = nil
                let trees = overview.agentTrees.orphans.map(Self.treeSelectionID)
                let simulators = overview.simulators.map(Self.simulatorSelectionID)
                // Gewählte Posten bleiben gewählt; neu gefundene Bäume kommen vorausgewählt dazu.
                self.selection = self.selection.intersection(trees + simulators).union(trees.filter { !previous.contains($0) })
            case .failure(let error):
                self.scanError = error.readableDescription
            }
            self.phase = self.overview == nil ? .idle : .scanned
            self.scanProgress.finish()
        }
    }

    /// Bestätigte Auswahl: Bäume mit SIGTERM (nach Neuprüfung im `ProcessCleaner`), Simulatoren herunterfahren.
    func clean() {
        let trees = selectedTrees, simulators = selectedSimulators
        guard phase == .scanned, !trees.isEmpty || !simulators.isEmpty else { return }
        run { cleaner in
            var outcomes: [ProcessCleanupOutcome] = []
            for tree in trees { outcomes.append(await cleaner.terminate(tree)) }
            for simulator in simulators { outcomes.append(await cleaner.shutdown(simulator)) }
            return outcomes
        }
    }

    /// Zweite Bestätigung erteilt: SIGKILL an die Überlebenden.
    func forceTerminate() {
        let offer = forceOffer
        guard phase == .scanned, !offer.isEmpty else { return }
        run { cleaner in
            var outcomes: [ProcessCleanupOutcome] = []
            for outcome in offer { outcomes.append(await cleaner.forceTerminate(outcome)) }
            return outcomes
        }
    }

    private func run(_ action: @escaping @Sendable (ProcessCleaner) async -> [ProcessCleanupOutcome]) {
        phase = .cleaning
        let cleaner = cleaner, log = log
        task = Task { [weak self] in
            let outcomes = await action(cleaner)
            do {
                try log.append(outcomes.map(\.logEntry), at: .now)
            } catch {
                Self.logger.error("Aufräumprotokoll nicht geschrieben: \(error.localizedDescription, privacy: .public)")
            }
            guard let self else { return }
            self.lastOutcomes = outcomes
            self.phase = .scanned
            self.scan()
        }
    }
}
