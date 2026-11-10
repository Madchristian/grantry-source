import Testing
@testable import ManagerKit

@Suite struct ProcessTreeTests {
    private func row(_ pid: Int32, parent: Int32) -> ProcessDetailRow {
        ProcessDetailRow(process: ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: parent, uid: 501,
                                                     name: "p\(pid)", cpuLoad: nil, memoryBytes: nil,
                                                     diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil),
                         userName: "mara", isOwn: true)
    }

    /// PIDs eingerückt nach Tiefe.
    private func shape(_ lines: [ProcessTreeLine]) -> [String] {
        lines.map { String(repeating: "  ", count: $0.depth) + String($0.row.process.key.pid) }
    }

    @Test func childrenFollowTheirParentInRowOrder() {
        let rows = [row(20, parent: 1), row(1, parent: 1), row(11, parent: 10), row(10, parent: 1), row(12, parent: 10)]
        let lines = ProcessTree.lines(rows, collapsed: [])
        #expect(shape(lines) == ["1", "  20", "  10", "    11", "    12"])
        #expect(lines.map(\.childCount) == [2, 0, 2, 0, 0])
        #expect(lines.allSatisfy { $0.isExpanded })
    }

    @Test func collapsedRowHidesAllDescendants() {
        let rows = [row(1, parent: 1), row(10, parent: 1), row(11, parent: 10), row(12, parent: 11)]
        let lines = ProcessTree.lines(rows, collapsed: [rows[1].id])
        #expect(shape(lines) == ["1", "  10"])
        #expect(lines[1].hasChildren && !lines[1].isExpanded)
    }

    @Test func rowWithoutVisibleParentIsRoot() {
        #expect(shape(ProcessTree.lines([row(11, parent: 10), row(12, parent: 11)], collapsed: [])) == ["11", "  12"])
    }

    @Test func ownPIDAsParentIsRoot() {
        #expect(shape(ProcessTree.lines([row(0, parent: 0), row(1, parent: 0)], collapsed: [])) == ["0", "  1"])
    }

    @Test func parentCycleStillShowsEveryRow() {
        #expect(shape(ProcessTree.lines([row(5, parent: 6), row(6, parent: 5)], collapsed: [])) == ["5", "  6"])
    }

    @Test func flatHasNoIndentation() {
        let lines = ProcessTree.flat([row(1, parent: 1), row(10, parent: 1)])
        #expect(shape(lines) == ["1", "10"])
        #expect(lines.allSatisfy { !$0.hasChildren })
    }
}
