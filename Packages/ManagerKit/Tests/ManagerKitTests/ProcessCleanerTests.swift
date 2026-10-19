import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ProcessCleanerTests {
    private typealias F = ProcessFixture

    /// Prozesstabelle, die je Aufruf den nächsten Stand liefert (danach den letzten).
    private final class SequencedTable: ProcessTableReading {
        private let states: Mutex<[[ProcessEntry]]>
        init(_ states: [[ProcessEntry]]) { self.states = Mutex(states) }
        func entries() throws -> [ProcessEntry] {
            states.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? [] }
        }
    }

    /// Protokolliert Signale; `surviving` überlebt SIGTERM.
    private final class RecordingTerminator: ProcessListTerminating {
        let calls = Mutex<[(pids: [pid_t], force: Bool)]>([])
        let surviving: Set<pid_t>
        init(surviving: Set<pid_t> = []) { self.surviving = surviving }
        func terminate(_ processes: [RunningProcess], force: Bool) async -> ProcessTerminationReport {
            calls.withLock { $0.append((processes.map(\.pid), force)) }
            let survivors = force ? [] : processes.filter { surviving.contains($0.pid) }
            return ProcessTerminationReport(ended: processes.filter { !survivors.contains($0) }, stillRunning: survivors)
        }
    }

    private func cleaner(_ states: [[ProcessEntry]], terminator: RecordingTerminator = RecordingTerminator(),
                         runner: MockCommandRunner = MockCommandRunner()) -> ProcessCleaner {
        ProcessCleaner(table: SequencedTable(states), detector: F.detector, terminator: terminator, runner: runner)
    }

    private func scannedTree() throws -> AgentProcessTree {
        try #require(F.detector.scan(F.brokerTree()).orphans.first)
    }

    @Test func terminatesFreshlyConfirmedMembersRootFirst() async throws {
        let tree = try scannedTree()
        let terminator = RecordingTerminator()
        // Seit dem Scan ist ein weiterer MCP-Server dazugekommen: Er gehört zum Baum und wird mit beendet.
        let fresh = F.brokerTree() + [F.entry(105, parent: 102, ["/opt/homebrew/bin/node", "/x/new-mcp"])]
        let outcome = await cleaner([fresh], terminator: terminator).terminate(tree)
        #expect(outcome.result == .removed)
        #expect(terminator.calls.withLock { $0.map(\.pids) } == [[100, 101, 102, 103, 104, 105]])
        #expect(terminator.calls.withLock { $0.map(\.force) } == [false])
        #expect(outcome.survivors.isEmpty)
    }

    @Test func treeAdoptedBySessionSinceScanIsSkipped() async throws {
        let tree = try scannedTree()
        let terminator = RecordingTerminator()
        let fresh = F.brokerTree() + [F.claudeSession(300, cwd: "/Users/me/project")]
        let outcome = await cleaner([fresh], terminator: terminator).terminate(tree)
        #expect(outcome.result == .skipped(ProcessCleaner.inUseReason))
        #expect(terminator.calls.withLock { $0.isEmpty })
    }

    /// Codex-Review #221: Auch im Neuscan vor dem Signal gibt eine Sitzung ohne lesbaren Arbeitsordner den Broker nicht frei.
    @Test func sessionWithUnreadableWorkspaceAtSignalTimeSkipsBroker() async throws {
        let tree = try scannedTree()
        let terminator = RecordingTerminator()
        let fresh = F.brokerTree() + [F.entry(300, parent: 50, ["claude"], executable: "/opt/homebrew/bin/claude", cwd: nil)]
        let outcome = await cleaner([fresh], terminator: terminator).terminate(tree)
        #expect(outcome.result == .skipped(ProcessCleaner.inUseReason))
        #expect(terminator.calls.withLock { $0.isEmpty })
    }

    @Test func endedOrReplacedRootIsSkipped() async throws {
        let tree = try scannedTree()
        let terminator = RecordingTerminator()
        // Dieselbe PID, aber neu vergeben (andere Startzeit).
        var replaced = F.brokerTree()
        replaced[0] = F.entry(100, parent: 1, ["/opt/homebrew/bin/node", F.broker, "serve", "--cwd", "/Users/me/project"],
                              leader: true, start: 7)
        for state in [[], replaced] {
            let outcome = await cleaner([state], terminator: terminator).terminate(tree)
            #expect(outcome.result == .skipped(ProcessCleaner.goneReason))
        }
        #expect(terminator.calls.withLock { $0.isEmpty })
    }

    @Test func survivorsAreOfferedForKillOnlyAfterTerm() async throws {
        let tree = try scannedTree()
        let terminator = RecordingTerminator(surviving: [102])
        let cleaner = cleaner([F.brokerTree()], terminator: terminator)
        let outcome = await cleaner.terminate(tree)
        #expect(outcome.survivors.map(\.pid) == [102])
        #expect(outcome.result == .failed("1 Prozess läuft noch."))
        let forced = await cleaner.forceTerminate(outcome)
        #expect(forced.result == .removed)
        #expect(forced.survivors.isEmpty)
        #expect(terminator.calls.withLock { $0.last.map { [$0.pids.map(Int.init), [$0.force ? 1 : 0]] } } == [[102], [1]])
    }

    @Test func logEntryNamesTreeWithoutArguments() throws {
        let tree = try #require(F.detector.scan([
            F.entry(301, parent: 1, ["/opt/homebrew/bin/node", "/x/mcp-server-postgres", "postgres://u:geheim@h/db"]),
        ]).orphans.first)
        let entry = ProcessCleanupOutcome(.tree(tree), .removed).logEntry
        #expect(entry.target == "MCP-Server, PID 301 (1 Prozess)")
        #expect(entry.method == .signal)
        #expect(entry.freedBytes == nil)
        #expect(entry.categoryID == ProcessCleaner.treeCategoryID)
    }

    @Test func shutsDownSimulatorWithOfficialCLI() async {
        let simulator = BootedSimulator(udid: "11111111-2222-3333-4444-555555555555", name: "iPhone", runtime: "iOS 27.0",
                                        bootedAt: nil, memoryBytes: nil, processCount: 0)
        let runner = MockCommandRunner()
        let line = simulator.shutdownCommand.commandLine
        runner.stub(line, CommandResult(exitCode: 0, stdout: ""))
        #expect(await cleaner([], runner: runner).shutdown(simulator).result == .removed)
        #expect(runner.calls == [line])
        #expect(line.hasSuffix("/usr/bin/xcrun simctl shutdown 11111111-2222-3333-4444-555555555555"))
        runner.stub(line, CommandResult(exitCode: 1, stdout: "", stderr: "Unable to shutdown device\nmore"))
        #expect(await cleaner([], runner: runner).shutdown(simulator).result == .failed("simctl: Unable to shutdown device"))
    }

    /// Echt: ein selbst gestarteter Waise (`/bin/sleep` als „…-mcp“, ppid 1, Sitzung der Shell) wird gefunden und mit
    /// den echten Abhängigkeiten beendet (Leitplanke 5: Signale nur an selbst gestartete Prozesse).
    @Test func findsAndEndsRealSelfStartedOrphan() async throws {
        let marker = "grantry-test-\(UUID().uuidString.prefix(8))-mcp"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", "( exec -a /opt/probe/\(marker) /bin/sleep 60 ) >/dev/null 2>&1 &"]
        try shell.run()
        shell.waitUntilExit()
        let detector = OrphanAgentTreeDetector()
        var tree: AgentProcessTree?
        for _ in 0..<40 where tree == nil {
            tree = detector.scan(try LibprocProcessTable().entries()).orphans.first { $0.root.arguments.first?.hasSuffix(marker) == true }
            if tree == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let found = try #require(tree)
        #expect(found.root.parentPID == 1)
        #expect(found.root.executablePath == "/bin/sleep")
        let outcome = await ProcessCleaner().terminate(found)
        #expect(outcome.result == .removed)
        #expect(LibprocProcessInspector().hasEnded(found.root.pid, startedAt: found.root.startTime))
    }
}

@Suite struct BootedSimulatorReaderTests {
    private typealias F = ProcessFixture
    private static let udid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private static let listing = """
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"udid": "\(udid)", "name": "iPhone 17", "state": "Booted"},
        {"udid": "not-a-uuid; rm -rf", "name": "Kaputt", "state": "Booted"}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
        {"udid": "11111111-2222-3333-4444-555555555555", "name": "Watch", "state": "Shutdown"}
      ]
    }}
    """

    @Test func parsesBootedDevicesWithMemoryOfTheirLaunchdSim() throws {
        let entries = [
            F.entry(10, parent: 1, ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/\(Self.udid)/data/var/run/launchd_bootstrap.plist"],
                    executable: "/Library/Developer/CoreSimulator/launchd_sim", memory: 1_000),
            F.entry(11, parent: 10, ["SpringBoard"], memory: 500),
        ]
        let simulators = try BootedSimulatorReader.parse(Data(Self.listing.utf8), entries: entries)
        #expect(simulators.map(\.title) == ["iPhone 17 (iOS 27.0)"])
        #expect(simulators.first?.memoryBytes == 1_500)
        #expect(simulators.first?.processCount == 2)
        #expect(simulators.first?.bootedAt == Date(timeIntervalSince1970: 0.01))
    }

    @Test func withoutLaunchdSimMemoryIsUnknown() throws {
        let simulators = try BootedSimulatorReader.parse(Data(Self.listing.utf8), entries: [])
        #expect(simulators.first?.memoryBytes == nil)
        #expect(simulators.first?.bootedAt == nil)
    }

    @Test func doesNotRunXcrunWithoutSimulatorDevices() async throws {
        let runner = MockCommandRunner()
        let reader = BootedSimulatorReader(runner: runner, home: "/Users/me", isDirectory: { _ in false })
        #expect(try await reader.booted(entries: []).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: [
        ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "iOS 27.0"),
        ("com.apple.CoreSimulator.SimRuntime.visionOS-2-4", "visionOS 2.4"),
        ("weird", "weird"),
    ])
    func runtimeNames(_ identifier: String, _ expected: String) {
        #expect(BootedSimulatorReader.runtimeName(identifier) == expected)
    }
}
