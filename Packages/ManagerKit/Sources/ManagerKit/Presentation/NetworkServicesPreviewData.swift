#if DEBUG
import Foundation

/// Feste lauschende Dienste für die SwiftUI-Previews der Ansicht „Dienste“ – ohne Scan.
public enum NetworkServicesPreviewData {
    private static let seen = Date(timeIntervalSince1970: 1_790_000_000)

    /// node auf allen Schnittstellen (aus VS Code), python3 auf einer Adresse im lokalen Netz, redis und postgres nur
    /// auf diesem Mac, dnsmasq als root und der AirPlay-Empfänger von macOS.
    public static var listeners: [NetworkListener] {
        [
            listener("/opt/homebrew/Cellar/node/24.1.0/bin/node", port: 3000, addresses: ["0.0.0.0"],
                     signing: SigningInfo(kind: .adHoc),
                     ancestorPaths: ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron"]),
            listener("/opt/homebrew/bin/python3", port: 8000, addresses: ["192.168.1.20"],
                     signing: SigningInfo(kind: .adHoc),
                     ancestorPaths: ["/Applications/iTerm.app/Contents/MacOS/iTerm2"]),
            listener("/usr/local/bin/redis-server", port: 6379, addresses: ["127.0.0.1", "::1"],
                     signing: SigningInfo(kind: .unsigned)),
            listener("/Applications/Postgres.app/Contents/Versions/17/bin/postgres", port: 5432,
                     addresses: ["127.0.0.1"],
                     signing: SigningInfo(kind: .developerID, teamID: "TEAMB12345", isNotarized: true)),
            listener("/usr/local/sbin/dnsmasq", uid: 0, transport: .udp, port: 53, addresses: ["0.0.0.0"],
                     signing: SigningInfo(kind: .adHoc)),
            listener("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", port: 7000,
                     addresses: ["::"], signing: SigningInfo(kind: .apple)),
        ]
    }

    /// Befunde je Lauscher-ID: die von außen erreichbaren Dienste, die nicht von macOS stammen.
    public static func severity(for id: String) -> RiskFinding.Severity? {
        guard let listener = listeners.first(where: { $0.id == id }), listener.countsAsExposed else { return nil }
        return listener.uid == 0 ? .high : .medium
    }

    private static func listener(_ path: String, uid: UInt32 = 501, transport: SocketTransport = .tcp, port: UInt16,
                                 addresses: [String], signing: SigningInfo,
                                 ancestorPaths: [String] = []) -> NetworkListener {
        NetworkListener(executablePath: path, uid: uid, transport: transport, port: port, addresses: addresses,
                        signing: signing, ancestorPaths: ancestorPaths, firstSeenAt: seen, lastSeenAt: seen)
    }
}
#endif
