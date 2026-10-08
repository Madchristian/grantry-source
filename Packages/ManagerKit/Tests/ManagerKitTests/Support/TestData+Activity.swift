import Foundation
@testable import ManagerKit

extension TestData {
    static func connectionActivity(
        remote: String? = "192.0.2.10", port: UInt16? = 443, transport: ConnectionTransport = .tcp,
        state: String = "Established", download: Double = 0, upload: Double = 0, isNew: Bool = false,
        isGone: Bool = false
    ) -> ConnectionActivity {
        let connection = ConnectionTraffic(
            transport: transport, ipVersion: .v4, local: ConnectionEndpoint(address: "192.0.2.1", port: 50000),
            remote: ConnectionEndpoint(address: remote, port: port), state: state, bytesIn: 0, bytesOut: 0
        )
        return ConnectionActivity(key: ConnectionKey(connection, ordinal: 0), connection: connection,
                                  rate: TrafficRate(download: download, upload: upload), transferred: .zero,
                                  isNew: isNew, isGone: isGone)
    }

    static func processActivity(
        _ pid: Int32, _ name: String = "app", download: Double = 0, upload: Double = 0, transferred: UInt64 = 0,
        connections: [ConnectionActivity] = [], isGone: Bool = false
    ) -> ProcessActivity {
        ProcessActivity(key: ProcessKey(pid: pid, startTime: 1), shortName: name,
                        rate: TrafficRate(download: download, upload: upload),
                        transferred: ByteTotals(received: transferred, sent: 0), connections: connections, isGone: isGone)
    }

    static func activityFrame(_ processes: [ProcessActivity], programs: [Int32: NetworkProgram] = [:],
                              pendingSignatures: Set<Int32> = []) -> ActivityFrame {
        ActivityFrame(
            report: TrafficReport(processes: processes, total: processes.reduce(.zero) { $0 + $1.rate },
                                  history: [], skippedLineCount: 0),
            programs: Dictionary(uniqueKeysWithValues: programs.map { (ProcessKey(pid: $0.key, startTime: 1), $0.value) }),
            pendingSignatures: Set(pendingSignatures.map { ProcessKey(pid: $0, startTime: 1) })
        )
    }
}
