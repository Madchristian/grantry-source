import Foundation
import Testing
@testable import ManagerKit

/// Verlauf der Task-Manager-Aktionen (TM-9.5): Ablage, Texte, Filter, keine Benachrichtigung.
@Suite struct TaskActionHistoryTests {
    private static let killed = TaskActionRecord(action: .forceTerminate, processName: "agent", pid: 4242,
                                                 userName: "root", outcome: .done)
    private static let failedPriority = TaskActionRecord(action: .setPriority(.high), processName: "agent", pid: 4242,
                                                         userName: "root", outcome: .failed("Admin-Bestätigung abgebrochen – nichts geändert"))

    @Test func storeKeepsActionAsReadEventWithoutTouchingSnapshot() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        try await store.record(Self.killed, at: Date(timeIntervalSince1970: 100))
        let events = try await store.events(limit: 10)
        #expect(events.map(\.event.subject) == [.taskAction(Self.killed)])
        #expect(events.first?.isRead == true)
        #expect(try await store.unreadCount() == 0)
        #expect(try await store.latestSnapshot() == nil)
    }

    @Test func descriptionsNameProcessUserAndResult() {
        let done = ChangeDescription(Self.killed.event(at: .now))
        #expect(done.title == "Prozess sofort beendet")
        #expect(done.body == "„agent“ (PID 4242, Benutzer root).")
        let failed = ChangeDescription(Self.failedPriority.event(at: .now))
        #expect(failed.title == "Priorität geändert – gescheitert")
        #expect(failed.body == "„agent“ (PID 4242, Benutzer root) auf „Hoch“: Admin-Bestätigung abgebrochen – nichts geändert")
    }

    /// Dienste stehen unter ihrem Label und ohne PID (jeder Start vergibt eine neue) im Verlauf.
    @Test func serviceActionsNameLabelAndUserWithoutPID() {
        let started = TaskActionRecord(action: .startService, processName: "com.example.agent", pid: nil,
                                       userName: "mara", outcome: .done)
        let startedText = ChangeDescription(started.event(at: .now))
        #expect(startedText.title == "Dienst gestartet")
        #expect(startedText.body == "„com.example.agent“ (Benutzer mara).")
        let stopFailed = TaskActionRecord(action: .stopService, processName: "com.example.agent", pid: nil,
                                          userName: "mara", outcome: .failed("Der Dienst läuft nicht."))
        let failedText = ChangeDescription(stopFailed.event(at: .now))
        #expect(failedText.title == "Dienst gestoppt – gescheitert")
        #expect(failedText.body == "„com.example.agent“ (Benutzer mara): Der Dienst läuft nicht.")
    }

    @Test func serviceRecordsRoundTripAsJSONAndStayInTheTaskManagerFilter() throws {
        let record = TaskActionRecord(action: .stopService, processName: "com.example.agent", pid: nil, userName: "mara",
                                      outcome: .done)
        let data = try JSONEncoder().encode(record.event(at: Date(timeIntervalSince1970: 5)))
        #expect(try JSONDecoder().decode(ChangeEvent.self, from: data).subject == .taskAction(record))
        let event = HistoryEvent(id: UUID(), event: record.event(at: .now), isRead: true)
        #expect(HistoryFilter(category: .taskManager).matches(event, now: .now))
        #expect(!NotificationPolicy().shouldNotify(record.event(at: .now)))
    }

    @Test func historyFilterHasTaskManagerCategory() {
        let event = HistoryEvent(id: UUID(), event: Self.killed.event(at: .now), isRead: true)
        #expect(HistoryFilter(category: .taskManager).matches(event, now: .now))
        #expect(!HistoryFilter(category: .network).matches(event, now: .now))
        #expect(HistoryFilter.Category.taskManager.displayName == "Task-Manager")
    }

    @Test func ownActionsDoNotNotify() {
        let event = Self.killed.event(at: .now)
        #expect(!NotificationPolicy().shouldNotify(event))
        #expect(NotificationDestination(for: event) == .history)
    }

    @Test func recordRoundTripsAsJSON() throws {
        let data = try JSONEncoder().encode(Self.failedPriority.event(at: Date(timeIntervalSince1970: 5)))
        #expect(try JSONDecoder().decode(ChangeEvent.self, from: data).subject == .taskAction(Self.failedPriority))
    }

    /// Je fremdem Prozess ein Eintrag mit Ergebnis; eigene Prozesse nicht.
    @Test func terminationRecordsOnlyForeignProcesses() {
        let root = RunningProcess(pid: 1, uid: 0, executablePath: "/usr/sbin/a", startTime: 1)
        let other = RunningProcess(pid: 2, uid: 88, executablePath: "/usr/sbin/b", startTime: 1)
        let own = RunningProcess(pid: 3, uid: 501, executablePath: "/usr/bin/c", startTime: 1)
        let result = TaskTerminationResult(
            request: TaskTerminationRequest(name: "x", processes: [root, other, own]), force: false, outcome: .done,
            report: ProcessTerminationReport(ended: [own], stillRunning: [other],
                                             failures: [ProcessTerminationFailure(process: root, message: "abgelehnt")])
        )
        let records = TaskActionRecord.terminations(of: result, currentUID: 501, userName: { "u\($0)" })
        #expect(records.map(\.pid) == [1, 2])
        #expect(records.map(\.outcome) == [.failed("abgelehnt"), .failed("läuft noch")])
        #expect(records.map(\.userName) == ["u0", "u88"])
    }
}
