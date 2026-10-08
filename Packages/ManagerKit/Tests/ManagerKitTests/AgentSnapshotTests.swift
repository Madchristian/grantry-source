import Foundation
import Testing
@testable import ManagerKit

@Suite struct AgentSnapshotTests {
    let differ = SnapshotDiffer()
    let later = TestData.date.addingTimeInterval(60)

    @Test func olderSnapshotsDecodeWithoutAgentFields() throws {
        let old = TestData.snapshot(grants: [TestData.grant()])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "mcpServers")
        json.removeValue(forKey: "agentAutoApprovals")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.mcpServers.isEmpty)
        #expect(decoded.agentAutoApprovals.isEmpty)
        #expect(decoded.grants == old.grants)
    }

    @Test func agentFieldsRoundTrip() throws {
        let snapshot = TestData.agentSnapshot([TestData.mcpServer()], approvals: [TestData.autoApproval()])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func firstDeliveryIsBaseline() {
        let previous = TestData.snapshot()   // Quelle `.agents` noch nicht in der Baseline
        let current = TestData.agentSnapshot([TestData.mcpServer()], approvals: [TestData.autoApproval()], at: later)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func entriesDeriveTheirBaseline() {
        let snapshot = Snapshot(takenAt: TestData.date, grants: [], autostartItems: [], mcpServers: [TestData.mcpServer()],
                                sourceErrors: [])
        #expect(snapshot.baselineSources == [.agents])
    }

    @Test func reportsAddedModifiedRemoved() {
        let kept = TestData.mcpServer("kept")
        let changed = TestData.mcpServer("changed")
        var changedAfter = changed
        changedAfter.transport = .local(command: "npx", arguments: ["pkg@2.0.0"])
        let previous = TestData.agentSnapshot([kept, changed, TestData.mcpServer("gone")])
        let current = TestData.agentSnapshot([kept, changedAfter, TestData.mcpServer("new")],
                                             approvals: [TestData.autoApproval()], at: later)
        let events = differ.diff(from: previous, to: current)
        #expect(Set(events.map { "\($0.kind.rawValue):\($0.subject.recordID)" }) == [
            "modified:\(changed.id)", "removed:\(TestData.mcpServer("gone").id)", "added:\(TestData.mcpServer("new").id)",
            "added:\(TestData.autoApproval().id)",
        ])
    }

    @Test func failedSourceKeepsEntries() {
        let server = TestData.mcpServer()
        let previous = TestData.agentSnapshot([server])
        let failed = TestData.agentSnapshot([], errors: [SourceError(source: .agents, message: "x")], at: later)
            .carryingForwardRecords(ofFailedSourcesFrom: previous)
        #expect(failed.mcpServers == [server])
        #expect(differ.diff(from: previous, to: failed).isEmpty)
    }

    @Test func unreadableFileCarriesItsEntriesForward() {
        let fromBroken = TestData.mcpServer("a", configPath: "/h/.cursor/mcp.json")
        let fromProject = TestData.mcpServer("b", configPath: "/p/.mcp.json", scope: .project(path: "/p"),
                                             registryPath: "/h/.claude.json")
        let other = TestData.mcpServer("c", configPath: "/h/other.json")
        let previous = TestData.agentSnapshot([fromBroken, fromProject, other])
        let current = TestData.agentSnapshot([], at: later)
            .carryingForwardAgents(inIncompleteFiles: ["/h/.cursor/mcp.json", "/h/.claude.json"], from: previous)
        #expect(Set(current.mcpServers.map(\.id)) == [fromBroken.id, fromProject.id])
    }

    @Test func sameNameFromAnotherFileDoesNotBlockCarryForward() {
        let fromBroken = TestData.mcpServer("a", configPath: "/h/.cursor/mcp.json")
        let fromOther = TestData.mcpServer("a", configPath: "/h/other.json")
        let previous = TestData.agentSnapshot([fromBroken, fromOther])
        let current = TestData.agentSnapshot([fromOther], at: later)
            .carryingForwardAgents(inIncompleteFiles: ["/h/.cursor/mcp.json"], from: previous)
        #expect(Set(current.mcpServers.map(\.id)) == [fromBroken.id, fromOther.id])
        #expect(current.mcpServers.count == 2)
    }

    @Test func unreadableFileCarriesApprovalsForwardOnce() {
        let approval = TestData.autoApproval()
        let previous = TestData.agentSnapshot([], approvals: [approval])
        let current = TestData.agentSnapshot([], approvals: [approval], at: later)
            .carryingForwardAgents(inIncompleteFiles: [approval.configPath], from: previous)
        #expect(current.agentAutoApprovals == [approval])
    }

    /// Ist `~/.claude.json` unlesbar, liest der Scan auch die Projekt-Einstellungsdateien nicht: deren Freigaben werden
    /// über `registryPath` fortgeschrieben – ohne Ereignis.
    @Test func unreadableRegistryCarriesProjectApprovalsForward() {
        let fromProject = TestData.autoApproval(configPath: "/p/.claude/settings.json", registryPath: "/h/.claude.json",
                                                scope: .project(path: "/p"))
        let fromUser = TestData.autoApproval(configPath: "/h/.claude/settings.json")
        let previous = TestData.agentSnapshot([], approvals: [fromProject, fromUser])
        let current = TestData.agentSnapshot([], approvals: [fromUser], at: later)
            .carryingForwardAgents(inIncompleteFiles: ["/h/.claude.json"], from: previous)
        #expect(Set(current.agentAutoApprovals.map(\.id)) == [fromProject.id, fromUser.id])
        #expect(current.agentAutoApprovals.count == 2)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func equivalenceConsidersAgents() {
        let base = TestData.agentSnapshot([TestData.mcpServer()])
        #expect(base.isEquivalent(to: TestData.agentSnapshot([TestData.mcpServer()], at: later)))
        #expect(!base.isEquivalent(to: TestData.agentSnapshot([TestData.mcpServer(isEnabled: false)], at: later)))
        #expect(!base.isEquivalent(to: TestData.agentSnapshot([TestData.mcpServer()], approvals: [TestData.autoApproval()])))
    }

    @Test func scanCoordinatorCollectsAgentContribution() async throws {
        let server = TestData.mcpServer()
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .agents, result: .success(InventoryContribution(agents: AgentContribution(mcpServers: [server], agentAutoApprovals: [TestData.autoApproval()])))),
        ])
        let snapshot = try await coordinator.scan()
        #expect(snapshot.mcpServers == [server])
        #expect(snapshot.agentAutoApprovals == [TestData.autoApproval()])
        #expect(snapshot.baselineSources.contains(.agents))
    }

    @Test func scanCoordinatorCarriesEntriesOfIncompleteFilesForward() async throws {
        let server = TestData.mcpServer()
        let previous = TestData.agentSnapshot([server])
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .agents, result: .success(InventoryContribution(agents: AgentContribution(incompleteFiles: [server.configPath])))),
        ])
        let snapshot = try await coordinator.scan(previous: previous)
        #expect(snapshot.mcpServers == [server])
    }
}
