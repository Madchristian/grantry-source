import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkConnectionsPresentationTests {
    private func listening(_ port: UInt16, address: String? = nil, version: IPVersion = .v4) -> ConnectionTraffic {
        ConnectionTraffic(transport: .tcp, ipVersion: version, local: ConnectionEndpoint(address: address, port: port),
                          remote: ConnectionEndpoint(address: nil, port: nil), state: "Listen", bytesIn: nil,
                          bytesOut: nil)
    }

    private func socket(_ transport: ConnectionTransport = .tcp, local: String? = "192.168.1.24", _ localPort: UInt16? = 50000,
                        remote: String? = nil, _ remotePort: UInt16? = nil, state: String = "Established",
                        isGone: Bool = false) -> ConnectionActivity {
        let traffic = ConnectionTraffic(
            transport: transport, ipVersion: (remote ?? local ?? "").contains(":") ? .v6 : .v4,
            local: ConnectionEndpoint(address: local, port: localPort),
            remote: ConnectionEndpoint(address: remote, port: remotePort),
            state: transport == .tcp ? state : "", bytesIn: 0, bytesOut: 0
        )
        return ConnectionActivity(key: ConnectionKey(traffic, ordinal: 0), connection: traffic,
                                  rate: TrafficRate(download: 10, upload: 5), transferred: ByteTotals(received: 100, sent: 50),
                                  isNew: false, isGone: isGone)
    }

    private func process(_ pid: Int32, _ name: String, connections: [ConnectionActivity] = [],
                         listening: [ConnectionTraffic] = [], uid: UInt32? = 501, isGone: Bool = false) -> ProcessActivity {
        ProcessActivity(key: ProcessKey(pid: pid, startTime: 1), shortName: name, rate: .zero, transferred: .zero,
                        connections: connections, isGone: isGone, listeningSockets: listening, uid: uid)
    }

    private func presentation(_ processes: [ProcessActivity], filter: NetworkConnectionFilter = .all, query: String = "",
                              programs: [Int32: NetworkProgram] = [:],
                              regions: RemoteRegionResolver = .unavailable) -> NetworkConnectionsPresentation {
        NetworkConnectionsPresentation(frame: TestData.activityFrame(processes, programs: programs), filter: filter,
                                       query: query, userName: { $0 == 0 ? "root" : "anna" }, regions: regions)
    }

    /// Feste Zuordnung der Dokumentationsnetze: `192.0.2.0/24` Deutschland, `198.51.100.0/24` USA, `2001:db8::/32`
    /// Niederlande; `203.0.113.0/24` hat keinen Eintrag.
    private static let regions = RemoteRegionResolver(dataDate: DateComponents(year: 2026, month: 11, day: 13)) {
        if $0.hasPrefix("192.0.2.") { "DE" } else if $0.hasPrefix("198.51.100.") { "US" }
        else if $0.hasPrefix("2001:db8:") { "NL" } else { nil }
    }
    private static let german = Locale(identifier: "de_DE")

    /// Verbindungen in drei Länder, ohne Eintrag, ins lokale Netz und über Loopback, dazu lauschende Sockets.
    private var travelling: [ProcessActivity] {
        [
            process(10, "safari", connections: [
                socket(remote: "192.0.2.10", 443), socket(local: "192.168.1.24", 50001, remote: "192.0.2.11", 443),
                socket(local: "fd00::24", 50002, remote: "2001:db8::44", 443),
                socket(.quic, local: "192.168.1.24", 50003, remote: "198.51.100.7", 443),
            ]),
            process(11, "mail", connections: [socket(remote: "203.0.113.25", 993)]),
            process(20, "node", connections: [socket(local: "192.168.1.24", 3000, remote: "192.168.1.20", 61000)],
                    listening: [listening(3000)]),
            process(30, "postgres", connections: [socket(local: "127.0.0.1", 5432, remote: "127.0.0.1", 52000)],
                    listening: [listening(5432, address: "127.0.0.1")]),
        ]
    }

    private var sample: [ProcessActivity] {
        [
            process(10, "safari", connections: [socket(remote: "203.0.113.5", 443)]),
            process(20, "node", connections: [socket(local: "192.168.1.24", 3000, remote: "192.168.1.20", 61000)],
                    listening: [listening(3000), listening(3000, version: .v6)]),
            process(30, "postgres", connections: [socket(local: "127.0.0.1", 5432, remote: "127.0.0.1", 52000)],
                    listening: [listening(5432, address: "127.0.0.1")]),
            process(40, "mDNSResponder", connections: [socket(.udp, local: nil, 5353),
                                                       socket(.udp, local: nil, nil)], uid: 0),
        ]
    }

    @Test func ordersListeningThenBoundThenConnectedByName() {
        let rows = presentation(sample).rows
        #expect(rows.map(\.kind) == [.listening, .listening, .listening, .bound, .connected, .connected, .connected])
        #expect(rows.map(\.title) == ["node", "node", "postgres", "mDNSResponder", "node", "postgres", "safari"])
    }

    /// Unbelegte UDP-Sockets (`*:*<->*:*`) erscheinen nicht.
    @Test func skipsUnboundPlaceholders() {
        let rows = presentation(sample).all.filter { $0.title == "mDNSResponder" }
        #expect(rows.map(\.localText) == ["*:5353"])
    }

    @Test func showsTCPStatesAndUDPKinds() {
        let rows = presentation([process(1, "a", connections: [
            socket(remote: "203.0.113.5", 443, state: "TimeWait"), socket(.udp, local: nil, 5353),
            socket(.quic, remote: "198.51.100.7", 443),
        ], listening: [listening(80)])]).rows
        #expect(rows.map(\.stateText) == ["LISTEN", "BOUND", "CONNECTED", "TIME_WAIT"])
        #expect(rows.map(\.protocolText) == ["TCP", "UDP", "QUIC", "TCP"])
        #expect(rows.map(\.service) == ["HTTP", "mDNS", "HTTPS (QUIC)", "HTTPS"])
    }

    @Test func classifiesExposureWithoutDNS() {
        let rows = presentation([process(1, "a", connections: [
            socket(remote: "203.0.113.5", 443), socket(remote: "10.0.0.2", 22), socket(remote: "fd00::5", 22),
            socket(remote: "fe80::1%en0", 22), socket(local: "127.0.0.1", 1, remote: "127.0.0.1", 2),
        ], listening: [listening(80), listening(81, address: "::1"), listening(82, address: "192.168.1.24")])]).all
        let exposure = Dictionary(uniqueKeysWithValues: rows.map { ($0.remoteText == "–" ? $0.localText : $0.remoteText,
                                                                     $0.exposure) })
        #expect(exposure["*:80"] == .allInterfaces)
        #expect(exposure["[::1]:81"] == .thisMac)
        #expect(exposure["192.168.1.24:82"] == .localNetwork)
        #expect(exposure["203.0.113.5:443"] == .internet)
        #expect(exposure["10.0.0.2:22"] == .localNetwork)
        #expect(exposure["[fd00::5]:22"] == .localNetwork)
        #expect(exposure["[fe80::1%en0]:22"] == .localNetwork)
        #expect(exposure["127.0.0.1:2"] == .thisMac)
    }

    @Test func countsOpenSocketsPortsExposedAndProcesses() {
        var processes = sample
        processes.append(process(50, "curl", connections: [socket(remote: "203.0.113.9", 443, isGone: true)]))
        let counts = presentation(processes).counts
        #expect(counts.sockets == 7)
        // 3000 (IPv4 und IPv6) und 5432.
        #expect(counts.listeningPorts == 2)
        // node *:3000 zweimal und mDNS *:5353; postgres lauscht nur auf Loopback.
        #expect(counts.exposed == 3)
        #expect(counts.processes == 4)
    }

    /// Bewertung 2026.11.7-1188, Mangel 15: „x von y angezeigt“ zählt wie Kachel und Statusleiste nur offene Sockets.
    @Test func shownCountUsesOpenSocketsLikeTheTiles() {
        var processes = sample
        processes.append(process(50, "curl", connections: [socket(remote: "203.0.113.9", 443, isGone: true)]))
        let all = presentation(processes)
        #expect(all.rows.count == 8)
        #expect(all.shownCount == 7)
        #expect(all.shownCount == all.counts.sockets)
        let searched = presentation(processes, query: "node")
        #expect(searched.shownCount == 3)
        #expect(searched.counts.sockets == 7)
    }

    @Test func filtersBySegment() {
        func titles(_ filter: NetworkConnectionFilter) -> [String] { presentation(sample, filter: filter).rows.map(\.title) }
        #expect(titles(.connected) == ["node", "postgres", "safari"])
        #expect(titles(.listening) == ["node", "node", "postgres"])
        #expect(titles(.exposed) == ["node", "node", "mDNSResponder"])
        #expect(titles(.udp) == ["mDNSResponder"])
        #expect(titles(.loopback) == ["postgres", "postgres"])
        #expect(presentation(sample).count(for: .listening) == 3)
    }

    @Test func searchesByProcessNameIgnoringCase() {
        let rows = presentation(sample, query: " NOD ").rows
        #expect(Set(rows.map(\.title)) == ["node"])
    }

    /// TM-11.5 (#374): Eine Portnummer findet lauschende Sockets und Verbindungen auf beiden Seiten, nur ganz.
    @Test func searchesByExactLocalOrRemotePort() {
        #expect(presentation(sample, query: "443").rows.map(\.title) == ["safari"])
        #expect(presentation(sample, query: " 5432 ").rows.map(\.stateText) == ["LISTEN", "ESTABLISHED"])
        #expect(presentation(sample, filter: .listening, query: "3000").rows.count == 2)
        #expect(presentation(sample, query: "44").rows.isEmpty)
    }

    @Test func namesUserFromUIDAndShowsPID() {
        var processes = sample
        processes.append(process(60, "unbekannt", connections: [socket(remote: "203.0.113.9", 443)], uid: nil))
        let rows = presentation(processes).all
        #expect(rows.first { $0.title == "mDNSResponder" }?.user == "root")
        #expect(rows.first { $0.title == "safari" }?.user == "anna")
        #expect(rows.first { $0.title == "unbekannt" }?.user == nil)
        #expect(rows.first { $0.title == "safari" }?.pid == 10)
    }

    @Test func usesProgramTitleAndFindsRowsOutsideTheFilter() {
        let program = NetworkProgram(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                                     signing: SigningInfo(kind: .apple))
        let presentation = presentation(sample, filter: .listening, programs: [10: program])
        let safari = presentation.all.first { $0.pid == 10 }
        #expect(safari?.title == "Safari")
        #expect(presentation.rows.contains { $0.pid == 10 } == false)
        #expect(presentation.row(withID: safari?.id) == safari)
    }

    @Test func findsTheScannedServiceOfAListeningSocket() {
        let path = "/opt/homebrew/bin/node"
        func listener(_ port: UInt16?, _ transport: SocketTransport = .tcp, uid: UInt32 = 501) -> NetworkListener {
            NetworkListener(executablePath: path, uid: uid, transport: transport, port: port, addresses: ["0.0.0.0"],
                            signing: SigningInfo(kind: .adHoc), firstSeenAt: .now, lastSeenAt: .now)
        }
        let rows = presentation(sample, programs: [20: NetworkProgram(executablePath: path, signing: SigningInfo(kind: .adHoc))]).all
            .filter { $0.title == "node" }
        let listening = rows.first { $0.kind == .listening }
        let connected = rows.first { $0.kind == .connected }
        #expect(listening?.listener(in: [listener(8080), listener(3000)])?.port == 3000)
        #expect(listening?.listener(in: [listener(nil)])?.port == nil)
        #expect(listening?.listener(in: [listener(nil)]) != nil)
        #expect(listening?.listener(in: [listener(3000, .udp)]) == nil)
        #expect(listening?.listener(in: [listener(3000, uid: 0)]) == nil)
        #expect(connected?.listener(in: [listener(3000)]) == nil)
    }

    /// Geschlossene Sockets bleiben ausgegraut sichtbar, zählen aber nicht.
    @Test func keepsClosedSocketsVisibleButUncounted() {
        let presentation = presentation([process(1, "a", connections: [socket(remote: "203.0.113.5", 443, isGone: true)])])
        #expect(presentation.rows.map(\.isGone) == [true])
        #expect(presentation.counts == .zero)
    }

    /// Gruppen nach Erreichbarkeit (Gestaltung „Lagebild“): lauschend auf allen Schnittstellen „aus dem Netz“, auf
    /// Loopback „nur dieser Mac“, Verbindungen für sich.
    @Test func groupsSocketsByReach() {
        let rows = presentation([
            process(1, "node", listening: [listening(3000)]),
            process(2, "postgres", listening: [listening(5432, address: "127.0.0.1")]),
            process(3, "safari", connections: [socket(remote: "203.0.113.5", 443)]),
        ]).all
        #expect(rows.first { $0.title == "node" }?.reach == .network)
        #expect(rows.first { $0.title == "postgres" }?.reach == .thisMac)
        #expect(rows.first { $0.title == "safari" }?.reach == .connected)
    }

    @Test func verdictNamesSocketsReachableFromTheNetwork() {
        let exposed = presentation([process(1, "node", listening: [listening(3000)])]).verdict(firewallOn: true)
        #expect(exposed.level == .finding)
        #expect(exposed.title == "1 Socket aus dem Netz erreichbar")
        #expect(exposed.items.map(\.text) == ["Firewall an"])
        let local = presentation([process(2, "postgres", listening: [listening(5432, address: "127.0.0.1")])])
            .verdict(firewallOn: nil)
        #expect(local.level == .calm)
        #expect(local.title == "Nur von diesem Mac erreichbar")
        #expect(presentation([]).verdict(firewallOn: false).level == .finding)
    }

    // MARK: Nach Land (#630)

    @Test func rowsCarryTheRegionOfTheirRemoteAddress() {
        let rows = presentation(travelling, regions: Self.regions).all
        func regions(of title: String) -> [RemoteRegion?] { rows.filter { $0.title == title }.map(\.region) }
        #expect(Set(regions(of: "safari")) == [.country("DE"), .country("NL"), .country("US")])
        #expect(regions(of: "mail") == [.unknown])
        // Lauschende Sockets haben keine Gegenstelle und damit keine Region.
        #expect(regions(of: "node") == [nil, .localNetwork])
        #expect(regions(of: "postgres") == [nil, .thisMac])
    }

    @Test func tcpConnectionsCarryTheirDirection() {
        let rows = presentation(travelling, regions: Self.regions).all.filter { $0.kind == .connected }
        #expect(rows.first { $0.title == "node" }?.direction == .inbound)
        #expect(rows.first { $0.title == "mail" }?.direction == .outbound)
        #expect(rows.first { $0.socket.transport == .quic }?.direction == nil)
        #expect(presentation(travelling).all.filter { $0.kind != .connected }.allSatisfy { $0.direction == nil })
    }

    @Test func groupsConnectionsByCountryBusiestFirstThenByName() {
        let sections = presentation(travelling, regions: Self.regions).sections(by: .country, locale: Self.german)
        #expect(sections.map(\.title) == ["Deutschland", "Niederlande", "Vereinigte Staaten",
                                          "Land unbekannt (kein Eintrag)", "Lokales Netz (ohne Land)",
                                          "Dieser Mac (ohne Land)"])
        #expect(sections.map(\.openCount) == [2, 1, 1, 1, 1, 1])
        #expect(sections[0].rows.map(\.remoteText) == ["192.0.2.10:443", "192.0.2.11:443"])
    }

    /// Private und lokale Adressen stehen nie unter einem Land – auch nicht, wenn die Tabelle eines nennen würde.
    @Test func localAndPrivateAddressesNeverJoinACountry() {
        let everywhere = RemoteRegionResolver(dataDate: nil) { _ in "DE" }
        let sections = presentation(travelling, regions: everywhere).sections(by: .country, locale: Self.german)
        let germany = sections.first { $0.title == "Deutschland" }
        #expect(germany?.rows.allSatisfy { IPAddressScope.isPublic($0.socket.remote.address ?? "") } == true)
        #expect(sections.map(\.title).suffix(2) == ["Lokales Netz (ohne Land)", "Dieser Mac (ohne Land)"])
    }

    @Test func countrySectionsLeaveOutSocketsWithoutARemoteAddress() {
        let presentation = presentation(travelling, regions: Self.regions)
        let rows = presentation.sections(by: .country, locale: Self.german).flatMap(\.rows)
        #expect(rows.allSatisfy { $0.kind == .connected })
        #expect(rows.count == presentation.rows.count { $0.kind == .connected })
    }

    @Test func withoutATableEveryPublicRemoteIsUnknown() {
        let sections = presentation(travelling).sections(by: .country, locale: Self.german)
        #expect(sections.map(\.title) == ["Land unbekannt (kein Eintrag)", "Lokales Netz (ohne Land)",
                                          "Dieser Mac (ohne Land)"])
        #expect(sections[0].openCount == 5)
    }

    @Test func onlyLocalConnectionsGiveNoCountrySection() {
        let local = [process(20, "node", connections: [socket(remote: "192.168.1.20", 61000)]),
                     process(30, "postgres", connections: [socket(local: "127.0.0.1", 5432, remote: "127.0.0.1", 52000)])]
        let sections = presentation(local, regions: Self.regions).sections(by: .country, locale: Self.german)
        #expect(sections.map(\.title) == ["Lokales Netz (ohne Land)", "Dieser Mac (ohne Land)"])
    }

    @Test func countrySectionsFollowFilterAndSearch() {
        let filtered = presentation(travelling, query: "mail", regions: Self.regions)
        #expect(filtered.sections(by: .country, locale: Self.german).map(\.title) == ["Land unbekannt (kein Eintrag)"])
        let listening = presentation(travelling, filter: .listening, regions: Self.regions)
        #expect(listening.sections(by: .country, locale: Self.german).isEmpty)
    }

    @Test func closedConnectionsStayVisibleButDoNotCount() {
        let closing = [process(10, "safari", connections: [socket(remote: "192.0.2.10", 443),
                                                           socket(local: "192.168.1.24", 50001, remote: "192.0.2.11",
                                                                  443, isGone: true)])]
        let germany = presentation(closing, regions: Self.regions).sections(by: .country, locale: Self.german)[0]
        #expect(germany.rows.count == 2)
        #expect(germany.openCount == 1)
        #expect(germany.rate == TrafficRate(download: 10, upload: 5))
    }

    @Test func sectionHeaderReadsCountryCountAndTraffic() {
        let sections = presentation(travelling, regions: Self.regions).sections(by: .country, locale: Self.german)
        #expect(sections[0].rateText == "↓ 20 B/s ↑ 10 B/s")
        #expect(sections[0].accessibilityLabel(for: .country)
            == "Deutschland, 2 Verbindungen, empfängt 20 B/s, sendet 10 B/s")
        #expect(sections[1].accessibilityLabel(for: .country)
            == "Niederlande, 1 Verbindung, empfängt 10 B/s, sendet 5 B/s")
    }

    @Test func reachSectionsKeepTheirOrderAndFinding() {
        let sections = presentation(travelling, regions: Self.regions).sections(by: .reach, locale: Self.german)
        #expect(sections.map(\.title) == ["Aus dem Netz erreichbar", "Nur von diesem Mac erreichbar", "Verbindungen"])
        #expect(sections.map(\.isFinding) == [true, false, false])
        #expect(sections.map(\.tone) == [.warning, .positive, .neutral])
        #expect(sections.flatMap(\.rows).count == presentation(travelling).rows.count)
    }

    @Test func accessibilityLabelNamesRegionAndDirection() {
        let rows = presentation(travelling, regions: Self.regions).all
        let mail = rows.first { $0.title == "mail" }
        #expect(mail?.accessibilityLabel
            == "mail, PID 11, TCP IPv4, ESTABLISHED, lokal 192.168.1.24:50000, entfernt 203.0.113.25:993, Land unbekannt, ausgehend")
    }

    // MARK: Ziele des Bogenfächers (#630)

    @Test func destinationsFollowTheCountrySectionsWithTheirPrograms() {
        let destinations = presentation(travelling, regions: Self.regions).destinations(locale: Self.german)
        #expect(destinations.map(\.title) == ["Deutschland", "Niederlande", "Vereinigte Staaten", "Land unbekannt",
                                              "Lokales Netz", "Dieser Mac"])
        #expect(destinations.map(\.connectionCount) == [2, 1, 1, 1, 1, 1])
        #expect(destinations.map(\.isCountry) == [true, true, true, false, false, false])
        #expect(destinations[0].programs == [NetworkDestination.Program(title: "safari", connectionCount: 2)])
        #expect(destinations[0].region == .country("DE"))
    }

    @Test func destinationsIgnoreFilterSearchAndClosedConnections() {
        let closing = travelling + [process(12, "curl", connections: [socket(remote: "192.0.2.99", 443, isGone: true)])]
        let filtered = presentation(closing, filter: .listening, query: "node", regions: Self.regions)
        #expect(filtered.rows.count < filtered.all.count)
        let germany = filtered.destinations(locale: Self.german)[0]
        #expect(germany.connectionCount == 2)
        #expect(germany.programs.map(\.title) == ["safari"])
    }

    @Test func destinationProgramsAreOrderedByConnectionsThenName() {
        let shared = [process(10, "safari", connections: [socket(remote: "192.0.2.10", 443)]),
                      process(11, "mail", connections: [socket(remote: "192.0.2.11", 993),
                                                        socket(local: "192.168.1.24", 50001, remote: "192.0.2.12", 993)]),
                      process(12, "curl", connections: [socket(remote: "192.0.2.13", 443)])]
        let germany = presentation(shared, regions: Self.regions).destinations(locale: Self.german)[0]
        #expect(germany.programs.map(\.title) == ["mail", "curl", "safari"])
        #expect(germany.accessibilityLabel == "Deutschland, 4 Verbindungen: mail 2, curl 1, safari 1")
    }

    /// Nur eingehend gilt, wenn jede Verbindung dorthin auf einem lauschenden TCP-Port des Programms ankommt.
    @Test func destinationKnowsWhenEverythingIsInbound() {
        let destinations = presentation(travelling, regions: Self.regions).destinations(locale: Self.german)
        #expect(destinations.first { $0.region == .localNetwork }?.isInboundOnly == true)
        #expect(destinations.first { $0.region == .localNetwork }?.accessibilityLabel
            == "Lokales Netz, 1 Verbindung, nur eingehend: node 1")
        // Über Loopback steht dieselbe Verbindung einmal ausgehend (node) und einmal eingehend (postgres) da.
        #expect(destinations.first { $0.region == .country("DE") }?.isInboundOnly == false)
        #expect(destinations.first { $0.region == .country("US") }?.isInboundOnly == false)
    }

    @Test func withoutConnectionsThereAreNoDestinations() {
        #expect(presentation([process(1, "node", listening: [listening(3000)])]).destinations().isEmpty)
    }

    @Test func dataDateReadsMonthAndYear() {
        let date = DateComponents(year: 2026, month: 11, day: 13)
        #expect(NetworkConnectionTexts.dataDate(date, locale: Self.german) == "Länderdaten: Stand November 2026")
        #expect(NetworkConnectionTexts.dataDate(nil, locale: Self.german) == nil)
    }
}
