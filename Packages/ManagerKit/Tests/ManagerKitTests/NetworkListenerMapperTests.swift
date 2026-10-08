import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkListenerMapperTests {
    private let inspector = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
    private var mapper: NetworkListenerMapper { NetworkListenerMapper(inspector: inspector) }

    /// `systemAssigned`: `nil` wie ein älterer Helper ohne das Kernel-Flag – dann zählt der Portbereich.
    private func listening(_ transport: SocketTransport, _ address: String, _ port: UInt16, pid: Int32 = 10,
                           path: String = "/opt/homebrew/bin/node", ancestors: [String] = [],
                           systemAssigned: Bool? = nil) -> ListeningSocket {
        ListeningSocket(pid: pid, uid: 501, executablePath: path, transport: transport, localAddress: address,
                        localPort: port, ancestors: ancestors, hasSystemAssignedPort: systemAssigned)
    }

    @Test func mergesIPv4AndIPv6AndProcesses() {
        let listeners = mapper.listeners(from: [
            listening(.tcp, "0.0.0.0", 3000, pid: 10), listening(.tcp, "::", 3000, pid: 10), listening(.tcp, "::", 3000, pid: 11),
        ], at: TestData.date)
        #expect(listeners.count == 1)
        #expect(listeners.first?.addresses == ["0.0.0.0", "::"])
        #expect(listeners.first?.reachability == .network(allInterfaces: true))
    }

    /// Ohne das Kernel-Flag (älterer Helper) entscheidet der Portbereich.
    @Test func ephemeralTCPPortsCollapseWithoutTheFlag() {
        let listeners = mapper.listeners(from: [listening(.tcp, "127.0.0.1", 61086), listening(.tcp, "127.0.0.1", 59407)],
                                         at: TestData.date)
        #expect(listeners.map(\.port) == [nil])
    }

    /// Vom System vergebene Ports (`bind(0)`) sind „wechselnd“ – auch außerhalb des Ephemeralbereichs, etwa bei
    /// verändertem `net.inet.ip.portrange`.
    @Test func systemAssignedPortsCollapse() {
        let listeners = mapper.listeners(from: [
            listening(.tcp, "127.0.0.1", 61086, systemAssigned: true), listening(.tcp, "127.0.0.1", 1234, systemAssigned: true),
        ], at: TestData.date)
        #expect(listeners.map(\.port) == [nil])
    }

    /// Ein ausdrücklich gewählter Port bleibt fest, auch im Ephemeralbereich: WireGuard auf 51820 ist ein Dienst, kein
    /// STUN-Client mit Zufallsport.
    @Test func explicitlyChosenPortInEphemeralRangeIsKept() {
        let listeners = mapper.listeners(from: [
            listening(.udp, "::", 51820, path: "/usr/local/bin/wireguard-go", systemAssigned: false),
            listening(.tcp, "0.0.0.0", 50000, path: "/usr/local/bin/wireguard-go", systemAssigned: false),
        ], at: TestData.date)
        #expect(listeners.map(\.port) == [50000, 51820])
    }

    /// UDP im Ephemeralbereich bleibt sichtbar (Hintertür auf `0.0.0.0`): Zufallsports fallen wie bei TCP zu
    /// „wechselnd“ zusammen; die Ausnahme für Clients trifft erst die Bewertung (`isBenignClientUDP`).
    @Test func ephemeralUDPIsKeptAsVariable() {
        let listeners = mapper.listeners(from: [
            listening(.udp, "0.0.0.0", 52874, systemAssigned: true), listening(.udp, "0.0.0.0", 61000, systemAssigned: true),
            listening(.udp, "0.0.0.0", 5353, systemAssigned: false),
        ], at: TestData.date)
        #expect(listeners.map(\.port) == [5353, nil])
        #expect(listeners.last?.reachability == .network(allInterfaces: true))
        #expect(mapper.listeners(from: [listening(.udp, "::", 51820, path: "/usr/local/bin/wireguard-go")], at: TestData.date)
            .map(\.port) == [nil], "ohne Flag zählt der Bereich")
    }

    @Test func keepsAncestorsAndTimes() {
        let listener = mapper.listeners(from: [listening(.tcp, "0.0.0.0", 6768, ancestors: ["/Applications/Orca.app/Contents/MacOS/Orca"])],
                                        at: TestData.date).first
        #expect(listener?.ancestorPaths == ["/Applications/Orca.app/Contents/MacOS/Orca"])
        #expect(listener?.firstSeenAt == TestData.date)
        #expect(listener?.lastSeenAt == TestData.date)
        #expect(listener?.signing.kind == .adHoc)
    }

    /// Die Elternkette stammt vom Prozess mit der kleinsten PID – unabhängig von der Reihenfolge der Sockets.
    @Test func ancestorsComeFromLowestPID() {
        let listener = mapper.listeners(from: [
            listening(.tcp, "::", 3000, pid: 12, ancestors: ["/b"]), listening(.tcp, "0.0.0.0", 3000, pid: 11, ancestors: ["/a"]),
        ], at: TestData.date).first
        #expect(listener?.ancestorPaths == ["/a"])
    }

    @Test func distinctPortsStaySeparateAndSorted() {
        let ids = mapper.listeners(from: [listening(.tcp, "0.0.0.0", 8080), listening(.tcp, "0.0.0.0", 3000)], at: TestData.date)
            .map(\.id)
        #expect(ids == ["/opt/homebrew/bin/node|501|tcp|3000", "/opt/homebrew/bin/node|501|tcp|8080"])
    }

    @Test func inspectsSigningOncePerPath() {
        _ = mapper.listeners(from: [
            listening(.tcp, "0.0.0.0", 3000), listening(.tcp, "0.0.0.0", 8080), listening(.udp, "0.0.0.0", 5353),
            listening(.tcp, "0.0.0.0", 22, path: "/usr/sbin/sshd"),
        ], at: TestData.date)
        #expect(inspector.paths.sorted() == ["/opt/homebrew/bin/node", "/usr/sbin/sshd"])
    }

    /// `inet_ntop` gescheitert: Der Scanner liefert `""`. Die leere Adresse fällt weg, der Lauscher bleibt und gilt
    /// ohne bekannte Adresse konservativ als im Netzwerk erreichbar.
    @Test func dropsEmptyAddressesButKeepsListener() {
        let mixed = mapper.listeners(from: [listening(.tcp, "", 3000), listening(.tcp, "127.0.0.1", 3000)], at: TestData.date)
        #expect(mixed.first?.addresses == ["127.0.0.1"])
        #expect(mixed.first?.reachability == .thisMac)

        let unknown = mapper.listeners(from: [listening(.tcp, "", 3000)], at: TestData.date)
        #expect(unknown.count == 1)
        #expect(unknown.first?.addresses == [])
        #expect(unknown.first?.reachability == .network(allInterfaces: false))
    }
}
