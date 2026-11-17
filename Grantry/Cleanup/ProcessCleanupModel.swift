import Foundation
import ManagerKit
import Observation
import os

/// Zustand des Segments „Prozesse“ (#221): Scan auf Knopfdruck (abbrechbar, #611), Auswahl, Beenden nach Bestätigung,
/// SIGKILL nur nach zweiter Bestätigung, Ergebnis und Protokoll (`CleanupLog`, geteilt mit „Speicher“). Lebt im
/// `AppModel`; automatisch wird nie etwas beendet.
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
    /// Der Nutzer hat das Ergebnis-Banner geschlossen; Ausgänge und „Sofort beenden“ bleiben bis zur nächsten Aktion.
    private(set) var isResultDismissed = false
    /// Ende des Scans, der `overview` geliefert hat (#611).
    private(set) var scannedAt: Date?
    /// Der letzte Scan wurde abgebrochen; `overview` ist dann das frühere vollständige Ergebnis oder `nil`.
    private(set) var isScanCancelled = false
    /// Leiste über der Prozessliste (#270): Schritte sind die `ProcessScanStep`s.
    let scanProgress = SegmentScanProgress()

    @ObservationIgnored private let scanner: ProcessOverviewScanner
    @ObservationIgnored private let cleaner: ProcessCleaner
    @ObservationIgnored private let log: CleanupLog
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Der Scanner blockiert auf einer seriellen Queue: Ein Neustart nach dem Abbruch wartet auf deren Ende (#611).
    @ObservationIgnored private let scanRunner = SerialScanRunner()

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
        isScanCancelled = false
        let step = scanProgress.begin(steps: ProcessScanStep.allCases.map(\.rawValue))
        scanRunner.start({ [scanner] () async -> Result<ProcessOverview, any Error> in
            do {
                return .success(try await scanner.scan { await step($0.map(\.rawValue)) })
            } catch {
                return .failure(error)
            }
        }) { [weak self] result in
            self?.show(result, at: .now)
        }
    }

    /// Bricht den laufenden Scan ab: Ein Teilergebnis gibt es nicht, ein früheres vollständiges Ergebnis bleibt mit
    /// seiner Zeit stehen. Erneutes Scannen ist sofort möglich; es reicht seine Arbeit erst nach dem Ende der
    /// abgebrochenen ein (`SerialScanRunner`).
    func cancelScan() {
        guard phase == .scanning else { return }
        scanRunner.cancel()
        scanProgress.cancel()
        isScanCancelled = true
        phase = overview == nil ? .idle : .scanned
    }

    func dismissResult() {
        isResultDismissed = true
    }

    private func show(_ result: Result<ProcessOverview, any Error>, at date: Date) {
        switch result {
        case .success(let overview):
            let previous = Set(self.overview.map { $0.agentTrees.orphans.map(Self.treeSelectionID) } ?? [])
            self.overview = overview
            scannedAt = date
            scanError = nil
            let trees = overview.agentTrees.orphans.map(Self.treeSelectionID)
            let simulators = overview.simulators.map(Self.simulatorSelectionID)
            // Gewählte Posten bleiben gewählt; neu gefundene Bäume kommen vorausgewählt dazu.
            selection = selection.intersection(trees + simulators).union(trees.filter { !previous.contains($0) })
        case .failure(let error):
            scanError = error.readableDescription
        }
        phase = overview == nil ? .idle : .scanned
        scanProgress.finish()
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
            self.isResultDismissed = false
            self.phase = .scanned
            self.scan()
        }
    }
}
