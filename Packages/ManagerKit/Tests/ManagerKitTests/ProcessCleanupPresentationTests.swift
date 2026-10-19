import Foundation
import Testing
@testable import ManagerKit

@Suite struct ProcessCleanupPresentationTests {
    private typealias F = ProcessFixture
    private typealias P = ProcessCleanupPresentation

    private func tree(_ pid: pid_t = 301, memory: UInt64 = 2_000_000_000) throws -> AgentProcessTree {
        try #require(F.detector.scan([F.entry(pid, parent: 1, ["/opt/homebrew/bin/node", "/x/foo-mcp", "--token=geheim"],
                                              memory: memory)]).orphans.first)
    }

    @Test func statusLineNamesMemorySwapPressureAndProcesses() {
        let status = MemoryStatus(physicalBytes: 64 << 30, usedBytes: 59 << 30, swapUsedBytes: 25 << 30,
                                  swapTotalBytes: 26 << 30, pressure: .warning, processCount: 1_131)
        let line = P.statusLine(status)
        #expect(line.hasPrefix("Arbeitsspeicher "))
        #expect(line.contains(" · Swap "))
        #expect(line.contains("Speicherdruck erhöht"))
        #expect(line.hasSuffix("1131 Prozesse") || line.hasSuffix("1.131 Prozesse"))
        let unknown = MemoryStatus(physicalBytes: 1 << 30, usedBytes: nil, swapUsedBytes: 0, swapTotalBytes: 0,
                                   pressure: nil, processCount: 1)
        #expect(P.statusLine(unknown) == "Arbeitsspeicher \(P.memoryText(1 << 30)) · kein Swap · 1 Prozess")
    }

    @Test func confirmationListsEveryTargetWithoutArguments() throws {
        let simulator = BootedSimulator(udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "iPhone 17", runtime: "iOS 27.0",
                                        bootedAt: nil, memoryBytes: nil, processCount: 0)
        let confirmation = P.confirmation(trees: [try tree()], simulators: [simulator])
        #expect(confirmation.title == "2 Posten beenden?")
        let message = try #require(confirmation.message)
        #expect(message.contains("MCP-Server, PID 301 (1 Prozess): beenden (SIGTERM)"))
        #expect(message.contains("xcrun simctl shutdown AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(!message.contains("geheim"))
        #expect(confirmation.isDestructive)
    }

    @Test func forceConfirmationCountsSurvivors() throws {
        let tree = try tree()
        let outcome = ProcessCleanupOutcome(.tree(tree), .failed("1 Prozess läuft noch."),
                                            survivors: [tree.root.runningProcess])
        #expect(P.forceConfirmation([outcome]).title == "1 Prozess sofort beenden (SIGKILL)?")
    }

    @Test func summaryCountsResults() throws {
        let ended = ProcessCleanupOutcome(.tree(try tree(301, memory: 1 << 30)), .removed)
        let running = ProcessCleanupOutcome(.tree(try tree(302)), .failed("1 Prozess läuft noch."),
                                            survivors: [try tree(302).root.runningProcess])
        let skipped = ProcessCleanupOutcome(.tree(try tree(303)), .skipped(ProcessCleaner.goneReason))
        let failed = ProcessCleanupOutcome(.tree(try tree(304)), .failed("Keine Berechtigung"))
        #expect(P.summary([ended, running, skipped, failed])
            == "1 beendet (\(P.memoryText(1 << 30)) Arbeitsspeicher), 1 läuft noch, 1 übersprungen, 1 fehlgeschlagen")
        #expect(P.summary([skipped]) == "Nichts beendet, 1 übersprungen")
    }

    @Test(arguments: [(30, "1 Minute"), (600, "10 Minuten"), (7_200, "2 Stunden"), (86_400, "1 Tag"), (3 * 86_400, "3 Tagen")] as [(TimeInterval, String)])
    func ages(_ seconds: TimeInterval, _ expected: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(P.age(since: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func inUseNote() {
        #expect(P.inUseNote(0) == nil)
        #expect(P.inUseNote(2) == "2 Agenten-Prozessbäume gehören zu laufenden Sitzungen und werden nicht angeboten.")
    }
}
