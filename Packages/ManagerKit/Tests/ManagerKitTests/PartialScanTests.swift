import Testing
import Foundation
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1)))
struct PartialScanTests {
    private let agent = TestData.item("com.example.agent", source: .launchd)
    private let listener = TestData.listener()

    @Test func partialScanCollectsOnlySelectedSources() async throws {
        let newItem = TestData.item("com.example.new")
        let launchd = CountingSource(.launchd, .success(InventoryContribution(autostartItems: [newItem])))
        let listeners = CountingSource(.networkListeners, .success(InventoryContribution(networkListeners: [listener])))
        let btmError = SourceError(source: .btm, message: "kaputt")
        let previous = TestData.networkSnapshot([], items: [agent], errors: [btmError], baseline: TestData.allSources)

        let snapshot = try await ScanCoordinator(sources: [launchd, listeners], currentUID: 501,
                                                 now: { TestData.date + 60 })
            .scan(previous: previous, only: [.networkListeners])

        #expect(launchd.callCount == 0)
        #expect(listeners.callCount == 1)
        #expect(snapshot.takenAt == TestData.date + 60)
        #expect(snapshot.autostartItems == [agent])
        #expect(snapshot.sourceErrors == [btmError])
        #expect(snapshot.networkListeners == [listener])
        #expect(snapshot.baselineSources == TestData.allSources.union([.networkListeners]))
    }

    @Test func partialScanWithoutPreviousScansEverything() async throws {
        let launchd = CountingSource(.launchd, .success(InventoryContribution(autostartItems: [agent])))
        let listeners = CountingSource(.networkListeners, .success(InventoryContribution(networkListeners: [listener])))

        let snapshot = try await ScanCoordinator(sources: [launchd, listeners], currentUID: 501, now: { TestData.date })
            .scan(previous: nil, only: [.networkListeners])

        #expect(launchd.callCount == 1)
        #expect(listeners.callCount == 1)
        #expect(snapshot.autostartItems == [agent])
        #expect(snapshot.networkListeners == [listener])
    }

    /// Jedes Ergebnis landet bei seiner Quelle, auch wenn nur ein Teil der Quellen läuft (Index in `sources` vs.
    /// Position in der Auswahl).
    @Test func partialScanAttributesOutcomesToTheirSources() async throws {
        let grant = TestData.grant()
        let tcc = CountingSource(.tccUser, .success(InventoryContribution(grants: [grant])))
        let newItem = TestData.item("com.example.new")
        let launchd = CountingSource(.launchd, .success(InventoryContribution(autostartItems: [newItem])))
        let btm = CountingSource(.btm, .failure(CountingSource.Failure()))
        let listeners = CountingSource(.networkListeners, .success(InventoryContribution(networkListeners: [listener])))
        let previous = TestData.networkSnapshot([], items: [agent])

        let snapshot = try await ScanCoordinator(sources: [tcc, launchd, btm, listeners], currentUID: 501,
                                                 now: { TestData.date + 60 })
            .scan(previous: previous, only: [.tccUser, .btm, .networkListeners])

        #expect([tcc, launchd, btm, listeners].map(\.callCount) == [1, 0, 1, 1])
        #expect(snapshot.grants == [grant])
        #expect(snapshot.autostartItems == [agent])
        #expect(snapshot.networkListeners == [listener])
        #expect(snapshot.sourceErrors == [SourceError(source: .btm, message: "kaputt")])
    }

    /// Review Task 5: Der Merker laufender Quellen gilt je Index in `sources`. Hängt eine andere Quelle (Index 0) nach
    /// ihrer Frist, läuft der Teilscan der Lauscher trotzdem – mit dem Index der Auswahl würde er fälschlich als
    /// „läuft noch“ gelten.
    @Test func partialScanIsNotBlockedByAnotherHangingSource() async throws {
        let latch = Latch()
        defer { latch.release() }
        let launchd = CountingSource(.launchd, latch: latch)
        let listeners = CountingSource(.networkListeners, .success(InventoryContribution(networkListeners: [listener])))
        let coordinator = ScanCoordinator(sources: [launchd, listeners], sourceTimeout: .milliseconds(200),
                                          currentUID: 501, now: { TestData.date })

        let full = try await coordinator.scan()
        #expect(full.sourceErrors.map(\.source) == [.launchd])

        let partial = try await coordinator.scan(previous: full, only: [.networkListeners])
        #expect(listeners.callCount == 2)
        #expect(partial.networkListeners == [listener])
        #expect(partial.sourceErrors.map(\.source) == [.launchd])
        #expect(partial.sourceErrors.first?.message != ScanCoordinator.stillRunningMessage)
    }

    /// Umgekehrt: Hängt die Lauscher-Quelle nach einem Vollscan noch, fragt ein Teilscan sie nicht gleichzeitig erneut.
    @Test func partialScanDoesNotRestartASourceStillRunningFromAFullScan() async throws {
        let latch = Latch()
        defer { latch.release() }
        let launchd = CountingSource(.launchd, .success(InventoryContribution(autostartItems: [agent])))
        let listeners = CountingSource(.networkListeners, latch: latch)
        let coordinator = ScanCoordinator(sources: [launchd, listeners], sourceTimeout: .milliseconds(200),
                                          currentUID: 501, now: { TestData.date })

        let full = try await coordinator.scan()
        #expect(full.sourceErrors.map(\.source) == [.networkListeners])

        let partial = try await coordinator.scan(previous: full, only: [.networkListeners])
        #expect(listeners.callCount == 1)
        #expect(launchd.callCount == 1)
        #expect(partial.sourceErrors == [
            SourceError(source: .networkListeners, message: ScanCoordinator.stillRunningMessage),
        ])
        #expect(partial.autostartItems == [agent])
    }

    /// Die Kette nach dem Sammeln (Fortschreiben, Neubewertung der Ampel, App-Zustand, Entprellung) ist mit dem aus
    /// `previous` übernommenen Zustand idempotent: Ändert sich bei den Lauschern nichts, ist der Teilscan äquivalent,
    /// und alle übrigen Einträge bleiben unverändert.
    @Test func unchangedListenerPartialScanIsEquivalent() async throws {
        let app = TestData.installedApp()
        let update = TestData.update("A", firstSeenAt: TestData.date - 3 * TestData.day)
        let checks = [
            TestData.evaluatedCheck(TestData.firewallOn),
            TestData.evaluatedCheck(.pendingUpdates(updates: [update], lastCheck: TestData.date)),
        ]
        let foreign = TestData.listener("/usr/sbin/sshd", uid: 0, port: 22)
        let previousScan = TestData.networkSnapshot([foreign], items: [agent], baseline: TestData.networkSources)
        let sources: [any InventorySource] = [
            CountingSource(.launchd, .success(InventoryContribution(autostartItems: [agent]))),
            CountingSource(.btm, .failure(CountingSource.Failure())),
            CountingSource(.securityPosture, .success(InventoryContribution(securityChecks: checks))),
            CountingSource(.apps, .success(InventoryContribution(installedApps: [app],
                                                                 incompleteFolders: ["/Applications/Locked"]))),
            CountingSource(.networkListeners, .success(InventoryContribution(networkListeners: [listener]))),
        ]
        let full = try await ScanCoordinator(sources: sources, currentUID: 501, now: { TestData.date })
            .scan(previous: previousScan)

        let partial = try await ScanCoordinator(sources: sources, currentUID: 501, now: { TestData.date + 60 })
            .scan(previous: full, only: [.networkListeners])

        #expect(partial.isEquivalent(to: full))
        #expect(partial.takenAt == TestData.date + 60)
        #expect(partial.autostartItems == full.autostartItems)
        #expect(partial.securityChecks == full.securityChecks)
        #expect(partial.installedApps == full.installedApps)
        #expect(partial.sourceErrors == full.sourceErrors)
        #expect(partial.sourceLimitations == full.sourceLimitations)
        #expect(partial.baselineSources == full.baselineSources)
        #expect(Set(partial.networkListeners) == Set(full.networkListeners))
    }

    /// Jede Eintragsart ist befüllt: Fehlt eine in `removingRecords`, bliebe sie hier stehen.
    @Test func removingRecordsDropsOnlyGivenSources() {
        let check = TestData.evaluatedCheck(TestData.firewallOn)
        var snapshot = Snapshot(
            takenAt: TestData.date, grants: [TestData.grant()], autostartItems: [TestData.item()],
            securityChecks: [check], installedApps: [TestData.installedApp()], networkListeners: [TestData.listener()],
            mcpServers: [TestData.mcpServer()], agentAutoApprovals: [TestData.autoApproval()],
            sourceErrors: [SourceError(source: .networkListeners, message: "x"),
                           SourceError(source: .btm, message: "w")],
            sourceLimitations: [SourceLimitation(source: .networkListeners, message: "y"),
                                SourceLimitation(source: .launchd, message: "z")],
            baselineSources: TestData.networkSources
        )
        let all: Set<SourceID> = [TestData.grant().source, .launchd, check.source, .apps, .networkListeners, .agents]

        let removed = snapshot.removingRecords(of: [.networkListeners])
        #expect(removed.networkListeners.isEmpty)
        #expect(removed.sourceErrors == [SourceError(source: .btm, message: "w")])
        #expect(removed.sourceLimitations == [SourceLimitation(source: .launchd, message: "z")])
        #expect(removed.grants == snapshot.grants)
        #expect(removed.autostartItems == snapshot.autostartItems)
        #expect(removed.securityChecks == snapshot.securityChecks)
        #expect(removed.installedApps == snapshot.installedApps)
        #expect(removed.mcpServers == snapshot.mcpServers && !removed.mcpServers.isEmpty)
        #expect(removed.agentAutoApprovals == snapshot.agentAutoApprovals && !removed.agentAutoApprovals.isEmpty)
        #expect(removed.baselineSources == snapshot.baselineSources)

        let withoutAgents = snapshot.removingRecords(of: [.agents])
        #expect(withoutAgents.mcpServers.isEmpty && withoutAgents.agentAutoApprovals.isEmpty)
        #expect(withoutAgents.networkListeners == snapshot.networkListeners)

        snapshot = snapshot.removingRecords(of: all)
        #expect(snapshot.grants.isEmpty && snapshot.autostartItems.isEmpty && snapshot.securityChecks.isEmpty
            && snapshot.installedApps.isEmpty && snapshot.networkListeners.isEmpty
            && snapshot.mcpServers.isEmpty && snapshot.agentAutoApprovals.isEmpty)
    }

    @Test func reasonsMerge() {
        #expect(ScanReason.sourceRefresh([.networkListeners]).merging(.interval) == .interval)
        #expect(ScanReason.interval.merging(.sourceRefresh([.networkListeners])) == .interval)
        #expect(ScanReason.sourceRefresh([.networkListeners]).merging(.sourceRefresh([.apps]))
            == .sourceRefresh([.networkListeners, .apps]))
        #expect(ScanReason.manual.merging(.launch) == .launch)
    }

    @Test func refreshedSourcesAreNilForFullScans() {
        #expect(ScanReason.sourceRefresh([.networkListeners]).refreshedSources == [.networkListeners])
        #expect(ScanReason.interval.refreshedSources == nil)
        #expect(ScanReason.fileChange(path: "/a").refreshedSources == nil)
    }
}
