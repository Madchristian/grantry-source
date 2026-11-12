import Foundation
import Testing
@testable import ManagerKit

/// Texte des Segments „Prozesse“ im Lagebild (LB-4.4, #550): Zustandszeile, Stand des Scans, Umfang der Auswahl,
/// Zeilen und Ausgänge je Posten.
@Suite struct ProcessCleanupBoardTests {
    private typealias F = ProcessFixture
    private typealias P = ProcessCleanupPresentation

    private func tree(_ pid: pid_t = 301, memory: UInt64 = 1 << 30) throws -> AgentProcessTree {
        try #require(F.detector.scan([F.entry(pid, parent: 1, ["/opt/homebrew/bin/node", "/x/foo-mcp"],
                                              memory: memory)]).orphans.first)
    }

    private let memory = MemoryStatus(physicalBytes: 32 << 30, usedBytes: 18 << 30, swapUsedBytes: 0, swapTotalBytes: 0,
                                      pressure: .normal, processCount: 12)

    private let simulator = BootedSimulator(udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone Beispiel",
                                            runtime: "iOS 27.0", bootedAt: nil, memoryBytes: 1 << 29, processCount: 3)

    private func overview(trees: [AgentProcessTree] = [], simulators: [BootedSimulator] = [],
                          simulatorError: String? = nil) -> ProcessOverview {
        ProcessOverview(memory: memory, agentTrees: AgentTreeScan(orphans: trees, inUseCount: 0), simulators: simulators,
                        simulatorError: simulatorError)
    }

    // MARK: - Zustandszeile

    @Test func beforeTheFirstScanTheShieldStaysOpen() {
        let verdict = ProcessCleanupVerdict(overview: nil, isScanning: false, scanError: nil, survivorCount: 0)
        #expect(verdict.title == "Noch nicht gescannt")
        #expect(verdict.shield == .open)
        #expect(verdict.items.isEmpty)
        #expect(verdict.facts == "liest nur auf Knopfdruck")
        let scanning = ProcessCleanupVerdict(overview: nil, isScanning: true, scanError: nil, survivorCount: 0)
        #expect(scanning.title == "Scan läuft")
        #expect(scanning.shield == .open)
    }

    @Test func findingsNameTreesSimulatorsAndPressure() throws {
        let verdict = ProcessCleanupVerdict(overview: overview(trees: [try tree(301), try tree(302)],
                                                               simulators: [simulator]),
                                            isScanning: false, scanError: nil, survivorCount: 0)
        #expect(verdict.title == "3 Posten aufräumbar")
        #expect(verdict.shield == .finding)
        #expect(verdict.items == [SystemVerdict.Item(text: "2 verwaiste Agenten", tone: .warning),
                                  SystemVerdict.Item(text: "1 Simulator", tone: .neutral),
                                  SystemVerdict.Item(text: "Druck normal", tone: .positive)])
        #expect(verdict.facts == P.statusFacts(memory))
        #expect(!verdict.facts.contains("Speicherdruck"))
    }

    @Test func nothingFoundIsCalm() {
        let verdict = ProcessCleanupVerdict(overview: overview(), isScanning: false, scanError: nil, survivorCount: 0)
        #expect(verdict.title == "Ruhig")
        #expect(verdict.shield == .calm)
        #expect(verdict.items == [SystemVerdict.Item(text: "Druck normal", tone: .positive)])
    }

    @Test func unreadableSourcesGiveNoAllClear() {
        let simulators = ProcessCleanupVerdict(overview: overview(simulatorError: "simctl antwortet nicht"),
                                               isScanning: false, scanError: nil, survivorCount: 0)
        #expect(simulators.title == "Nicht vollständig gelesen")
        #expect(simulators.shield == .finding)
        let processes = ProcessCleanupVerdict(overview: nil, isScanning: false, scanError: "Keine Berechtigung",
                                              survivorCount: 0)
        #expect(processes.title == "Nicht vollständig gelesen")
        #expect(processes.shield == .finding)
    }

    @Test func survivorsLeadTheVerdict() throws {
        let verdict = ProcessCleanupVerdict(overview: overview(trees: [try tree()]), isScanning: false, scanError: nil,
                                            survivorCount: 1)
        #expect(verdict.title == "1 Prozess reagiert nicht")
        #expect(verdict.items.first == SystemVerdict.Item(text: "1 läuft weiter", tone: .warning))
        #expect(verdict.items.contains(SystemVerdict.Item(text: "1 verwaister Agent", tone: .warning)))
        #expect(verdict.items.count <= 3)
    }

    @Test func statusFactsLeaveOutThePressure() {
        #expect(P.statusFacts(memory) == "Arbeitsspeicher \(P.memoryText(18 << 30)) von \(P.memoryText(32 << 30)) "
            + "· kein Swap · 12 Prozesse")
        #expect(P.statusLine(memory).contains("Speicherdruck normal"))
    }

    // MARK: - Stand des Scans

    @Test func scanStateNamesMissingSimulators() {
        let complete = P.scanState(overview())
        #expect(complete.title == "Scan vollständig")
        #expect(complete.detail == "Prozesse und Simulatoren gelesen")
        #expect(complete.isComplete)
        let partial = P.scanState(overview(simulatorError: "simctl antwortet nicht"))
        #expect(partial.title == "Scan unvollständig")
        #expect(!partial.isComplete)
    }

    // MARK: - Zeilen und Umfang

    @Test func treeDetailLeavesTheMemoryForTheSizeColumn() throws {
        let tree = try tree()
        let now = tree.startDate.addingTimeInterval(7_200)
        #expect(P.detail(tree, now: now) == "läuft seit 2 Stunden · 1 Prozess")
        #expect(P.subtitle(tree, now: now) == P.detail(tree, now: now) + " · " + P.memoryText(tree.memoryBytes))
    }

    @Test func simulatorDetailAndSize() {
        #expect(P.detail(simulator, now: .now) == "3 Prozesse")
        #expect(P.sizeText(simulator) == P.memoryText(1 << 29))
        let unknown = BootedSimulator(udid: "X", name: "iPad", runtime: "iOS 27.0", bootedAt: nil, memoryBytes: nil,
                                      processCount: 0)
        #expect(P.sizeText(unknown) == "–")
    }

    @Test func scopeSumsTheSelection() throws {
        #expect(P.selectionScope(trees: [], simulators: []) == "Nichts ausgewählt")
        let scope = P.selectionScope(trees: [try tree(301), try tree(302)], simulators: [simulator])
        #expect(scope == "Ausgewählt: 2 Agenten-Bäume · 1 Simulator · 5 Prozesse · \(P.memoryText((2 << 30) + (1 << 29)))")
        #expect(P.selectionScope(trees: [try tree()], simulators: [])
            == "Ausgewählt: 1 Agenten-Baum · 1 Prozess · \(P.memoryText(1 << 30))")
    }

    @Test func memberShowsLabelPidAndMemory() throws {
        let member = try tree().root
        #expect(P.memberValue(member) == "PID 301 · \(P.memoryText(1 << 30))")
    }

    // MARK: - Ausgänge

    @Test func outcomeStatusPerResult() throws {
        let tree = try tree()
        let ended = ProcessCleanupOutcome(.tree(tree), .removed)
        #expect(P.outcomeStatus(ended) == SystemVerdict.Item(text: "beendet", tone: .positive))
        #expect(P.outcomeReason(ended) == nil)
        let running = ProcessCleanupOutcome(.tree(tree), .failed("1 Prozess läuft noch."),
                                            survivors: [tree.root.runningProcess])
        #expect(P.outcomeStatus(running) == SystemVerdict.Item(text: "läuft weiter", tone: .warning))
        #expect(P.outcomeReason(running) == "1 Prozess läuft noch.")
        let skipped = ProcessCleanupOutcome(.tree(tree), .skipped("weg"))
        #expect(P.outcomeStatus(skipped) == SystemVerdict.Item(text: "übersprungen", tone: .neutral))
        let failed = ProcessCleanupOutcome(.tree(tree), .failed("Keine Berechtigung"))
        #expect(P.outcomeStatus(failed) == SystemVerdict.Item(text: "fehlgeschlagen", tone: .critical))
    }

    @Test func resultBannerToneAndMessage() throws {
        let tree = try tree()
        let ended = ProcessCleanupOutcome(.tree(tree), .removed)
        #expect(P.resultTone([ended]) == .positive)
        #expect(P.resultMessage([ended]) == "")
        let running = ProcessCleanupOutcome(.tree(tree), .failed("1 Prozess läuft noch."),
                                            survivors: [tree.root.runningProcess])
        #expect(P.resultTone([ended, running]) == .warning)
        #expect(P.resultMessage([ended, running]) == "„\(tree.title)“ läuft nach SIGTERM weiter.")
        let skipped = ProcessCleanupOutcome(.tree(tree), .skipped("weg"))
        #expect(P.resultTone([skipped]) == .neutral)
    }
}
