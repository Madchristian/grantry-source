import Foundation
@testable import ManagerKit

extension TestData {
    /// Standardquellen plus Lauscher (eingeschwungener Zustand).
    static let networkSources: Set<SourceID> = allSources.union([.networkListeners])

    static func listener(
        _ path: String = "/opt/homebrew/bin/node", uid: UInt32 = 501, transport: SocketTransport = .tcp,
        port: UInt16? = 3000, addresses: [String] = ["0.0.0.0"], signing: SigningInfo = SigningInfo(kind: .adHoc),
        ancestors: [String] = [], firstSeen: Date = date, lastSeen: Date = date
    ) -> NetworkListener {
        NetworkListener(executablePath: path, uid: uid, transport: transport, port: port, addresses: addresses,
                        signing: signing, ancestorPaths: ancestors, firstSeenAt: firstSeen, lastSeenAt: lastSeen)
    }

    static func networkSnapshot(
        _ listeners: [NetworkListener], items: [AutostartItem] = [], errors: [SourceError] = [],
        baseline: Set<SourceID> = networkSources, at date: Date = date
    ) -> Snapshot {
        Snapshot(takenAt: date, grants: [], autostartItems: items, networkListeners: listeners, sourceErrors: errors,
                 baselineSources: baseline)
    }
}
