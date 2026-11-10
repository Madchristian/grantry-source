import Testing
@testable import ManagerKit

@Suite struct ProcessListPresenterTests {
    private static let me: UInt32 = 501
    private static let browser = RunningApp(pid: 100, bundleID: nil, bundlePath: "/Applications/Browser.app",
                                            name: "Browser")

    private func process(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = me, name: String, cpu: Double?,
                         memory: UInt64? = nil, path: String? = nil) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: parent, uid: uid, name: name, cpuLoad: cpu,
                           memoryBytes: memory, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil,
                           executablePath: path)
    }

    private var snapshot: TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [
            process(100, name: "Browser", cpu: 0.02, memory: 400, path: "/Applications/Browser.app/Contents/MacOS/Browser"),
            process(101, parent: 100, name: "Browser Helper", cpu: 0.08, memory: 900),
            process(102, parent: 100, name: "Browser Helper (GPU)", cpu: nil),
            process(200, name: "node", cpu: 0.05),
            process(201, name: "zsh", cpu: 0.001),
            process(300, uid: 0, name: "WindowServer", cpu: nil),
        ]
        return snapshot
    }

    private func present(_ options: ProcessListOptions = ProcessListOptions(),
                         snapshot: TaskManagerSnapshot? = nil) -> ProcessListPresentation {
        ProcessListPresenter.present(snapshot ?? self.snapshot, apps: [Self.browser], currentUID: Self.me, network: nil,
                                     options: options, physicalMemory: 1_000)
    }

    @Test func groupsWithEntriesSortedByCPUDescending() {
        let rows = present().rows
        #expect(rows.map(\.id) == ["group:apps", "app:100", "group:background", "process:200-1", "process:201-1",
                                   "group:system", "process:300-1"])
        #expect(rows[0].detail == "3 Prozesse")
        #expect(rows[1].detail == "3 Prozesse")
        #expect(rows[3].detail == "PID 200")
        #expect(rows[1].figures.cpuLoad == 0.1)
    }

    @Test func collapsedGroupShowsOnlyItsHeader() {
        var options = ProcessListOptions()
        options.toggle(present().rows[2])
        #expect(options.collapsedGroups == [.background])
        #expect(present(options).rows.map(\.id).filter { $0.hasPrefix("process:20") }.isEmpty)
        #expect(present(options).rows.contains { $0.id == "group:background" && !$0.isExpanded })
    }

    @Test func expandedAppShowsChildrenInSortOrderWithUnmeasuredLast() {
        var options = ProcessListOptions()
        options.toggle(present().rows[1])
        let ids = present(options).rows.map(\.id)
        #expect(Array(ids[1...4]) == ["app:100", "child:101-1", "child:100-1", "child:102-1"])
        #expect(present(options).rows[1].isExpanded)
    }

    @Test func unmeasuredValuesStayLastInBothDirections() {
        var options = ProcessListOptions()
        options.sort = ProcessSort(column: .cpu, ascending: true)
        let system = present(options).rows.map(\.id)
        #expect(Array(system[3...4]) == ["process:201-1", "process:200-1"])
        options.expandedEntries = ["app:100"]
        #expect(present(options).rows.map(\.id)[4] == "child:102-1")
    }

    @Test func sortsByNameAscendingFirst() {
        var options = ProcessListOptions()
        options.sort = ProcessSort.default.selecting(.name)
        #expect(options.sort == ProcessSort(column: .name, ascending: true))
        #expect(present(options).rows.map(\.title)[2...4] == ["Hintergrundprozesse", "node", "zsh"])
        options.sort = options.sort.selecting(.name)
        #expect(present(options).rows.map(\.title)[2...4] == ["Hintergrundprozesse", "zsh", "node"])
    }

    @Test func newValueColumnStartsDescending() {
        #expect(ProcessSort(column: .name, ascending: true).selecting(.memory) == ProcessSort(column: .memory,
                                                                                             ascending: false))
        #expect(ProcessSort.default.selecting(.cpu) == ProcessSort(column: .cpu, ascending: true))
    }

    @Test func searchMatchesNameOrPID() {
        var options = ProcessListOptions()
        options.query = "zs"
        #expect(present(options).rows.map(\.id) == ["group:background", "process:201-1"])
        options.query = "30"
        #expect(present(options).rows.map(\.id) == ["group:system", "process:300-1"])
    }

    /// Mangel 8 der Bewertung 2026.11.7: Bei einer Suche zählt und summiert die Gruppe nur ihre Treffer.
    @Test func searchLimitsGroupCountAndSums() {
        var options = ProcessListOptions()
        options.query = "zs"
        let group = present(options).rows[0]
        #expect(group.detail == "1 Prozess")
        #expect(group.figures.cpuLoad == 0.001)
        #expect(present().rows.first { $0.id == "group:background" }?.detail == "2 Prozesse")
    }

    @Test func searchHittingOnlyAChildShowsItWithoutExpanding() {
        var options = ProcessListOptions()
        options.query = "GPU"
        #expect(present(options).rows.map(\.id) == ["group:apps", "app:100", "child:102-1"])
        #expect(!present(options).rows[1].isExpanded)
    }

    /// Prozentwerte mit geschütztem Leerzeichen (`\u{A0}`) wie `FormatStyle` in de_DE.
    @Test func columnTextsAndHeat() {
        let figures = ProcessFigures(cpuLoad: 0.25, memoryBytes: 250, diskPerSecond: 1_200_000, networkPerSecond: nil)
        #expect(ProcessColumn.cpu.text(figures) == "25,0\u{A0}%")
        #expect(ProcessColumn.disk.text(figures) == "1,2 MB/s")
        #expect(ProcessColumn.network.text(figures) == "–")
        #expect(ProcessColumn.cpu.heat(figures, physicalMemory: 1_000) == 0.5)
        #expect(ProcessColumn.memory.heat(figures, physicalMemory: 1_000) == 0.5)
        #expect(ProcessColumn.network.heat(figures, physicalMemory: 1_000) == nil)
        #expect(ProcessColumn.cpu.heat(ProcessFigures(cpuLoad: 3, memoryBytes: nil, diskPerSecond: nil,
                                                      networkPerSecond: nil), physicalMemory: 1) == 1)
    }

    @Test func headerPrefersSystemWideValues() {
        #expect(present().headerValue(.cpu) == "15,1\u{A0}%")
        #expect(present().headerValue(.name) == "6 Prozesse")
        var withSystem = snapshot
        withSystem.cpu = CPULoad(total: 0.42, cores: [])
        withSystem.memory = MemoryStatus(physicalBytes: 2_000, usedBytes: 1_500, swapUsedBytes: nil, swapTotalBytes: nil,
                                         pressure: .normal, processCount: 0)
        let presentation = present(snapshot: withSystem)
        #expect(presentation.totals.cpuLoad == 0.42)
        #expect(presentation.totals.memoryBytes == 1_500)
        #expect(presentation.physicalMemory == 2_000)
    }

    @Test func emptyNameFallsBackToPID() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [process(77, name: "", cpu: nil)]
        #expect(present(snapshot: snapshot).rows.last?.title == "Prozess 77")
    }
}
