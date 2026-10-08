#if DEBUG
import Foundation

/// Feste Stände der Netzwerkaktivität für die SwiftUI-Previews – ohne nettop.
public enum NetworkActivityPreviewData {
    public static let hostNames = ["192.0.2.10": "api.example.com"]

    /// Firefox, ein node-Prozess (lauscht auf 3000, eine neue ausgehende und eine eingehende Verbindung) und ein
    /// ausgegrauter, eben beendeter curl.
    public static var frame: ActivityFrame {
        let firefox = ProcessKey(pid: 501, startTime: 1)
        let node = ProcessKey(pid: 4242, startTime: 1)
        let curl = ProcessKey(pid: 4300, startTime: 1)
        let processes = [
            ProcessActivity(key: firefox, shortName: "firefox", rate: TrafficRate(download: 1_250_000, upload: 42_000),
                            transferred: ByteTotals(received: 88_000_000, sent: 3_100_000),
                            connections: [connection(remote: "192.0.2.10", port: 443, download: 1_250_000, upload: 42_000),
                                          connection(remote: "192.0.2.20", port: 443, download: 0, upload: 0)],
                            isGone: false),
            ProcessActivity(key: node, shortName: "node", rate: TrafficRate(download: 3_400, upload: 18_000),
                            transferred: ByteTotals(received: 120_000, sent: 900_000),
                            connections: [connection(remote: "2001:db8::10", port: 8443, download: 3_400, upload: 16_000,
                                                     isNew: true),
                                          connection(remote: "192.168.1.20", port: 61_000, local: 3000, download: 0,
                                                     upload: 2_000)],
                            isGone: false,
                            history: (0..<24).map { TrafficRate(download: 3_400 + Double($0 % 5) * 900, upload: 18_000) },
                            listeningTCPPorts: [3000]),
            ProcessActivity(key: curl, shortName: "curl", rate: .zero, transferred: ByteTotals(received: 5_000, sent: 700),
                            connections: [], isGone: true),
        ]
        let history = (0..<60).map { index in
            TrafficRate(download: 600_000 + 500_000 * sin(Double(index) / 6), upload: 40_000 + Double(index % 7) * 3_000)
        }
        return ActivityFrame(
            report: TrafficReport(processes: processes, total: processes.reduce(.zero) { $0 + $1.rate },
                                  history: history, skippedLineCount: 0),
            programs: [
                firefox: NetworkProgram(executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox",
                                        signing: SigningInfo(kind: .developerID, teamID: "TEAMA12345",
                                                             isNotarized: true)),
                node: NetworkProgram(executablePath: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
                                     signing: SigningInfo(kind: .adHoc)),
            ]
        )
    }

    /// Messung läuft, aber kein Prozess ist aktiv.
    public static var quietFrame: ActivityFrame {
        ActivityFrame(report: TrafficReport(processes: [], total: .zero, history: Array(repeating: .zero, count: 5),
                                            skippedLineCount: 0),
                      programs: [:])
    }

    private static func connection(remote: String, port: UInt16, local: UInt16 = 50_000, download: Double,
                                   upload: Double, isNew: Bool = false) -> ConnectionActivity {
        let version: IPVersion = remote.contains(":") ? .v6 : .v4
        let traffic = ConnectionTraffic(
            transport: .tcp, ipVersion: version,
            local: ConnectionEndpoint(address: version == .v4 ? "192.0.2.2" : "2001:db8::2", port: local),
            remote: ConnectionEndpoint(address: remote, port: port), state: "Established", bytesIn: 0, bytesOut: 0
        )
        return ConnectionActivity(key: ConnectionKey(traffic, ordinal: 0), connection: traffic,
                                  rate: TrafficRate(download: download, upload: upload),
                                  transferred: ByteTotals(received: UInt64(download * 30), sent: UInt64(upload * 30)),
                                  isNew: isNew, isGone: false)
    }
}
#endif
