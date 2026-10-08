import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct StandardSourcesTests {
    private struct StubProvider: BTMDumpProviding {
        func dumpBTM() async throws -> String { "" }
    }

    private final class CountingSocketProvider: ListeningSocketProviding {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }

        func listeningSockets() async throws -> ListeningSocketScan {
            count.withLock { $0 += 1 }
            return ListeningSocketScan(sockets: [])
        }
    }

    @Test func v1ScansSystemTCCLaunchdAndBTM() {
        let sources = StandardSources.v1(
            btmProvider: StubProvider(), resolver: StubAppResolver(), fingerprinter: .ephemeral(), runner: MockCommandRunner()
        )
        #expect(sources.map(\.id) == [.tccSystem, .launchd, .btm])
    }

    @Test func tccStandardDefaultsToSystemOnly() {
        #expect(TCCSource.standard(resolver: StubAppResolver()).map(\.id) == [.tccSystem])
        #expect(TCCSource.standard(resolver: StubAppResolver(), includeUserDatabase: true).map(\.id) == [.tccUser, .tccSystem])
    }

    @Test func v2AddsSecurityPosture() {
        let sources = StandardSources.v2(
            btmProvider: StubProvider(), resolver: StubAppResolver(), fingerprinter: .ephemeral(), runner: MockCommandRunner()
        )
        #expect(sources.map(\.id) == [.tccSystem, .launchd, .btm, .securityPosture])
    }

    @Test func v3AddsTheAppInventory() {
        let sources = StandardSources.v3(
            btmProvider: StubProvider(), resolver: StubAppResolver(), fingerprinter: .ephemeral(),
                runner: MockCommandRunner(),
            apps: AppInventorySource(roots: [])
        )
        #expect(sources.map(\.id) == [.tccSystem, .launchd, .btm, .securityPosture, .apps])
    }

    /// Nur Benutzerdateien eines leeren Homes – der Test liest keine echten Konfigurationen.
    @Test func v4AddsAgentConfigurations() throws {
        try ScratchDirectory.with { home in
            let sources = StandardSources.v4(
                btmProvider: StubProvider(), resolver: StubAppResolver(), fingerprinter: .ephemeral(),
                runner: MockCommandRunner(),
                apps: AppInventorySource(roots: []), agents: Self.agentSource(home: home)
            )
            #expect(sources.map(\.id) == [.tccSystem, .launchd, .btm, .securityPosture, .apps, .agents])
        }
    }

    @Test func v5AddsNetworkListeners() throws {
        try ScratchDirectory.with { home in
            let sources = StandardSources.v5(
                btmProvider: StubProvider(), resolver: StubAppResolver(), sockets: nil,
                fingerprinter: .ephemeral(), runner: MockCommandRunner(),
                apps: AppInventorySource(roots: []), agents: Self.agentSource(home: home)
            )
            #expect(sources.map(\.id) == [.tccSystem, .launchd, .btm, .securityPosture, .apps, .agents, .networkListeners])
        }
    }

    /// Die Lauscher-Quelle nutzt den übergebenen Takt: Nach `reset()` fragt sie den Helper sofort wieder.
    @Test func v5UsesTheGivenListenerSchedule() async throws {
        try await ScratchDirectory.with { home in
            let sockets = CountingSocketProvider()
            let schedule = ListenerHelperSchedule()
            let sources = StandardSources.v5(
                btmProvider: StubProvider(), resolver: StubAppResolver(), sockets: sockets,
                fingerprinter: .ephemeral(), runner: MockCommandRunner(),
                apps: AppInventorySource(roots: []), agents: Self.agentSource(home: home), listenerSchedule: schedule
            )
            let listeners = try #require(sources.first { $0.id == .networkListeners })
            _ = try await listeners.collect()
            schedule.reset()
            _ = try await listeners.collect()
            #expect(sockets.calls == 2)
        }
    }

    private static func agentSource(home: URL) -> AgentConfigSource {
        AgentConfigSource(catalog: TestData.userCatalog, home: home.path, inspector: RecordingSigningInspector(result: .unknown))
    }

    /// Der Sicherheitsstatus bewertet mit der Uhr, die auch der `ScanCoordinator` bekommt.
    @Test func v2EvaluatesSecurityWithGivenClock() async throws {
        let runner = MockCommandRunner([
            "/usr/bin/xprotect version --json": CommandResult(exitCode: 0, stdout: try securityFixture("xprotect-version.json")),
        ])
        let installedAt = try #require(ISO8601DateFormatter().date(from: "2026-09-29T20:53:25Z"))
        let staleNow = installedAt.addingTimeInterval(40 * 86_400)
        let sources = StandardSources.v2(
            btmProvider: StubProvider(), resolver: StubAppResolver(), fingerprinter: .ephemeral(), runner: runner, now: { staleNow }
        )
        let security = try #require(sources.first { $0.id == .securityPosture })
        let xprotect = try await security.collect().securityChecks.first { $0.kind == .xprotect }
        #expect(xprotect?.state == .critical)
    }
}
