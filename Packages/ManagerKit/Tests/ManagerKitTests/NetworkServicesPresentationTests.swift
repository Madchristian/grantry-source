import Foundation
import Testing
@testable import ManagerKit

/// Ansicht „Dienste“ im Lagebild (#366): Zählkacheln, Zeilen und Urteil der Zustandszeile.
@Suite struct NetworkServicesPresentationTests {
    private let exposedNode = TestData.listener("/opt/homebrew/bin/node", port: 3000, addresses: ["0.0.0.0"])
    private let exposedPython = TestData.listener("/opt/homebrew/bin/python3", port: 8000, addresses: ["192.168.1.20"])
    private let localRedis = TestData.listener("/usr/local/bin/redis-server", port: 6379, addresses: ["127.0.0.1"])
    private let airPlay = TestData.listener(
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", port: 7000, addresses: ["::"],
        signing: SigningInfo(kind: .apple)
    )
    /// Browser mit UDP auf wechselndem Port: erreichbar, aber vermutlich ein Client.
    private let browserUDP = TestData.listener(
        "/Applications/Firefox.app/Contents/MacOS/firefox", transport: .udp, port: nil, addresses: ["0.0.0.0"],
        signing: SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
    )

    private func presentation(_ listeners: [NetworkListener], filter: NetworkListenerFilter = NetworkListenerFilter(),
                              query: String = "",
                              severity: @escaping (String) -> RiskFinding.Severity? = { _ in nil })
        -> NetworkServicesPresentation {
        NetworkServicesPresentation(listeners: listeners, severity: severity, query: query, filter: filter)
    }

    @Test func countsFollowSystemServiceSettingButIgnoreSearchAndFilters() {
        let listeners = [exposedNode, exposedPython, localRedis, airPlay, browserUDP]
        var filter = NetworkListenerFilter()
        filter.onlyInterpreters = true
        let hidden = presentation(listeners, filter: filter, query: "node",
                                  severity: { $0 == exposedNode.id ? .medium : nil })
        #expect(hidden.counts == NetworkServicesPresentation.Counts(total: 4, exposed: 2, exposedSystem: 0, thisMac: 1,
                                                                    withFindings: 1))
        #expect(hidden.rows.map(\.id) == [exposedNode.id])

        filter.showsSystemServices = true
        let shown = presentation(listeners, filter: filter)
        #expect(shown.counts.total == 5)
        #expect(shown.counts.exposed == 3)
        #expect(shown.counts.exposedSystem == 1)
    }

    /// Kachel, Zustandszeile und Firewall-Hinweis nennen dieselbe Zahl eigener erreichbarer Dienste; eingeblendete
    /// Systemdienste zählt die Kachel zusätzlich und weist sie getrennt aus.
    @Test func exposedCountsAgreeAcrossTileVerdictAndFirewall() {
        let listeners = [exposedNode, exposedPython, localRedis, airPlay, browserUDP]
        let overview = NetworkOverview.make(snapshot: TestData.networkSnapshot(listeners))
        for showsSystem in [false, true] {
            var filter = NetworkListenerFilter()
            filter.showsSystemServices = showsSystem
            let shown = presentation(listeners, filter: filter)
            #expect(shown.ownExposedCount == overview.exposedCount)
            #expect(shown.counts.exposed - shown.counts.exposedSystem == shown.ownExposedCount)
            #expect(shown.verdict(firewallHint: nil).title == "2 Dienste aus dem Netz erreichbar")
        }
    }

    @Test func rowsMatchListenerPresenter() {
        let listeners = [localRedis, exposedNode]
        #expect(presentation(listeners).rows == NetworkListenerPresenter.rows(
            listeners, severity: { _ in nil }, query: "", filter: NetworkListenerFilter()
        ))
    }

    @Test func verdictNamesOwnExposedServicesAsFinding() {
        let one = presentation([exposedNode, localRedis, airPlay]).verdict(firewallHint: .firewallOn)
        #expect(one.title == "1 Dienst aus dem Netz erreichbar")
        #expect(one.level == .finding)
        #expect(one.items == [SystemVerdict.Item(text: "Firewall an", tone: .positive)])

        let two = presentation([exposedNode, exposedPython]).verdict(firewallHint: .firewallOff(exposedCount: 2))
        #expect(two.title == "2 Dienste aus dem Netz erreichbar")
        #expect(two.items.first == SystemVerdict.Item(text: "Firewall aus", tone: .warning))
    }

    /// Systemdienste und vermutliche Clients ergeben keinen Befund – wie `ExposedListenerRule` und die Kachel der
    /// Übersicht.
    @Test func verdictIsCalmWithoutOwnExposedServices() {
        let calm = presentation([localRedis, airPlay, browserUDP]).verdict(firewallHint: nil)
        #expect(calm.title == "Kein Dienst aus dem Netz erreichbar")
        #expect(calm.level == .calm)
        #expect(calm.items.isEmpty)

        let empty = presentation([]).verdict(firewallHint: nil)
        #expect(empty.title == "Keine Netzwerkdienste")
        #expect(empty.level == .calm)
    }

    @Test func firewallOffIsAFindingOnItsOwn() {
        #expect(presentation([localRedis]).verdict(firewallHint: .firewallOff(exposedCount: 0)).level == .finding)
    }

    @Test func verdictCountsHintsAndNamesVisibility() {
        let verdict = presentation([exposedNode, exposedPython, localRedis],
                                   severity: { $0 == localRedis.id ? nil : .medium }).verdict(firewallHint: nil)
        #expect(verdict.items == [SystemVerdict.Item(text: "2 Dienste mit Hinweis", tone: .warning)])
        #expect(verdict.facts == "3 Dienste · Systemdienste ausgeblendet")

        var filter = NetworkListenerFilter()
        filter.showsSystemServices = true
        let single = presentation([exposedNode], filter: filter, severity: { _ in .high }).verdict(firewallHint: nil)
        #expect(single.items == [SystemVerdict.Item(text: "1 Dienst mit Hinweis", tone: .warning)])
        #expect(single.facts == "1 Dienst · mit Systemdiensten")
    }
}
