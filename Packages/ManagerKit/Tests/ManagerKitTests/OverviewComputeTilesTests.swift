import Foundation
import GrantryShared
import Testing
@testable import ManagerKit

/// Kacheln CPU, Kerne, Prozesse und GPU des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2, Teil B #501):
/// Werte je Größe aus dem fertigen Stand, fehlende Werte nie als 0.
@Suite struct OverviewComputeTilesTests {
    private static func overview(_ snapshot: TaskManagerSnapshot, profile: ChipProfile = ChipProfile(facts: ChipFacts()),
                                 context: MenuBarOverviewContext = MenuBarOverviewContext()) -> MenuBarOverview {
        MenuBarOverviewPresentation.overview(for: snapshot, profile: profile, context: context)
    }

    /// Formatter setzen geschützte Leerzeichen vor Einheiten.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Vier Effizienz- und zwölf Leistungskerne mit fester Last je Art wie M4 Max.
    private static func cores(efficiency: Int = 4, performance: Int = 12, efficiencyLoad: Double? = 0.18,
                              performanceLoad: Double? = 0.41) -> CPULoad {
        let cores = Array(repeating: CoreLoad(kind: .efficiency, load: efficiencyLoad), count: efficiency)
            + Array(repeating: CoreLoad(kind: .performance, load: performanceLoad), count: performance)
        return CPULoad(total: 0.38, cores: cores, system: 0.09)
    }

    private static func process(_ pid: Int32, load: Double?) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: 1, uid: 501, name: "p\(pid)",
                           cpuLoad: load, memoryBytes: nil, diskReadPerSecond: nil, diskWritePerSecond: nil,
                           threadCount: nil)
    }

    // MARK: - CPU

    @Test func cpuIdleIsTheRestOfTheTotal() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.38, cores: [], system: 0.09)
        let cpu = try #require(Self.overview(snapshot).cpu)
        #expect(cpu.idle == 0.62)
        #expect(cpu.idleText == "62 %")
    }

    @Test func cpuWithoutTotalHasNoIdleInsteadOfFullIdle() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: nil, cores: [], system: nil)
        let cpu = try #require(Self.overview(snapshot).cpu)
        #expect(cpu.idle == nil)
        #expect(cpu.idleText == "–")
    }

    /// Spitze der letzten Minute aus dem Verlauf; Lücken (`nil`, NaN) zählen nicht, ohne Verlauf „–“ statt 0.
    @Test func peakOfAHistoryIgnoresGaps() {
        #expect(MenuBarOverview.peakText(of: [0.1, 0.72, nil, .nan, 0.3]) == "72 %")
        #expect(MenuBarOverview.peakText(of: []) == "–")
        #expect(MenuBarOverview.peakText(of: [nil, .nan]) == "–")
    }

    // MARK: - Kerne

    @Test func coresSummaryNamesEachKindByTag() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cores()
        let cores = try #require(Self.overview(snapshot).cores)
        #expect(cores.averages.map(\.tag) == ["P", "E"])
        #expect(cores.averages.map(\.value) == ["41 %", "18 %"])
        #expect(cores.spokenSummary == "Leistungskerne 41 %, Effizienzkerne 18 %")
    }

    /// Ohne Kerntypen (Intel, unbekannte Topologie) ein Mittelwert ohne Kürzel.
    @Test func coresSummaryWithoutKindsIsOneAverage() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.3, cores: Array(repeating: CoreLoad(kind: .unknown, load: 0.3), count: 8),
                               system: nil)
        let cores = try #require(Self.overview(snapshot).cores)
        #expect(cores.averages.map(\.tag) == [nil])
        #expect(cores.spokenSummary == "Kerne 30 %")
        #expect(cores.averages.map(\.countText) == ["8 Kerne"])
    }

    @Test func coreAveragesCountTheirCores() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cores(efficiency: 1)
        let cores = try #require(Self.overview(snapshot).cores)
        #expect(cores.averages.map(\.countText) == ["12 P-Kerne", "1 E-Kern"])
    }

    /// Vor der zweiten Messung haben Kerne keine Last: „–“, nie 0 %.
    @Test func coresBeforeFirstLoadAreNotMeasured() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cores(efficiencyLoad: nil, performanceLoad: nil)
        let cores = try #require(Self.overview(snapshot).cores)
        #expect(cores.averages.map(\.value) == ["–", "–"])
        #expect(cores.averages.allSatisfy { $0.load == nil })
    }

    // MARK: - Prozesse

    /// Je Größe so viele Einträge, wie Zeilen passen: 2 × 1 zwei, 4 × 1 vier (zwei Spalten), 2 × 2 fünf, 4 × 2 fünf mit
    /// Lastbalken und Arbeitsspeicher wie die Karte aus PR 623.
    @Test func processCapacityFollowsTheSpan() {
        let capacities = OverviewTileKind.processes.allowedSpans.map(MenuBarOverview.Processes.capacity(of:))
        #expect(OverviewTileKind.processes.allowedSpans == [.wide, .large, .banner, .panel])
        #expect(capacities == [2, 5, 4, 5])
        #expect(MenuBarOverview.Processes.capacity(of: .small) == 0)
    }

    @Test func processesKeepEnoughEntriesForTheLargestTile() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = (1...12).map { Self.process(Int32($0 * 10), load: Double($0) / 100) }
        let processes = try #require(Self.overview(snapshot).processes)
        // Wie die Karte vor dem Baukasten: höchstens fünf Einträge, auch für die größte Kachel.
        #expect(processes.entries.count == 5)
        #expect(processes.entries.map(\.share) == (8...12).reversed().map { Double($0) / 100 })
        #expect(processes.entries(for: .wide).map(\.share) == [0.12, 0.11])
        #expect(processes.entries(for: .banner).count == 4)
        #expect(processes.entries(for: .large).count == 5)
        #expect(processes.entries(for: .panel).count == 5)
    }

    // MARK: - GPU

    @Test func gpuCarriesUtilizationAndMemoryInBytes() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.memory = MemoryStatus(physicalBytes: 64 << 30, usedBytes: nil, swapUsedBytes: nil,
                                       swapTotalBytes: nil, pressure: nil, processCount: 0)
        snapshot.gpu = GPULoadReading(utilization: 0.16, usedMemoryBytes: 2 << 30)
        let gpu = try #require(Self.overview(snapshot).gpu)
        #expect(gpu.utilization == 0.16)
        #expect(Self.plain(try #require(gpu.memory)) == "2 GB")
        #expect(gpu.memoryShare == 1.0 / 32)
    }

    @Test func gpuWithoutMemoryReadingHasNoMemory() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.gpu = GPULoadReading(utilization: 0.16, usedMemoryBytes: nil)
        let gpu = try #require(Self.overview(snapshot).gpu)
        #expect(gpu.memory == nil)
        #expect(gpu.memoryShare == nil)
    }
}
