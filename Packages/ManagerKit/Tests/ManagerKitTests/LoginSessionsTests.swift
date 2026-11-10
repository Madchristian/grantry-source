import Darwin
import Foundation
import Testing
@testable import ManagerKit

@Suite struct LoginSessionsTests {
    private func record(_ type: Int32 = USER_PROCESS, user: String = "mara", line: String, host: String = "",
                        at seconds: Int = 1_793_000_000) -> UtmpxRecord {
        UtmpxRecord(type: type, user: user, line: line, host: host, loginSeconds: seconds)
    }

    @Test func keepsOnlyLoggedInUsers() {
        let sessions = LoginSessions.sessions(from: [
            record(line: "console"), record(BOOT_TIME, user: "", line: "~"),
            record(DEAD_PROCESS, user: "jonas", line: "ttys009"),
        ])
        #expect(sessions.map(\.line) == ["console"])
    }

    @Test func classifiesScreenTerminalAndRemote() {
        let sessions = LoginSessions.sessions(from: [
            record(line: "ttys004", host: "10.0.0.7"), record(line: "ttys001"), record(line: "console"),
        ])
        #expect(sessions.map(\.kind) == [.graphical, .terminal, .remote])
        #expect(sessions.map(\.host) == [nil, nil, "10.0.0.7"])
    }

    @Test func sortsByUserThenKindThenLine() {
        let sessions = LoginSessions.sessions(from: [
            record(line: "ttys009"), record(user: "jonas", line: "ttys002"), record(line: "console"),
        ])
        #expect(sessions.map { "\($0.user)@\($0.line)" } == ["jonas@ttys002", "mara@console", "mara@ttys009"])
    }

    @Test func describesSession() throws {
        let session = LoginSession(user: "jonas", line: "ttys004", host: "10.0.0.7",
                                   loginDate: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(session.detail == "ttys004 von 10.0.0.7")
        #expect(session.sinceText(timeZone: try #require(TimeZone(identifier: "Europe/Berlin")))
            == "seit 26.10.2026, 08:33")
        #expect(session.kind.title == "Fernanmeldung")
    }

    /// Integration (nur lesend): Die utmpx-Datenbank dieses Macs lässt sich lesen.
    @Test func readsDatabaseOfThisMac() {
        #expect(LoginSessions.current().allSatisfy { !$0.user.isEmpty && !$0.line.isEmpty })
    }
}

@MainActor
@Suite struct LoginSessionsModelTests {
    @Test func refreshPublishesSessions() async {
        let session = LoginSession(user: "mara", line: "console", host: nil, loginDate: Date(timeIntervalSince1970: 0))
        let model = LoginSessionsModel(read: { [session] })
        #expect(model.sessions.isEmpty)
        await model.refresh()
        #expect(model.sessions == [session])
    }
}
