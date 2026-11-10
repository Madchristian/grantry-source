import Testing
@testable import ManagerKit

@Suite struct ServiceListPresenterTests {
    private static let home = "/Users/mara"

    private func agent(_ label: String, inHome: Bool = true) -> AutostartItem {
        AutostartItem(kind: .launchAgent, domain: inHome ? .user : .system, label: label,
                      program: "/usr/local/bin/\(label)", programPresence: .present, isEnabled: true, isLoaded: true,
                      plistPath: (inHome ? Self.home : "") + "/Library/LaunchAgents/\(label).plist", owner: nil,
                      source: .launchd)
    }

    private func daemon(_ label: String) -> AutostartItem {
        AutostartItem(kind: .launchDaemon, domain: .system, label: label, program: "/usr/local/bin/\(label)",
                      programPresence: .present, isEnabled: true, isLoaded: true,
                      plistPath: "/Library/LaunchDaemons/\(label).plist", owner: nil, source: .launchd)
    }

    private func status(_ label: String, pid: Int32? = nil, exit: LaunchdExitStatus = .never) -> LaunchdServiceStatus {
        LaunchdServiceStatus(label: label, pid: pid, lastExit: exit)
    }

    private var rows: [ServiceRow] {
        ServiceListPresenter.rows(
            [.system: [status("com.example.daemon", pid: 9)],
             .user(501): [status("com.example.own", pid: 5), status("com.example.shared"), status("com.apple.Finder", pid: 7)]],
            autostartItems: [agent("com.example.own"), agent("com.example.shared", inHome: false),
                             daemon("com.example.daemon")]
        )
    }

    @Test func linksAgentsAndDaemonsByLabelAndDomain() {
        let rows = rows
        #expect(rows.map(\.id) == ["gui/501/com.example.own", "gui/501/com.example.shared", "gui/501/com.apple.Finder",
                                   "system/com.example.daemon"])
        #expect(rows.map { $0.autostartItem?.label } == ["com.example.own", "com.example.shared", nil,
                                                         "com.example.daemon"])
        #expect(rows.map(\.isControllable) == [true, false, false, false])
        let notOwn = ActionAvailability.Reason.notOwnAgent.description
        #expect(rows.map(\.controlNote) == [nil, notOwn, ActionAvailability.Reason.noPlist.description, notOwn])
    }

    @Test func labelInSeveralPlistsStaysUnlinked() {
        let rows = ServiceListPresenter.rows([.user(501): [status("com.example.twice", pid: 3)]],
                                             autostartItems: [agent("com.example.twice"),
                                                              agent("com.example.twice", inHome: false)])
        #expect(rows[0].autostartItem == nil)
        #expect(!rows[0].isControllable)
    }

    @Test func agentOfAnotherSessionTypeIsNotControllable() {
        var item = agent("com.example.background")
        item.sessionTypes = ["Background"]
        let row = ServiceListPresenter.rows([.user(501): [status("com.example.background")]], autostartItems: [item])[0]
        #expect(row.controlNote == ActionAvailability.Reason.nonAquaSession.description)
    }

    @Test func scopesFilterAndCount() {
        var options = ServiceListOptions()
        options.scope = .own
        let own = ServiceListPresenter.present(rows, options: options)
        #expect(own.rows.map(\.label) == ["com.example.own"])
        #expect(own.counts == [.own: 1, .session: 3, .system: 1])
        options.scope = .system
        #expect(ServiceListPresenter.present(rows, options: options).rows.map(\.label) == ["com.example.daemon"])
    }

    @Test func runningFirstThenLabelAndSearchByLabelOrPID() {
        let rows = ServiceListPresenter.rows(
            [.user(501): [status("gamma", pid: 12), status("alpha"), status("beta", pid: 3)]], autostartItems: []
        )
        var options = ServiceListOptions()
        #expect(ServiceListPresenter.present(rows, options: options).rows.map(\.label) == ["beta", "gamma", "alpha"])
        options.query = "12"
        #expect(ServiceListPresenter.present(rows, options: options).rows.map(\.label) == ["gamma"])
        options.query = "ALP"
        #expect(ServiceListPresenter.present(rows, options: options).rows.map(\.label) == ["alpha"])
    }

    @Test func statesAndTexts() {
        let cases: [(LaunchdServiceStatus, ServiceState, String, String)] = [
            (status("a", pid: 4), .running, "Läuft", "–"),
            (status("b"), .idle, "Bereit", "–"),
            (status("c", exit: .exited(0)), .ended, "Beendet", "0"),
            (status("d", exit: .exited(78)), .failed, "Fehler", "78"),
            (status("e", exit: .signaled(15)), .ended, "Beendet", "Signal 15"),
            (status("f", exit: .signaled(9)), .failed, "Fehler", "Signal 9"),
            (status("g", exit: .other("(jt)")), .ended, "Beendet", "(jt)"),
        ]
        for (status, state, title, exit) in cases {
            let row = ServiceListPresenter.rows([.user(501): [status]], autostartItems: [])[0]
            #expect(row.state == state)
            #expect(row.state.title == title)
            #expect(row.exitText == exit)
        }
        let presentation = ServiceListPresenter.present(
            ServiceListPresenter.rows([.user(501): cases.map(\.0)], autostartItems: []), options: ServiceListOptions()
        )
        #expect(presentation.stateCounts == [.running: 1, .idle: 1, .ended: 3, .failed: 2])
        #expect(presentation.runningCount == 1)
    }
}
