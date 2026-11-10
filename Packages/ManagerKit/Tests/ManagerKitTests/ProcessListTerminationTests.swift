import Testing
@testable import ManagerKit

@Suite struct ProcessListTerminationTests {
    private static let me: UInt32 = 501

    @Test func onlyRowsOfOwnProcessesAreCandidates() {
        let own = ProcessMeasurement(key: ProcessKey(pid: 7, startTime: 1), parentPID: 1, uid: Self.me, name: "zsh",
                                     cpuLoad: nil, memoryBytes: nil, diskReadPerSecond: nil, diskWritePerSecond: nil,
                                     threadCount: nil)
        let foreign = ProcessMeasurement(key: ProcessKey(pid: 8, startTime: 1), parentPID: 1, uid: 0, name: "launchd",
                                         cpuLoad: nil, memoryBytes: nil, diskReadPerSecond: nil, diskWritePerSecond: nil,
                                         threadCount: nil)
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [own, foreign]
        let rows = ProcessListPresenter.present(snapshot, apps: [], currentUID: Self.me, network: nil,
                                                options: ProcessListOptions()).rows
        #expect(rows.map { $0.terminationCandidate(currentUID: Self.me) } == [
            nil, TaskTerminationCandidate(name: "zsh", keys: [own.key]), nil, nil,
        ])
    }
}
