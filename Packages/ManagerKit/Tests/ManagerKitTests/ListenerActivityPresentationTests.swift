import Foundation
import Testing
@testable import ManagerKit

@Suite struct ListenerActivityPresentationTests {
    private let postgres = NetworkProgram(executablePath: "/opt/homebrew/bin/postgres", signing: SigningInfo(kind: .adHoc))
    private let safari = NetworkProgram(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                                        signing: SigningInfo(kind: .developerID, teamID: "TEAMA12345"))

    private func connection(local: UInt16, remote: String? = "192.0.2.10", remotePort: UInt16? = 443,
                            transport: ConnectionTransport = .tcp, download: Double = 0, isGone: Bool = false)
        -> ConnectionActivity {
        let traffic = ConnectionTraffic(
            transport: transport, ipVersion: .v4, local: ConnectionEndpoint(address: "192.0.2.1", port: local),
            remote: ConnectionEndpoint(address: remote, port: remotePort), state: transport == .tcp ? "Established" : "",
            bytesIn: 0, bytesOut: 0
        )
        return ConnectionActivity(key: ConnectionKey(traffic, ordinal: 0), connection: traffic,
                                  rate: TrafficRate(download: download, upload: 0),
                                  transferred: ByteTotals(received: 10, sent: 5), isNew: false, isGone: isGone)
    }

    private func process(_ pid: Int32, connections: [ConnectionActivity], download: Double = 0,
                         received: UInt64 = 0, sent: UInt64 = 0, history: [TrafficRate] = [],
                         listening: Set<UInt16> = [], isGone: Bool = false) -> ProcessActivity {
        ProcessActivity(key: ProcessKey(pid: pid, startTime: 1), shortName: "postgres",
                        rate: TrafficRate(download: download, upload: 0),
                        transferred: ByteTotals(received: received, sent: sent), connections: connections,
                        isGone: isGone, history: history, listeningTCPPorts: listening)
    }

    @Test func collectsAllProcessesOfTheProgramOnly() {
        let frame = TestData.activityFrame([
            process(10, connections: [], download: 100, received: 1000, sent: 10),
            process(11, connections: [], download: 50, received: 500, sent: 20, isGone: true),
            TestData.processActivity(20, "Safari", download: 9999),
        ], programs: [10: postgres, 11: postgres, 20: safari])

        let activity = ListenerActivityPresenter.activity(forProgramAt: postgres.executablePath, frame: frame,
                                                          hostNames: [:])
        #expect(activity.processes.map(\.pid) == [10, 11])
        #expect(activity.processes.map(\.isGone) == [false, true])
        #expect(activity.rate == TrafficRate(download: 150, upload: 0))
        #expect(activity.transferred == ByteTotals(received: 1500, sent: 30))
    }

    @Test func unknownProgramIsEmpty() {
        let frame = TestData.activityFrame([TestData.processActivity(20, download: 1)], programs: [20: safari])
        let activity = ListenerActivityPresenter.activity(forProgramAt: postgres.executablePath, frame: frame,
                                                          hostNames: [:])
        #expect(activity.isEmpty)
        #expect(activity == .empty)
    }

    /// TCP auf einem lauschenden Port (auch eines anderen Prozesses desselben Programms) ist eingehend.
    @Test func directionFollowsListeningPorts() throws {
        let frame = TestData.activityFrame([
            process(10, connections: [], listening: [5432]),
            process(11, connections: [
                connection(local: 5432, remote: "192.168.1.20", remotePort: 61000),
                connection(local: 50000),
                connection(local: 50001, transport: .udp),
            ]),
        ], programs: [10: postgres, 11: postgres])

        let activity = ListenerActivityPresenter.activity(forProgramAt: postgres.executablePath, frame: frame,
                                                          hostNames: [:])
        let byPort = Dictionary(uniqueKeysWithValues: activity.connections.map { ($0.connection.local.port, $0) })
        #expect(byPort[5432]?.direction == .inbound)
        #expect(byPort[5432]?.location == .localNetwork)
        #expect(byPort[50000]?.direction == .outbound)
        #expect(byPort[50000]?.location == .internet)
        #expect(byPort[50001]?.direction == nil)
        #expect(activity.openConnectionCount(.inbound) == 1)
        #expect(activity.openConnectionCount(.outbound) == 1)
        #expect(activity.remoteHostCount == 2)
        #expect(activity.processes.map(\.connectionCount) == [0, 3])
    }

    @Test func connectionsShowHostNamesOpenAndBusiestFirst() throws {
        let frame = TestData.activityFrame([
            process(10, connections: [
                connection(local: 50000, download: 10),
                connection(local: 50001, remote: "192.0.2.20", download: 500, isGone: true),
                connection(local: 50002, remote: "192.0.2.30", download: 900),
            ]),
        ], programs: [10: postgres])

        let activity = ListenerActivityPresenter.activity(forProgramAt: postgres.executablePath, frame: frame,
                                                          hostNames: ["192.0.2.10": "api.example.com"])
        #expect(activity.connections.map(\.title) == ["192.0.2.30", "api.example.com (192.0.2.10)", "192.0.2.20"])
        #expect(activity.openConnections.count == 2)
        let first = try #require(activity.connections.first { $0.hostName != nil })
        #expect(first.target == "api.example.com:443")
        #expect(first.remoteEndpoint == "192.0.2.10:443")
        #expect(first.localEndpoint == "192.0.2.1:50000")
        #expect(first.protocolText == "TCP · IPv4")
        #expect(first.state == "Established")
        #expect(first.accessibilityLabel.hasPrefix("api.example.com (192.0.2.10), ausgehend, Port 443, TCP"))
    }

    @Test func historySumsRightAligned() {
        let frame = TestData.activityFrame([
            process(10, connections: [], history: [TrafficRate(download: 1, upload: 0), TrafficRate(download: 2, upload: 0),
                                                   TrafficRate(download: 3, upload: 1)]),
            process(11, connections: [], history: [TrafficRate(download: 10, upload: 0)]),
        ], programs: [10: postgres, 11: postgres])

        let activity = ListenerActivityPresenter.activity(forProgramAt: postgres.executablePath, frame: frame,
                                                          hostNames: [:])
        #expect(activity.history == [TrafficRate(download: 1, upload: 0), TrafficRate(download: 2, upload: 0),
                                     TrafficRate(download: 13, upload: 1)])
    }
}
