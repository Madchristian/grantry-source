#if DEBUG
import Foundation

/// Fester Stand der Ansicht „Verbindungen“ für SwiftUI-Previews und Bilder – ohne nettop: lauschende Dienste (node auf
/// allen Schnittstellen, postgres nur lokal, ein Systemdienst als root), gebundenes UDP (mDNS) und Verbindungen ins
/// Internet, ins lokale Netz und über Loopback.
public enum NetworkConnectionsPreviewData {
    public static var frame: ActivityFrame {
        let processes = [
            process(388, "mDNSResponder", connections: [
                bound(5353, version: .v4), bound(5353, version: .v6),
            ], download: 1_800, upload: 600, uid: 65),
            process(612, "rapportd", connections: [
                tcp(local: "192.168.1.24", 52630, remote: "192.168.1.31", 49_152, download: 0, upload: 120),
            ], listening: [listening(port: 49_178, version: .v6)]),
            process(4242, "node", connections: [
                tcp(local: "192.168.1.24", 3000, remote: "192.168.1.20", 61_000, download: 2_000, upload: 18_000),
                tcp(local: "127.0.0.1", 52_114, remote: "127.0.0.1", 5432, download: 1_200, upload: 300),
            ], listening: [listening(port: 3000), listening(port: 3000, version: .v6)], download: 3_200, upload: 18_300),
            process(733, "postgres", connections: [
                tcp(local: "127.0.0.1", 5432, remote: "127.0.0.1", 52_114, download: 300, upload: 1_200),
            ], listening: [listening(port: 5432, address: "127.0.0.1"), listening(port: 5432, address: "::1", version: .v6)]),
            process(4820, "Safari", connections: [
                tcp(local: "fd00::24", 52_118, remote: "2001:db8::44", 443, download: 1_250_000, upload: 42_000),
                tcp(local: "192.168.1.24", 52_206, remote: "192.0.2.10", 443, download: 310_000, upload: 8_000),
                quic(local: "192.168.1.24", 61_412, remote: "198.51.100.7", 443, download: 96_000, upload: 4_000),
            ], download: 1_656_000, upload: 54_000),
            process(1102, "Mail", connections: [
                tcp(local: "192.168.1.24", 52_411, remote: "203.0.113.25", 993, download: 0, upload: 0),
            ]),
            process(911, "sharingd", connections: [bound(61_302, version: .v6)]),
            process(1, "launchd", connections: [], listening: [listening(port: 8021, address: "127.0.0.1")], uid: 0),
            process(5120, "ssh", connections: [
                tcp(local: "192.168.1.24", 52_509, remote: "192.168.1.5", 22, download: 900, upload: 400),
            ]),
        ]
        let history = (0..<60).map { index in
            TrafficRate(download: 900_000 + 700_000 * sin(Double(index) / 5),
                        upload: 60_000 + 40_000 * cos(Double(index) / 4))
        }
        return ActivityFrame(
            report: TrafficReport(processes: processes, total: processes.reduce(.zero) { $0 + $1.rate },
                                  history: history, skippedLineCount: 0),
            programs: Dictionary(uniqueKeysWithValues: processes.compactMap { process in
                programs[process.shortName].map { (process.key, $0) }
            })
        )
    }

    /// Feste Kurznamen zu den UIDs der Beispielprozesse – unabhängig von den Konten des Macs.
    public static func userName(_ uid: UInt32) -> String {
        [0: "root", 65: "_mdnsresponder", 501: "anna"][uid] ?? String(uid)
    }

    private static let programs: [String: NetworkProgram] = [
        "mDNSResponder": NetworkProgram(executablePath: "/usr/sbin/mDNSResponder",
                                        signing: SigningInfo(kind: .apple)),
        "rapportd": NetworkProgram(executablePath: "/usr/libexec/rapportd",
                                   signing: SigningInfo(kind: .apple)),
        "node": NetworkProgram(executablePath: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
                               signing: SigningInfo(kind: .adHoc)),
        "postgres": NetworkProgram(executablePath: "/opt/homebrew/opt/postgresql@17/bin/postgres",
                                   signing: SigningInfo(kind: .adHoc)),
        "Safari": NetworkProgram(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                                 signing: SigningInfo(kind: .apple)),
        "Mail": NetworkProgram(executablePath: "/System/Applications/Mail.app/Contents/MacOS/Mail",
                               signing: SigningInfo(kind: .apple)),
        "sharingd": NetworkProgram(executablePath: "/usr/libexec/sharingd",
                                   signing: SigningInfo(kind: .apple)),
        "ssh": NetworkProgram(executablePath: "/usr/bin/ssh", signing: SigningInfo(kind: .apple)),
    ]

    private static func process(_ pid: Int32, _ name: String, connections: [ConnectionActivity],
                                listening: [ConnectionTraffic] = [], download: Double = 0,
                                upload: Double = 0, uid: UInt32 = 501) -> ProcessActivity {
        ProcessActivity(key: ProcessKey(pid: pid, startTime: 1), shortName: name,
                        rate: TrafficRate(download: download, upload: upload),
                        transferred: ByteTotals(received: UInt64(download * 60), sent: UInt64(upload * 60)),
                        connections: connections, isGone: false, listeningSockets: listening, uid: uid)
    }

    private static func listening(port: UInt16, address: String? = nil, version: IPVersion = .v4) -> ConnectionTraffic {
        NetworkActivityPreviewData.listening(port: port, address: address, version: version)
    }

    private static func tcp(local: String, _ localPort: UInt16, remote: String, _ remotePort: UInt16, download: Double,
                            upload: Double) -> ConnectionActivity {
        activity(.tcp, local: local, localPort, remote: remote, remotePort, state: "Established", download: download,
                 upload: upload)
    }

    private static func quic(local: String, _ localPort: UInt16, remote: String, _ remotePort: UInt16, download: Double,
                             upload: Double) -> ConnectionActivity {
        activity(.quic, local: local, localPort, remote: remote, remotePort, state: "", download: download, upload: upload)
    }

    private static func bound(_ port: UInt16, version: IPVersion) -> ConnectionActivity {
        let traffic = ConnectionTraffic(transport: .udp, ipVersion: version, local: ConnectionEndpoint(address: nil, port: port),
                                        remote: ConnectionEndpoint(address: nil, port: nil), state: "", bytesIn: 0,
                                        bytesOut: 0)
        return ConnectionActivity(key: ConnectionKey(traffic, ordinal: 0), connection: traffic, rate: .zero,
                                  transferred: .zero, isNew: false, isGone: false)
    }

    private static func activity(_ transport: ConnectionTransport, local: String, _ localPort: UInt16, remote: String,
                                 _ remotePort: UInt16, state: String, download: Double,
                                 upload: Double) -> ConnectionActivity {
        let traffic = ConnectionTraffic(
            transport: transport, ipVersion: remote.contains(":") ? .v6 : .v4,
            local: ConnectionEndpoint(address: local, port: localPort),
            remote: ConnectionEndpoint(address: remote, port: remotePort), state: state, bytesIn: 0, bytesOut: 0
        )
        return ConnectionActivity(key: ConnectionKey(traffic, ordinal: 0), connection: traffic,
                                  rate: TrafficRate(download: download, upload: upload),
                                  transferred: ByteTotals(received: UInt64(download * 60), sent: UInt64(upload * 60)),
                                  isNew: false, isGone: false)
    }
}
#endif
