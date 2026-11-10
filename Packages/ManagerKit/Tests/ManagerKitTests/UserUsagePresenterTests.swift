import Foundation
import Testing
@testable import ManagerKit

@Suite struct UserUsagePresenterTests {
    private static let names: [UInt32: String] = [501: "mara", 502: "jonas", 0: "root", 88: "_windowserver"]

    private func process(_ pid: Int32, uid: UInt32, cpu: Double?, memory: UInt64?) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: 1, uid: uid, name: "p\(pid)",
                           cpuLoad: cpu, memoryBytes: memory, diskReadPerSecond: nil, diskWritePerSecond: nil,
                           threadCount: nil)
    }

    private func session(_ user: String, _ line: String, host: String? = nil) -> LoginSession {
        LoginSession(user: user, line: line, host: host, loginDate: Date(timeIntervalSince1970: 1_793_000_000))
    }

    private func present(_ processes: [ProcessMeasurement], sessions: [LoginSession],
                         network: [ProcessKey: Double]? = nil) -> UserUsagePresentation {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = processes
        return UserUsagePresenter.present(snapshot, sessions: sessions, currentUID: 501, network: network,
                                          userName: { Self.names[$0] ?? String($0) }, physicalMemory: 16 << 30)
    }

    private var twoUsers: UserUsagePresentation {
        present([process(10, uid: 501, cpu: 0.25, memory: 100), process(11, uid: 501, cpu: 0.5, memory: 50),
                 process(20, uid: 502, cpu: 0.25, memory: 10)],
                sessions: [session("jonas", "ttys004", host: "10.0.0.7"), session("mara", "console")])
    }

    @Test func sumsProcessesPerLoggedInUserCurrentUserFirst() {
        let presentation = twoUsers
        #expect(presentation.rows.map(\.name) == ["mara", "jonas"])
        #expect(presentation.rows.map(\.processCount) == [2, 1])
        #expect(presentation.rows[0].figures.cpuLoad == 0.75)
        #expect(presentation.rows[0].figures.memoryBytes == 150)
        #expect(presentation.rows.map(\.isCurrentUser) == [true, false])
        #expect(presentation.processCount == 3)
    }

    @Test func currentUserAppearsWithoutSession() {
        let presentation = present([process(10, uid: 501, cpu: 0.1, memory: 1)], sessions: [])
        #expect(presentation.rows.map(\.name) == ["mara"])
        #expect(presentation.rows[0].summary == "Keine Anmeldung erfasst")
        #expect(!presentation.rows[0].isExpandable)
    }

    @Test func otherAccountsAreOneRowOrderedByCPU() {
        let presentation = present([process(10, uid: 501, cpu: 0.125, memory: 1),
                                    process(1, uid: 0, cpu: 0.25, memory: 1), process(2, uid: 0, cpu: 0.125, memory: 1),
                                    process(88, uid: 88, cpu: 0.5, memory: 1)], sessions: [])
        let other = presentation.rows.last
        #expect(other?.kind == .otherAccounts)
        #expect(other?.id == "other")
        #expect(other?.accounts == ["_windowserver", "root"])
        #expect(other?.processCount == 3)
        #expect(other?.figures.cpuLoad == 0.875)
        #expect(other?.summary == "_windowserver, root")
    }

    @Test func summaryCountsSessions() {
        let presentation = present([], sessions: [
            session("mara", "console"), session("mara", "ttys001"), session("mara", "ttys002"),
            session("mara", "ttys004", host: "10.0.0.7"), session("mara", "ttys005", host: "10.0.0.7"),
        ])
        #expect(presentation.rows[0].summary == "Bildschirm · 2 Terminals · SSH von 10.0.0.7")
        #expect(presentation.rows[0].isExpandable)
    }

    @Test func accountListShortensLongLists() {
        #expect(UserUsagePresenter.accountList(["a", "b", "c", "d", "e"]) == "a, b, c und 2 weitere")
    }

    @Test func headerAndCPUShares() {
        let presentation = twoUsers
        #expect(presentation.headerValue(.name) == "2 Benutzer")
        #expect(presentation.cpuShare(of: presentation.rows[0]) == 0.75)
        #expect(presentation.cpuShareText(of: presentation.rows[1]) == "25\u{A0}% der CPU-Last")
    }

    @Test func includesNetworkRates() {
        let presentation = present([process(10, uid: 501, cpu: 0, memory: 1)], sessions: [],
                                   network: [ProcessKey(pid: 10, startTime: 1): 1_000])
        #expect(presentation.rows[0].figures.networkPerSecond == 1_000)
    }
}
