import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct NotificationDestinationTests {
    private func event(_ kind: ChangeEvent.Kind, _ subject: ChangeSubject) -> ChangeEvent {
        TestData.historyEvent(kind, subject).event
    }

    @Test func securityCheckEventLeadsToItsCheck() {
        let check = TestData.securityCheck(TestData.firewallOff, state: .critical)
        #expect(NotificationDestination(for: event(.modified, .securityCheck(check))) == .securityCheck(.firewall))
    }

    @Test func everyCheckKindKeepsItsKind() {
        for kind in SecurityCheckKind.allCases {
            let check = SecurityCheck(kind: kind, state: .warning, facts: nil)
            #expect(NotificationDestination(for: event(.modified, .securityCheck(check))) == .securityCheck(kind))
        }
    }

    @Test func removedCheckLeadsToHistory() {
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        #expect(NotificationDestination(for: event(.removed, .securityCheck(check))) == .history)
    }

    @Test func grantAndAutostartEventsLeadToHistory() {
        #expect(NotificationDestination(for: event(.added, .autostartItem(TestData.item("com.example.agent")))) == .history)
        #expect(NotificationDestination(for: event(.modified, .grant(TestData.grant()))) == .history)
    }

    @Test func userInfoRoundTrips() {
        for destination in [NotificationDestination.history] + SecurityCheckKind.allCases.map(NotificationDestination.securityCheck) {
            #expect(NotificationDestination(userInfo: destination.userInfo) == destination)
        }
    }

    @Test func userInfoWithoutAReadableDestinationYieldsNil() {
        #expect(NotificationDestination(userInfo: [:]) == nil)
        #expect(NotificationDestination(userInfo: ["other": "history"]) == nil)
        #expect(NotificationDestination(userInfo: ["destination": 42]) == nil)
        #expect(NotificationDestination(userInfo: ["destination": "securityCheck:unbekannt"]) == nil)
        #expect(NotificationDestination(userInfo: ["destination": "securityCheck:"]) == nil)
        #expect(NotificationDestination(userInfo: ["destination": "installedApp:"]) == nil)
        #expect(NotificationDestination(userInfo: ["destination": "settings"]) == nil)
    }

    @Test func appEventsLeadToTheApp() {
        let app = TestData.installedApp()
        let added = ChangeEvent(kind: .added, before: nil, after: .installedApp(app), detectedAt: TestData.date)
        let removed = ChangeEvent(kind: .removed, before: .installedApp(app), after: nil, detectedAt: TestData.date)
        #expect(NotificationDestination(for: added) == .installedApp(app.id))
        #expect(NotificationDestination(for: removed) == .history)
        #expect(NotificationDestination(userInfo: NotificationDestination.installedApp(app.id).userInfo) == .installedApp(app.id))
    }

    @Test func agentEventsOpenTheEntry() {
        let server = TestData.mcpServer()
        let added = ChangeEvent(kind: .added, before: nil, after: .mcpServer(server), detectedAt: TestData.date)
        #expect(NotificationDestination(for: added) == .agent(server.id))
        let removed = ChangeEvent(kind: .removed, before: .mcpServer(server), after: nil, detectedAt: TestData.date)
        #expect(NotificationDestination(for: removed) == .history)
        #expect(NotificationDestination(userInfo: NotificationDestination.agent(server.id).userInfo) == .agent(server.id))
        let approval = TestData.autoApproval()
        let approvalAdded = ChangeEvent(kind: .added, before: nil, after: .agentAutoApproval(approval), detectedAt: TestData.date)
        #expect(NotificationDestination(for: approvalAdded) == .agent(approval.id))
        let approvalRemoved = ChangeEvent(kind: .removed, before: .agentAutoApproval(approval), after: nil, detectedAt: TestData.date)
        #expect(NotificationDestination(for: approvalRemoved) == .history)
        #expect(NotificationDestination(userInfo: ["destination": "agent:"]) == nil)
    }

    @Test func updateDestinationRoundTrips() {
        #expect(NotificationDestination(userInfo: NotificationDestination.update.userInfo) == .update)
    }

    @Test func listenerEventsLeadToTheListener() {
        let listener = TestData.listener()
        let added = ChangeEvent(kind: .added, before: nil, after: .networkListener(listener), detectedAt: TestData.date)
        let removed = ChangeEvent(kind: .removed, before: .networkListener(listener), after: nil, detectedAt: TestData.date)
        #expect(NotificationDestination(for: added) == .networkListener(listener.id))
        #expect(NotificationDestination(for: removed) == .history)
        let destination = NotificationDestination.networkListener(listener.id)
        #expect(NotificationDestination(userInfo: destination.userInfo) == destination)
        #expect(NotificationDestination(userInfo: ["destination": "networkListener:"]) == nil)
    }
}
