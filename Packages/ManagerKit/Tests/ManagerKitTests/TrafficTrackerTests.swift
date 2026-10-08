import Foundation
import Testing
@testable import ManagerKit

@Suite struct TrafficTrackerTests {
    private let t0 = ContinuousClock.now

    private func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    /// Ein Prozess, der schon vor dem Öffnen lief (Startzeit 1), sofern `started` nichts anderes sagt.
    private func process(_ pid: Int32, _ name: String = "app", received: UInt64?, sent: UInt64?,
                         connections: [ConnectionTraffic] = [], started: UInt64? = 1) -> ProcessTraffic {
        ProcessTraffic(pid: pid, shortName: name, bytesIn: received, bytesOut: sent, connections: connections,
                       startTime: started)
    }

    private func tcp(_ port: UInt16, received: UInt64? = 0, sent: UInt64? = 0, state: String = "Established")
        -> ConnectionTraffic {
        ConnectionTraffic(transport: .tcp, ipVersion: .v4, local: ConnectionEndpoint(address: "192.0.2.1", port: 50000),
                          remote: ConnectionEndpoint(address: "192.0.2.10", port: port), state: state,
                          bytesIn: received, bytesOut: sent)
    }

    private func sample(_ processes: ProcessTraffic...) -> NettopSample { NettopSample(processes: processes) }

    /// Ansicht geöffnet bei 1 000 000 000 µs seit 1970.
    private static let openedAt: UInt64 = 1_000_000_000

    private func tracker() -> TrafficTracker {
        TrafficTracker(wallClock: { Self.openedAt })
    }

    @Test func firstSampleIsOnlyBaseline() {
        var tracker = tracker()
        let report = tracker.update(with: sample(process(7, received: 5000, sent: 100)), at: at(0))
        #expect(report.processes.first?.rate == .zero)
        #expect(report.processes.first?.transferred == .zero)
        #expect(report.history.isEmpty)
    }

    @Test func rateIsDifferenceOverElapsedTime() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 1000, sent: 0)), at: at(0))
        let report = tracker.update(with: sample(process(7, received: 3000, sent: 1000)), at: at(2))
        #expect(report.processes.first?.rate == TrafficRate(download: 1000, upload: 500))
        #expect(report.processes.first?.transferred == ByteTotals(received: 2000, sent: 1000))
        #expect(report.total == TrafficRate(download: 1000, upload: 500))
        #expect(report.history == [TrafficRate(download: 1000, upload: 500)])
    }

    @Test func smoothsOverLastThreeSteps() {
        var tracker = tracker()
        var received: UInt64 = 0
        var report = TrafficReport.empty
        for (second, step) in [0, 100, 400, 700, 1000].enumerated() {
            received += UInt64(step)
            report = tracker.update(with: sample(process(7, received: received, sent: 0)), at: at(second))
        }
        #expect(report.processes.first?.rate.download == 700)
        #expect(report.processes.first?.transferred.received == 2200)
    }

    /// Ein sinkender Zähler (neuer Socket unter gleichem Schlüssel) ergibt Rate 0 und eine neue Basis; die Raten davor
    /// wirken in der Glättung nicht nach.
    @Test func decreasingCounterStartsNewBaseline() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(0))
        _ = tracker.update(with: sample(process(7, received: 1000, sent: 0)), at: at(1))
        let busy = tracker.update(with: sample(process(7, received: 2000, sent: 0)), at: at(2))
        #expect(busy.processes.first?.rate.download == 1000)
        let dropped = tracker.update(with: sample(process(7, received: 500, sent: 0)), at: at(3))
        #expect(dropped.processes.first?.rate == .zero)
        let report = tracker.update(with: sample(process(7, received: 1500, sent: 0)), at: at(4))
        #expect(report.processes.first?.rate.download == 500)
        #expect(report.processes.first?.transferred.received == 3000)
    }

    /// Dieselbe PID mit anderer Startzeit ist ein neuer Prozess: keine geerbten Zahlen, der Vorgänger verschwindet.
    @Test func reusedPIDStartsNewProcess() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 1000, sent: 0, started: 100)), at: at(0))
        _ = tracker.update(with: sample(process(7, received: 5000, sent: 0, started: 100)), at: at(2))
        let report = tracker.update(with: sample(process(7, "neu", received: 9000, sent: 0, started: 200)), at: at(4))
        let successor = report.processes.first { $0.key == ProcessKey(pid: 7, startTime: 200) }
        let predecessor = report.processes.first { $0.key == ProcessKey(pid: 7, startTime: 100) }
        #expect(successor?.rate == .zero)
        #expect(successor?.transferred == .zero)
        #expect(successor?.isGone == false)
        #expect(predecessor?.isGone == true)
        #expect(predecessor?.rate == .zero)
        #expect(predecessor?.transferred.received == 4000)
    }

    /// Endet ein Prozess, bevor seine Zeile erfasst wurde, ist seine Startzeit unbekannt: Ein bekannter Prozess mit
    /// dieser PID ist derselbe – seine Abschlusswerte schreiben die Summe fort, statt eine zweite Zeile als Basis zu
    /// beginnen.
    @Test func unknownStartTimeContinuesKnownProcessWithSamePID() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 1000, sent: 0, started: 100)), at: at(0))
        _ = tracker.update(with: sample(process(7, received: 2000, sent: 0, started: 100)), at: at(2))
        let report = tracker.update(with: sample(process(7, received: 12000, sent: 0, started: nil)), at: at(4))
        #expect(report.processes.map(\.key) == [ProcessKey(pid: 7, startTime: 100)])
        #expect(report.processes.first?.transferred.received == 11000)
        #expect(report.processes.first?.isGone == false)
    }

    /// Ohne Startzeit und ohne bekannten Prozess dieser PID beginnt eine Basis unter Startzeit 0.
    @Test func unknownStartTimeWithoutKnownProcessIsBaseline() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(0))
        let report = tracker.update(with: sample(process(9, received: 4000, sent: 0, started: nil)), at: at(2))
        let unknown = report.processes.first { $0.key.pid == 9 }
        #expect(unknown?.key.startTime == 0)
        #expect(unknown?.transferred == .zero)
    }

    @Test func newConnectionsAreMarkedForTenSeconds() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443)])), at: at(0))
        let appeared = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443), tcp(22)])),
                                      at: at(2))
        let newByPort = Dictionary(uniqueKeysWithValues: appeared.processes[0].connections.map {
            ($0.connection.remote.port, $0.isNew)
        })
        #expect(newByPort == [443: false, 22: true])
        let later = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443), tcp(22)])),
                                   at: at(12))
        #expect(later.processes[0].connections.allSatisfy { !$0.isNew })
    }

    @Test func vanishedConnectionStaysGreyedForTenSeconds() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443, received: 10)])),
                           at: at(0))
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443, received: 50)])),
                           at: at(2))
        let gone = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(4))
        #expect(gone.processes[0].connections.map(\.isGone) == [true])
        #expect(gone.processes[0].connections[0].rate == .zero)
        #expect(gone.processes[0].connections[0].transferred.received == 40)
        let removed = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(14))
        #expect(removed.processes[0].connections.isEmpty)
    }

    @Test func vanishedProcessStaysGreyedForTenSeconds() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443)]),
                                        process(8, received: 0, sent: 0)), at: at(0))
        let gone = tracker.update(with: sample(process(8, received: 0, sent: 0)), at: at(2))
        let vanished = gone.processes.first { $0.key.pid == 7 }
        #expect(vanished?.isGone == true)
        #expect(vanished?.connections.allSatisfy { $0.isGone } == true)
        let removed = tracker.update(with: sample(process(8, received: 0, sent: 0)), at: at(12))
        #expect(removed.processes.map(\.key.pid) == [8])
    }

    @Test func ignoresListeningSockets() {
        var tracker = tracker()
        let report = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [
            tcp(443), ConnectionTraffic(transport: .tcp, ipVersion: .v4, local: ConnectionEndpoint(address: nil, port: 8080),
                                        remote: ConnectionEndpoint(address: nil, port: nil), state: "Listen",
                                        bytesIn: nil, bytesOut: nil),
        ])), at: at(0))
        #expect(report.processes[0].connections.map(\.connection.remote.port) == [443])
    }

    /// Lauschende TCP-Ports bleiben als Merkmal des Prozesses erhalten (eingehende Verbindungen im Dienst-Detail).
    @Test func recordsListeningTCPPorts() {
        var tracker = tracker()
        let listen = ConnectionTraffic(transport: .tcp, ipVersion: .v4, local: ConnectionEndpoint(address: nil, port: 8080),
                                       remote: ConnectionEndpoint(address: nil, port: nil), state: "Listen",
                                       bytesIn: nil, bytesOut: nil)
        let report = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443), listen])),
                                    at: at(0))
        #expect(report.processes[0].listeningTCPPorts == [8080])
    }

    /// Verlauf je Prozess: ab der zweiten Messung, ausgegraut mit Rate 0, höchstens `historyLength` Punkte.
    @Test func processHistoryFollowsItsRates() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(0))
        var report = tracker.update(with: sample(process(7, received: 2000, sent: 0)), at: at(2))
        #expect(report.processes[0].history == [TrafficRate(download: 1000, upload: 0)])
        report = tracker.update(with: sample(), at: at(4))
        #expect(report.processes[0].history.last == .zero)
        #expect(report.processes[0].history.count == 2)

        for second in stride(from: 6, through: 200, by: 2) {
            report = tracker.update(with: sample(process(8, received: UInt64(second), sent: 0)), at: at(second))
        }
        #expect(report.processes.first { $0.key.pid == 8 }?.history.count == TrafficTracker.historyLength)
    }

    /// Gleich aussehende Sockets (`udp4 *:*<->*:*`) bleiben getrennte Verbindungen.
    @Test func identicalSocketsGetOrdinals() {
        let unbound = ConnectionTraffic(transport: .udp, ipVersion: .v4, local: ConnectionEndpoint(address: nil, port: nil),
                                        remote: ConnectionEndpoint(address: nil, port: nil), state: "",
                                        bytesIn: nil, bytesOut: nil)
        var tracker = tracker()
        let report = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [unbound, unbound])),
                                    at: at(0))
        #expect(report.processes[0].connections.map(\.key.ordinal) == [0, 1])
    }

    @Test func totalSumsProcessesAndHistoryKeepsLastSixty() {
        var tracker = tracker()
        var report = TrafficReport.empty
        for second in 0...65 {
            let bytes = UInt64(second * 100)
            report = tracker.update(with: sample(process(7, received: bytes, sent: 0), process(8, received: 0, sent: bytes)),
                                    at: at(second))
        }
        #expect(report.total == TrafficRate(download: 100, upload: 100))
        #expect(report.history.count == TrafficTracker.historyLength)
    }

    /// Ein Prozess, der nach dem Öffnen startet, zählt mit allen Bytes – sonst bliebe kurzer Verkehr (curl) unsichtbar.
    @Test func processStartedAfterOpeningCountsFully() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(0))
        let report = tracker.update(with: sample(process(7, received: 0, sent: 0),
                                                 process(9, "curl", received: 4000, sent: 1000,
                                                         started: Self.openedAt + 500_000)), at: at(2))
        let curl = report.processes.first { $0.key.pid == 9 }
        #expect(curl?.transferred == ByteTotals(received: 4000, sent: 1000))
        #expect(curl?.rate == TrafficRate(download: 2000, upload: 500))
        #expect(report.total == TrafficRate(download: 2000, upload: 500))
    }

    /// Ein Prozess, der schon vor dem Öffnen lief und erst später auftaucht, ist Basis – seine Bytes stammen von vorher.
    @Test func processStartedBeforeOpeningIsBaseline() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(0))
        let report = tracker.update(with: sample(process(9, received: 4000, sent: 1000,
                                                         started: Self.openedAt - 60_000_000)), at: at(2))
        let late = report.processes.first { $0.key.pid == 9 }
        #expect(late?.transferred == .zero)
        #expect(late?.rate == .zero)
    }

    /// Eine Verbindung nach der ersten Messung ist neu: Ihr Zähler läuft seit Öffnen des Sockets, alles zählt.
    @Test func newConnectionCountsFromSocketOpen() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 10, sent: 0, connections: [tcp(443, received: 10)])),
                           at: at(0))
        let report = tracker.update(with: sample(process(7, received: 360, sent: 0, connections: [
            tcp(443, received: 60), tcp(22, received: 300),
        ])), at: at(2))
        let byPort = Dictionary(uniqueKeysWithValues: report.processes[0].connections.map {
            ($0.connection.remote.port, $0)
        })
        #expect(byPort[443]?.transferred.received == 50)
        #expect(byPort[22]?.transferred.received == 300)
        #expect(byPort[22]?.rate.download == 150)
    }

    /// Die Rate teilt durch die Zeit seit den letzten Werten dieses Zählers, nicht seit der letzten Messung.
    @Test func rateAfterGapUsesTimeSinceLastValues() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0, connections: [tcp(443, received: 0)])),
                           at: at(0))
        _ = tracker.update(with: sample(process(7, received: 100, sent: 0, connections: [tcp(443, received: 100)])),
                           at: at(2))
        _ = tracker.update(with: sample(process(8, received: 0, sent: 0)), at: at(4))
        let back = tracker.update(with: sample(process(7, received: 500, sent: 0, connections: [tcp(443, received: 500)])),
                                  at: at(6))
        let process = back.processes.first { $0.key.pid == 7 }
        #expect(process?.isGone == false)
        #expect(process?.rate.download == 100)
        #expect(process?.connections.first?.rate.download == 100)
        #expect(process?.transferred.received == 500)
    }

    /// Leere Byte-Felder einer Prozesszeile pausieren den Zähler (Rate 0), statt als 0 einen Rücksprung vorzutäuschen.
    @Test func emptyProcessFieldsPauseCounter() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 100, sent: 0)), at: at(0))
        let paused = tracker.update(with: sample(process(7, received: nil, sent: nil)), at: at(2))
        #expect(paused.processes.first?.rate == .zero)
        let report = tracker.update(with: sample(process(7, received: 500, sent: 0)), at: at(4))
        #expect(report.processes.first?.rate.download == 100)
        #expect(report.processes.first?.transferred.received == 400)
    }

    /// Ohne Zeitabstand gibt es keine Rate, die Bytes zählen trotzdem zur Summe.
    @Test func bytesWithoutElapsedTimeStillCount() {
        var tracker = tracker()
        _ = tracker.update(with: sample(process(7, received: 0, sent: 0)), at: at(0))
        _ = tracker.update(with: sample(process(7, received: 1000, sent: 0)), at: at(2))
        let report = tracker.update(with: sample(process(7, received: 1600, sent: 0)), at: at(2))
        #expect(report.processes.first?.transferred.received == 1600)
        #expect(report.processes.first?.rate.download == 500)
    }
}
