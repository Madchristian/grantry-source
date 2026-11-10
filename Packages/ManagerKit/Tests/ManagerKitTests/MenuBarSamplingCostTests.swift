import Darwin
import Testing
@testable import ManagerKit

/// Messweg für das Budget der Menüleisten-Anzeige (Spec §4: Sampling ≤ 1 % CPU bei 1 s Takt): CPU-Zeit je Takt der
/// Quellen des Abnehmers `.menuBar`. Die verbindliche Messung am Release-Kandidaten beschreibt
/// `docs/performance-abnahme.md` (Abschnitt „Menüleisten-Anzeige des Task-Managers“).
@Suite struct MenuBarSamplingCostTests {
    /// 1 % von 1 s sind 10 ms; 2 ms bleiben für Engine, Accumulator und das Zeichnen des Symbols.
    private static let budgetNanoseconds: UInt64 = 8_000_000

    private static func threadCPUNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Liest jede Quelle einmal auf dem aktuellen Thread (die Engine liest sie nebenläufig, die Summe ist dieselbe).
    private static func readAll(_ sources: TaskManagerSources) throws {
        _ = try sources.processes?.read()
        _ = try sources.cpu?.read()
        _ = try sources.memory?.read()
        _ = try sources.disks?.read()
        _ = try sources.interfaces?.read()
        _ = try sources.gpu?.read()
        _ = try sources.battery?.read()
    }

    /// Median und Maximum der CPU-Zeit über 20 Takte nach einem Aufwärmtakt.
    private static func cost(of sources: TaskManagerSources) throws -> (median: UInt64, maximum: UInt64) {
        try readAll(sources)
        var costs: [UInt64] = []
        for _ in 0..<20 {
            let before = threadCPUNanoseconds()
            try readAll(sources)
            costs.append(threadCPUNanoseconds() - before)
        }
        costs.sort()
        return (costs[costs.count / 2], costs[costs.count - 1])
    }

    @Test func menuBarTaktStaysWellBelowOnePercent() throws {
        let menuBar = TaskManagerSources.system.restricted(to: TaskManagerModel.Consumer.menuBar.sources)
        #expect(menuBar.configured == [.cpu, .memory, .disks, .interfaces])
        let cost = try Self.cost(of: menuBar)
        let window = try Self.cost(of: .system)
        print("menuBar takt cpu_us median=\(cost.median / 1_000) max=\(cost.maximum / 1_000); "
              + "window takt cpu_us median=\(window.median / 1_000)")
        #expect(cost.median < Self.budgetNanoseconds)
    }

    /// Alle Menüleisten-Elemente zusammen (TM-17.5, #468): die Quellen aller Elemente, also zusätzlich GPU und Akku,
    /// aber nie die Prozesse. Budget wie oben bei 1 s, das bei 2 s Takt die Hälfte des Kerns-Prozents bedeutet.
    @Test @MainActor func allMenuBarElementsStayWellBelowOnePercent() throws {
        let union = MenuBarMeterKind.allCases.reduce(into: Set<TaskManagerSource>()) { $0.formUnion($1.sources) }
        #expect(!union.contains(.processes))
        let sources = TaskManagerSources.system.restricted(to: union)
        let cost = try Self.cost(of: sources)
        print("allMenuBarElements takt cpu_us median=\(cost.median / 1_000) max=\(cost.maximum / 1_000)")
        #expect(cost.median < Self.budgetNanoseconds)
    }
}
