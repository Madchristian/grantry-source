import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ForeignProcessUsageTests {
    @Test func parsesPIDUserCPUAndResidentMemory() {
        let output = """
            1     0   0.7  32976
          849   308  58,5 890640
          kaputt
          900   501   abc   100
        """
        let usage = PSUsageParser.parse(output, coreCount: 10)
        #expect(usage.count == 2)
        #expect(usage[1]?.uid == 0)
        #expect(abs((usage[1]?.cpuLoad ?? 0) - 0.0007) < 1e-12)
        #expect(usage[1]?.residentBytes == 32_976 * 1024)
        #expect(usage[849]?.uid == 308)
        #expect(abs((usage[849]?.cpuLoad ?? 0) - 0.0585) < 1e-12)
    }

    @Test func cpuIsCappedAtAllCores() {
        #expect(PSUsageParser.parse("5 0 1200.0 1", coreCount: 8)[5]?.cpuLoad == 1)
    }

    @Test func argumentsNeverRequestCommandLines() {
        #expect(PSUsageParser.arguments == ["-axo", "pid=,uid=,pcpu=,rss="])
    }

    private func process(_ pid: Int32, uid: UInt32, cpu: Double? = nil) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: 1, uid: uid, name: "p\(pid)", cpuLoad: cpu,
                           memoryBytes: nil, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil)
    }

    @Test func fillsOnlyForeignProcessesWithMatchingUser() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [process(88, uid: 88), process(89, uid: 0), process(501, uid: 501), process(90, uid: 0)]
        let usage: [Int32: ForeignProcessUsage] = [
            88: ForeignProcessUsage(uid: 88, cpuLoad: 0.2, residentBytes: 4_096),
            89: ForeignProcessUsage(uid: 501, cpuLoad: 0.3, residentBytes: 1),
            501: ForeignProcessUsage(uid: 501, cpuLoad: 0.4, residentBytes: 1),
        ]
        let filled = snapshot.fillingForeignUsage(usage, currentUID: 501).processes
        #expect(filled.map(\.cpuLoad) == [0.2, nil, nil, nil])
        #expect(filled[0].memoryBytes == 4_096)
        #expect(filled[0].diskReadPerSecond == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ForeignProcessUsageModelTests {
    private static let command = "/bin/ps -axo pid=,uid=,pcpu=,rss="

    private struct ConditionTimedOut: Error {}

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ConditionTimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Wartet nach der ersten Messung, bis der Test stoppt.
    private func model(_ runner: MockCommandRunner) -> ForeignProcessUsageModel {
        ForeignProcessUsageModel(runner: runner, coreCount: 2, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
    }

    @Test func measuresWhileStartedWithFixedLocale() async throws {
        let runner = MockCommandRunner([Self.command: CommandResult(exitCode: 0, stdout: "88 88 50.0 2\n")])
        let model = model(runner)
        model.start()
        try await eventually { !model.usage.isEmpty }
        #expect(model.usage[88] == ForeignProcessUsage(uid: 88, cpuLoad: 0.25, residentBytes: 2_048))
        #expect(runner.recordedEnvironments == [["LC_ALL": "C"]])
        model.stop()
        #expect(model.usage.isEmpty)
        #expect(!model.isRunning)
    }

    @Test func failingPSLeavesUsageEmpty() async throws {
        let runner = MockCommandRunner()
        let model = model(runner)
        model.start()
        try await eventually { runner.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.usage.isEmpty)
        model.stop()
    }
}
