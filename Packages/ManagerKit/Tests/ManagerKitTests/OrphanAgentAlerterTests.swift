import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@MainActor
@Suite struct OrphanAgentAlerterTests {
    private typealias F = ProcessFixture

    /// Liefert je Scan das nächste Ergebnis und zählt die Scans.
    private final class ScriptedScans: Sendable {
        private let results: Mutex<[Result<AgentTreeScan, any Error>]>
        private let calls = Mutex(0)

        init(_ results: [Result<AgentTreeScan, any Error>]) { self.results = Mutex(results) }

        var count: Int { calls.withLock { $0 } }

        func next() throws -> AgentTreeScan {
            calls.withLock { $0 += 1 }
            return try results.withLock { $0.removeFirst() }.get()
        }
    }

    private struct Unreadable: Error {}

    /// Mehr als 4 Bäume oder mehr als 1.000 Bytes; entspannt bei höchstens 2 Bäumen und 500 Bytes.
    private static let threshold = OrphanAgentAlertThreshold(treeCount: 4, memoryBytes: 1_000)

    private let store = InMemorySettingsStore()
    private let notifier = RecordingNotifier()

    private var preferences: OrphanAgentAlertPreferences { OrphanAgentAlertPreferences(store: store) }

    /// `count` Bäume mit je `memory` Bytes.
    private static func scan(_ count: Int, memory: UInt64 = 10) -> Result<AgentTreeScan, any Error> {
        .success(AgentTreeScan(orphans: (0..<count).map { index in
            AgentProcessTree(pattern: AgentProcessCatalog.standard.orphanRoots[0],
                             members: [F.entry(pid_t(100 + index), parent: 1, ["node"], memory: memory)], workspace: nil)
        }, inUseCount: 0))
    }

    /// Prüft je Ergebnis einmal.
    private func run(_ results: [Result<AgentTreeScan, any Error>]) async -> ScriptedScans {
        let scans = ScriptedScans(results)
        let alerter = OrphanAgentAlerter(scan: { try scans.next() }, notifier: notifier, preferences: preferences,
                                         threshold: Self.threshold)
        for _ in results { await alerter.check() }
        return scans
    }

    @Test func notifiesOnceWhenTreeCountIsExceeded() async throws {
        await run([Self.scan(5), Self.scan(6), Self.scan(7)])
        let post = try #require(notifier.all.first)
        #expect(notifier.all.count == 1)
        #expect(post.title == ProcessCleanupPresentation.alertTitle)
        #expect(post.body.hasPrefix("5 verwaiste Agenten-Prozessbäume belegen"))
        #expect(post.identifier == OrphanAgentAlerter.notificationIdentifier)
        #expect(post.destination == .processes)
    }

    @Test func stayingAtTheThresholdIsQuiet() async {
        await run([Self.scan(4, memory: 250)])
        #expect(notifier.all.isEmpty)
    }

    @Test func memoryAloneExceeds() async throws {
        await run([Self.scan(1, memory: 1_001)])
        let post = try #require(notifier.all.first)
        #expect(post.body.hasPrefix("1 verwaister Agenten-Prozessbaum belegt"))
        #expect(post.body.contains("nur nach Bestätigung"))
    }

    @Test func notifiesAgainOnlyAfterTheSituationCleared() async {
        await run([
            Self.scan(5),               // Hinweis
            Self.scan(3),               // unter der Schwelle, aber nicht entspannt
            Self.scan(2, memory: 300),  // wenige Bäume, aber noch zu viel Speicher
            Self.scan(5),               // kein zweiter Hinweis
            Self.scan(2, memory: 250),  // entspannt
            Self.scan(5),               // neuer Hinweis
        ])
        #expect(notifier.all.count == 2)
    }

    @Test func debounceSurvivesARestart() async {
        await run([Self.scan(5)])
        await run([Self.scan(5)])
        #expect(notifier.all.count == 1)
    }

    @Test func switchedOffItDoesNotScanAndMayNotifyRightAfterSwitchingOn() async {
        await run([Self.scan(5)])
        preferences.isEnabled = false
        let scans = await run([Self.scan(5)])
        #expect(scans.count == 0)
        #expect(preferences.isArmed)
        preferences.isEnabled = true
        await run([Self.scan(5)])
        #expect(notifier.all.count == 2)
    }

    @Test func unreadableScanChangesNothing() async {
        await run([.failure(Unreadable()), Self.scan(5)])
        #expect(notifier.all.count == 1)
        await run([.failure(Unreadable())])
        #expect(!preferences.isArmed)
    }

    @Test func enabledByDefault() {
        #expect(preferences.isEnabled)
        #expect(preferences.isArmed)
    }

    @Test func settingNoteNamesIntervalAndThreshold() {
        let note = ProcessCleanupPresentation.alertSettingNote
        #expect(note.contains("alle 15 Minuten"))
        #expect(note.contains("mehr als 10 verwaiste"))
    }

    @Test func backgroundScanReadsOnlyAgentTrees() async throws {
        struct Table: ProcessTableReading {
            func entries() throws -> [ProcessEntry] { F.brokerTree() }
        }
        let scanner = ProcessOverviewScanner(table: Table(), detector: F.detector, simulators: BootedSimulatorReader())
        let scan = try await scanner.scanAgentTrees()
        #expect(scan.orphans.map(\.root.pid) == [100])
    }
}
