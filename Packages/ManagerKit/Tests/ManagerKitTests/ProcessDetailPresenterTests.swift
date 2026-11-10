import Foundation
import Testing
@testable import ManagerKit

@Suite struct ProcessDetailPresenterTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func process(_ pid: Int32, _ name: String, uid: UInt32 = 501, parent: Int32 = 1, cpu: Double? = nil,
                                memory: UInt64? = nil, threads: Int? = nil, cpuTime: UInt64? = nil,
                                path: String? = nil, started: UInt64 = 1_000_000) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: started), parentPID: parent, uid: uid, name: name,
                           cpuLoad: cpu, memoryBytes: memory, diskReadPerSecond: nil, diskWritePerSecond: nil,
                           threadCount: threads, executablePath: path, cpuTimeNanoseconds: cpuTime)
    }

    private static var snapshot: TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [
            process(610, "Safari", cpu: 0.02, memory: 400 << 20, threads: 12, cpuTime: 83_000_000_000,
                    path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            process(612, "Safari Web Content", parent: 610, cpu: 0.08, memory: 1_600 << 20, threads: 20),
            process(88, "WindowServer", uid: 88, cpu: 0.06, memory: 890 << 20, path: "/System/Library/WindowServer"),
            process(1, "launchd", uid: 0, parent: 0),
            process(2_005, "zsh", cpu: 0, memory: 4 << 20, threads: 1, path: ""),
        ]
        return snapshot
    }

    private static func present(_ options: ProcessDetailOptions = ProcessDetailOptions()) -> ProcessDetailPresentation {
        ProcessDetailPresenter.present(snapshot, currentUID: 501, options: options,
                                       userName: { [501: "mara", 0: "root", 88: "_windowserver"][$0] ?? String($0) },
                                       physicalMemory: 32 << 30)
    }

    private static func sorted(_ column: ProcessDetailColumn, ascending: Bool) -> [Int32] {
        var options = ProcessDetailOptions()
        options.sort = ProcessDetailSort(column: column, ascending: ascending)
        return present(options).rows.map(\.process.key.pid)
    }

    @Test func defaultSortIsCPUDescendingWithUnmeasuredLast() {
        #expect(Self.present().rows.map(\.process.key.pid) == [612, 88, 610, 2_005, 1])
    }

    @Test func sortsByEveryColumnWithMissingValuesLastInBothDirections() {
        #expect(Self.sorted(.pid, ascending: true) == [1, 88, 610, 612, 2_005])
        #expect(Self.sorted(.memory, ascending: true) == [2_005, 610, 88, 612, 1])
        #expect(Self.sorted(.memory, ascending: false) == [612, 88, 610, 2_005, 1])
        #expect(Self.sorted(.threads, ascending: false) == [612, 610, 2_005, 1, 88])
        #expect(Self.sorted(.cpuTime, ascending: true) == [610, 1, 612, 88, 2_005])
        #expect(Self.sorted(.user, ascending: true) == [88, 2_005, 610, 612, 1])
        #expect(Self.sorted(.name, ascending: false) == [2_005, 88, 612, 610, 1])
        #expect(Self.sorted(.path, ascending: true) == [610, 1, 2_005, 612, 88])
    }

    @Test func searchesNamePIDAndUser() {
        var options = ProcessDetailOptions()
        options.query = "safari"
        #expect(Self.present(options).rows.map(\.process.key.pid) == [612, 610])
        options.query = "61"
        #expect(Self.present(options).rows.map(\.process.key.pid) == [612, 610])
        options.query = " root "
        #expect(Self.present(options).rows.map(\.process.key.pid) == [1])
        #expect(Self.present(options).processCount == 5)
    }

    @Test func pathOnlyForOwnProcessesAndNeverEmpty() {
        let rows = Dictionary(uniqueKeysWithValues: Self.present().rows.map { ($0.process.key.pid, $0) })
        #expect(rows[610]?.path == "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(rows[88]?.path == nil)
        #expect(rows[2_005]?.path == nil)
        #expect(rows[88].map { ProcessDetailColumn.path.text($0) } == "–")
    }

    @Test func formatsEveryColumn() throws {
        let row = try #require(Self.present().rows.first { $0.process.key.pid == 610 })
        let texts = ProcessDetailColumn.allCases.map { $0.text(row, timeZone: Self.berlin) }
        #expect(texts == ["Safari", "610", "1", "mara", "2,0\u{A0}%", "", "0:01:23", "400 MB", "12",
                          "01.01.1970, 01:00:01", "/Applications/Safari.app/Contents/MacOS/Safari"])
        let foreign = try #require(Self.present().rows.first { $0.process.key.pid == 1 })
        #expect(ProcessDetailColumn.cpu.text(foreign) == "–")
        #expect(ProcessDetailColumn.cpuTime.text(foreign) == "–")
        #expect(ProcessDetailColumn.threads.text(foreign) == "–")
        #expect(ProcessDetailColumn.cpuTimeText(90_061_000_000_000) == "25:01:01")
    }

    @Test func headerShowsTotals() {
        let presentation = Self.present()
        #expect(presentation.headerValue(.name) == "5 Prozesse")
        #expect(presentation.headerValue(.user) == "3 Benutzer")
        #expect(presentation.headerValue(.cpu) == "16,0\u{A0}%")
        // Bewertung 2026.11.7-1188, Mangel 9: WindowServer und launchd ohne Thread-Zahl – die Summe ist eine Teilmenge.
        #expect(presentation.headerValue(.threads) == "mind. 33")
        #expect(presentation.headerValue(.pid).isEmpty)
        #expect(presentation.heat(.cpu, presentation.totals) == ProcessColumn.cpu.heat(presentation.totals,
                                                                                       physicalMemory: 32 << 30))
        #expect(presentation.heat(.pid, presentation.totals) == nil)
    }

    @Test func threadTotalIsPlainWhenEveryProcessIsCounted() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [Self.process(1, "a", threads: 1_200), Self.process(2, "b", uid: 0, threads: 3_400)]
        let presentation = ProcessDetailPresenter.present(snapshot, currentUID: 501, options: ProcessDetailOptions(),
                                                          userName: String.init, physicalMemory: 1)
        #expect(presentation.headerValue(.threads) == "4.600")
    }

    @Test func onlyOwnRowsAreTerminationCandidates() throws {
        let rows = Self.present().rows
        let own = try #require(rows.first { $0.process.key.pid == 612 })
        #expect(own.terminationCandidate == TaskTerminationCandidate(name: "Safari Web Content",
                                                                     keys: [ProcessKey(pid: 612, startTime: 1_000_000)]))
        #expect(rows.first { $0.process.key.pid == 88 }?.terminationCandidate == nil)
    }

    /// Im Tab „Details“ ist jede Zeile ein einzelner Prozess: Für fremde passt „Zeile aufklappen“ nicht, der Hinweis
    /// nennt stattdessen den Tab „Prozesse“. Eigene Prozesse brauchen keinen.
    @Test func foreignRowsExplainWhereTheyCanBeTerminated() throws {
        let rows = Self.present().rows
        let foreign = try #require(rows.first { $0.process.key.pid == 88 })
        #expect(foreign.terminationNote == TaskTerminationCandidate.foreignProcessInDetailsNote)
        #expect(foreign.terminationNote != TaskTerminationCandidate.foreignProcessNote)
        #expect(foreign.terminationNote?.contains("Tab „Prozesse“") == true)
        let own = try #require(rows.first { $0.process.key.pid == 612 })
        #expect(own.terminationNote == nil)
    }

    @Test func emptyNameFallsBackToPID() {
        let row = ProcessDetailRow(process: Self.process(7, ""), userName: "mara", isOwn: true)
        #expect(row.title == "Prozess 7")
    }
}

@Suite struct ProcessDetailColumnsTests {
    @Test func defaultHidesParentPIDAndStartTime() {
        #expect(ProcessDetailColumns.default.visible == [.name, .pid, .user, .cpu, .cpuHistory, .cpuTime, .memory,
                                                         .threads, .path])
    }

    @Test func roundTripsThroughStoredTextAndIgnoresUnknownNames() {
        var columns = ProcessDetailColumns.default
        columns.toggle(.path)
        columns.toggle(.parentPID)
        #expect(columns.rawValue == "startTime,path")
        #expect(ProcessDetailColumns(rawValue: columns.rawValue) == columns)
        #expect(ProcessDetailColumns(rawValue: "threads,gibtsnicht,name").hidden == [.threads])
        #expect(ProcessDetailColumns(rawValue: "").visible == ProcessDetailColumn.allCases)
    }

    @Test func nameCannotBeHidden() {
        var columns = ProcessDetailColumns(hidden: [])
        columns.toggle(.name)
        #expect(columns.contains(.name))
    }

    @Test func sortSelectionFollowsColumnKind() {
        let sort = ProcessDetailSort.default
        #expect(sort.selecting(.cpu) == ProcessDetailSort(column: .cpu, ascending: true))
        #expect(sort.selecting(.name) == ProcessDetailSort(column: .name, ascending: true))
        #expect(sort.selecting(.memory) == ProcessDetailSort(column: .memory, ascending: false))
        #expect(sort.selecting(.startTime) == ProcessDetailSort(column: .startTime, ascending: true))
        #expect(sort.selecting(.cpuHistory) == sort)
    }
}
