import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkActivityPresentationTests {
    private let safari = NetworkProgram(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                                        signing: SigningInfo(kind: .developerID, teamID: "TEAMA12345"))
    private let mdns = NetworkProgram(executablePath: "/usr/sbin/mDNSResponder", signing: SigningInfo(kind: .apple))
    private let node = NetworkProgram(executablePath: "/opt/homebrew/bin/node", signing: SigningInfo(kind: .adHoc))

    private func rows(_ frame: ActivityFrame, filter: NetworkActivityFilter = NetworkActivityFilter(), query: String = "",
                      hostNames: [String: String] = [:],
                      sortOrder: [KeyPathComparator<NetworkActivityRow>] = NetworkActivityPresenter.defaultSortOrder)
        -> [NetworkActivityRow] {
        NetworkActivityPresenter.rows(frame: frame, hostNames: hostNames, filter: filter, query: query,
                                      sortOrder: sortOrder)
    }

    @Test func defaultFilterShowsOnlyActiveNonAppleProcessesByTotalRate() {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, "Safari", download: 100, upload: 10),
            TestData.processActivity(2, "mDNSResponder", download: 5000),
            TestData.processActivity(3, "node", upload: 500),
            TestData.processActivity(4, "idle"),
            TestData.processActivity(0, "kernel_task", download: 9000),
        ], programs: [1: safari, 2: mdns, 3: node])
        #expect(rows(frame).map(\.title) == ["node", "Safari"])

        var all = NetworkActivityFilter()
        all.onlyActive = false
        all.hidesAppleServices = false
        #expect(rows(frame, filter: all).map(\.title) == ["kernel_task", "mDNSResponder", "node", "Safari", "idle"])
    }

    @Test func interpreterFilterKeepsOnlyInterpreters() {
        var filter = NetworkActivityFilter()
        filter.onlyInterpreters = true
        let frame = TestData.activityFrame([
            TestData.processActivity(1, download: 1), TestData.processActivity(3, download: 1),
        ], programs: [1: safari, 3: node])
        #expect(rows(frame, filter: filter).map(\.title) == ["node"])
        #expect(filter.isActive)
        #expect(!NetworkActivityFilter().isActive)
    }

    @Test func processRowCarriesProgramTotalsAndConnectionCount() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, "Safari", download: 100, transferred: 4096, connections: [
                TestData.connectionActivity(port: 443, download: 100),
                TestData.connectionActivity(port: 80),
                TestData.connectionActivity(port: 8443, isGone: true),
            ]),
        ], programs: [1: safari])
        let row = try #require(rows(frame).first)
        #expect(row.title == "Safari")
        #expect(row.detail == "2 Verbindungen")
        #expect(row.compactDetail == "2")
        #expect(row.connectionCount == 2)
        #expect(row.totalBytes == 4096)
        #expect(row.executablePath == safari.executablePath)
        #expect(row.signing == safari.signing)
        #expect(row.accessibilityLabel == "Safari, empfängt 100 B/s, sendet 0 B/s, 2 Verbindungen")
    }

    /// Ein eben beendeter Prozess hat Rate 0, bleibt unter „Nur aktive“ aber für seine 10 s ausgegraut sichtbar.
    @Test func activeFilterKeepsVanishedProcessesGreyed() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, "Safari", download: 100),
            TestData.processActivity(3, "node", connections: [TestData.connectionActivity(isGone: true)], isGone: true),
            TestData.processActivity(4, "idle"),
        ], programs: [1: safari, 3: node])
        let rows = rows(frame)
        #expect(rows.map(\.title) == ["Safari", "node"])
        let vanished = try #require(rows.last)
        #expect(vanished.isGone)
        #expect(vanished.children?.map(\.isGone) == [true])
        #expect(vanished.accessibilityLabel.hasSuffix(", beendet"))
    }

    /// Solange die Signatur geprüft wird, zeigt die Zeile kein Signatur-Label.
    @Test func pendingSignatureShowsNoLabelYet() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, download: 2), TestData.processActivity(3, download: 1),
        ], programs: [1: safari, 3: node], pendingSignatures: [3])
        let rows = rows(frame)
        #expect(rows.map(\.title) == ["Safari", "node"])
        #expect(rows[0].signing == safari.signing)
        #expect(rows[1].signing == nil)
        #expect(rows[1].executablePath == node.executablePath)
    }

    /// „Nur aktive“ blendet ruhende Verbindungen aus, neue und geschlossene bleiben sichtbar.
    @Test func activeFilterKeepsBusyNewAndClosedConnections() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, download: 100, connections: [
                TestData.connectionActivity(remote: "192.0.2.10", download: 100),
                TestData.connectionActivity(remote: "192.0.2.11"),
                TestData.connectionActivity(remote: "192.0.2.12", isNew: true),
                TestData.connectionActivity(remote: "192.0.2.13", isGone: true),
            ]),
        ], programs: [1: safari])
        let children = try #require(rows(frame).first?.children)
        #expect(children.map(\.title) == ["192.0.2.10", "192.0.2.12", "192.0.2.13"])
        #expect(children.map(\.isNew) == [false, true, false])
    }

    @Test func connectionRowShowsHostPortProtocolAndState() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, download: 1, connections: [
                TestData.connectionActivity(remote: "192.0.2.10", port: 443, download: 1),
                TestData.connectionActivity(remote: nil, port: nil, transport: .udp, state: "", isNew: true),
            ]),
        ], programs: [1: safari])
        let children = try #require(rows(frame, hostNames: ["192.0.2.10": "api.example.com"]).first?.children)
        #expect(children[0].title == "api.example.com")
        #expect(children[0].detail == "Port 443 · TCP · Established")
        #expect(children[0].compactDetail == "443 · TCP")
        #expect(children[0].target == "api.example.com:443")
        #expect(children[1].title == "Ohne Gegenstelle")
        #expect(children[1].detail == "UDP")
        #expect(children[1].compactDetail == "UDP")
        #expect(children[1].target == nil)
        #expect(children[1].accessibilityLabel == "Ohne Gegenstelle, UDP, empfängt 0 B/s, sendet 0 B/s, neu")
    }

    @Test func targetWithoutHostNameKeepsIPv6Brackets() throws {
        let connection = ConnectionTraffic(
            transport: .tcp, ipVersion: .v6, local: ConnectionEndpoint(address: "2001:db8::2", port: 50000),
            remote: ConnectionEndpoint(address: "2001:db8::1", port: 443), state: "Established", bytesIn: 0, bytesOut: 0
        )
        let activity = ConnectionActivity(key: ConnectionKey(connection, ordinal: 0), connection: connection,
                                          rate: TrafficRate(download: 1, upload: 0), transferred: .zero,
                                          isNew: false, isGone: false)
        let frame = TestData.activityFrame([TestData.processActivity(1, download: 1, connections: [activity])],
                                           programs: [1: safari])
        #expect(rows(frame).first?.children?.first?.target == "[2001:db8::1]:443")
    }

    /// Suche nach Name, Pfad, Ziel oder Port; passt nur eine Verbindung, bleibt nur sie unter ihrem Prozess.
    @Test func searchMatchesNamesTargetsAndPorts() {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, "Safari", download: 2, connections: [
                TestData.connectionActivity(remote: "192.0.2.10", port: 443, download: 1),
                TestData.connectionActivity(remote: "192.0.2.20", port: 8443, download: 1),
            ]),
            TestData.processActivity(3, "node", download: 1),
        ], programs: [1: safari, 3: node])
        #expect(rows(frame, query: "homebrew").map(\.title) == ["node"])
        #expect(rows(frame, query: "safari").first?.children?.count == 2)
        let byPort = rows(frame, query: "8443")
        #expect(byPort.map(\.title) == ["Safari"])
        #expect(byPort.first?.children?.map(\.title) == ["192.0.2.20"])
        #expect(rows(frame, query: "api", hostNames: ["192.0.2.10": "api.example.com"]).first?.children?.count == 1)
        #expect(rows(frame, query: "nichts").isEmpty)
    }

    /// Die PID ist kein Suchbegriff – sonst träfe die Port-Suche „443“ auch PID 4430.
    @Test func searchIgnoresProcessIDs() {
        let frame = TestData.activityFrame([
            TestData.processActivity(4430, "node", download: 1, connections: [
                TestData.connectionActivity(remote: "192.0.2.20", port: 8080, download: 1),
            ]),
            TestData.processActivity(1, "Safari", download: 1, connections: [
                TestData.connectionActivity(remote: "192.0.2.10", port: 443, download: 1),
            ]),
        ], programs: [4430: node, 1: safari])
        #expect(rows(frame, query: "443").map(\.title) == ["Safari"])
        #expect(rows(frame, query: "4430").isEmpty)
    }

    @Test func sortsByChosenColumnWithStableTieBreak() {
        let frame = TestData.activityFrame([
            TestData.processActivity(1, download: 100, upload: 0),
            TestData.processActivity(3, download: 10, upload: 500),
        ], programs: [1: safari, 3: node])
        #expect(rows(frame).map(\.title) == ["node", "Safari"])
        #expect(rows(frame, sortOrder: [KeyPathComparator(\.downloadRate, order: .reverse)]).map(\.title) == ["Safari", "node"])
        #expect(rows(frame, sortOrder: [KeyPathComparator(\.title, order: .reverse)]).map(\.title) == ["Safari", "node"])
        #expect(rows(frame, sortOrder: []).map(\.id) == ["p:1-1", "p:3-1"])
    }

    @Test func findsRowsAndMatchingListener() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(3, download: 1, connections: [TestData.connectionActivity(download: 1)]),
        ], programs: [3: node])
        let rows = rows(frame)
        let child = try #require(rows.first?.children?.first)
        #expect(NetworkActivityPresenter.row(withID: child.id, in: rows) == child)
        let listener = TestData.listener("/opt/homebrew/bin/node")
        #expect(NetworkActivityPresenter.listener(for: rows[0], in: [TestData.listener("/usr/sbin/sshd"), listener])
            == listener)
        #expect(NetworkActivityPresenter.listener(for: child, in: [listener]) == nil)
    }
}
