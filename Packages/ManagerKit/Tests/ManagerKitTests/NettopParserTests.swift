import Foundation
import Testing
@testable import ManagerKit

@Suite struct NettopParserTests {
    private let header = NettopParser.header

    private func fixture() throws -> NettopSample {
        let url = try #require(Bundle.module.url(forResource: "nettop-block", withExtension: "txt", subdirectory: "Fixtures"))
        return try NettopParser.parse(block: String(contentsOf: url, encoding: .utf8))
    }

    private func process(_ name: String, in sample: NettopSample) throws -> ProcessTraffic {
        try #require(sample.processes.first { $0.shortName == name })
    }

    @Test func readsProcessesOfRealBlock() throws {
        let sample = try fixture()
        #expect(sample.processes.map(\.shortName) == [
            "kernel_task", "launchd", "syslogd", "apsd", "nesessionmanage", "mDNSResponder", "com.apple.WebKi",
            "python3.14", "Remote Desktop", "GitHub Desktop",
        ])
        #expect(sample.processes.map(\.pid) == [0, 1, 571, 577, 584, 622, 2112, 5610, 1869, 55073])
        #expect(sample.skippedLineCount == 0)
        let kernel = try process("kernel_task", in: sample)
        #expect(kernel.bytesIn == 6_930_047)
        #expect(kernel.bytesOut == 6_409_315)
        #expect(kernel.connections.count == 2)
        #expect(try process("GitHub Desktop", in: sample).connections.isEmpty)
    }

    @Test func readsIPv4Connection() throws {
        let apsd = try process("apsd", in: try fixture())
        #expect(apsd.connections == [ConnectionTraffic(
            transport: .tcp, ipVersion: .v4,
            local: ConnectionEndpoint(address: "192.0.2.235", port: 63199),
            remote: ConnectionEndpoint(address: "192.0.2.25", port: 5223),
            state: "Established", bytesIn: 4_727_302, bytesOut: 10_165_988
        )])
    }

    /// IPv6 trennt den Port mit einem Punkt; Adressen dürfen auf `::` enden und eine Zone tragen.
    @Test func readsIPv6WithZoneAndTrailingColons() throws {
        let sample = try fixture()
        let quic = try #require(try process("mDNSResponder", in: sample).connections.last)
        #expect(quic.transport == .quic)
        #expect(quic.ipVersion == .v6)
        #expect(quic.local == ConnectionEndpoint(address: "2001:db8:50d2:cfa0:28f4:b1dd:992c:8ba1", port: 63600))
        #expect(quic.remote == ConnectionEndpoint(address: "2001:db8:3e:2:ace0:2e84::", port: 443))
        #expect(quic.state.isEmpty)
        let linkLocal = try #require(try process("com.apple.WebKi", in: sample).connections.first)
        #expect(linkLocal.remote == ConnectionEndpoint(address: "fe80::2%en8", port: 49153))
        #expect(linkLocal.remote.description == "[fe80::2%en8]:49153")
    }

    @Test func readsUDPWithoutPeerAndEmptyByteFields() throws {
        let unbound = try process("nesessionmanage", in: try fixture()).connections
        #expect(unbound.count == 2)
        #expect(unbound[0] == ConnectionTraffic(
            transport: .udp, ipVersion: .v4, local: ConnectionEndpoint(address: nil, port: nil),
            remote: ConnectionEndpoint(address: nil, port: nil), state: "", bytesIn: nil, bytesOut: nil
        ))
        #expect(unbound[1].ipVersion == .v6)
        let syslog = try #require(try process("syslogd", in: try fixture()).connections.first)
        #expect(syslog.local == ConnectionEndpoint(address: nil, port: 57811))
        #expect(syslog.bytesIn == 0 && syslog.bytesOut == 84)
    }

    /// Gekürzte Namen mit Punkten und Leerzeichen: Die PID ist das letzte Feld nach einem Punkt.
    @Test func readsTruncatedNamesWithDotsAndSpaces() throws {
        let sample = try fixture()
        #expect(try process("python3.14", in: sample).pid == 5610)
        #expect(try process("com.apple.WebKi", in: sample).pid == 2112)
        #expect(try process("Remote Desktop", in: sample).pid == 1869)
        #expect(try process("GitHub Desktop", in: sample).pid == 55073)
    }

    @Test func readsListenLinesAndFlagsThem() throws {
        let launchd = try process("launchd", in: try fixture())
        #expect(launchd.connections.count == 4)
        #expect(launchd.connections.allSatisfy { $0.isListening })
        #expect(launchd.connections[0].local == ConnectionEndpoint(address: "127.0.0.1", port: 8021))
        #expect(launchd.connections[3].local == ConnectionEndpoint(address: nil, port: 5900))
    }

    @Test func rejectsUnknownHeader() {
        #expect(throws: NettopParser.Error.unrecognizedFormat) {
            try NettopParser.parse(block: ",state,bytes_in,\napsd.577,,1,2,")
        }
        #expect(throws: NettopParser.Error.unrecognizedFormat) {
            try NettopParser.parse(block: "time,,interface,state,bytes_in,bytes_out,\napsd.577,,1,2,")
        }
    }

    @Test func rejectsUnreadableProcessLines() {
        for line in ["apsd,,1,2,", "apsd.577,Established,1,2,", "apsd.577,,eins,2,", ".577,,1,2,", "apsd.577,,1,2"] {
            #expect(throws: NettopParser.Error.unrecognizedFormat, "\(line)") {
                try NettopParser.parse(block: "\(header)\n\(line)")
            }
        }
    }

    @Test func rejectsConnectionBeforeFirstProcess() {
        #expect(throws: NettopParser.Error.unrecognizedFormat) {
            try NettopParser.parse(block: "\(header)\ntcp4 192.0.2.1:1<->192.0.2.2:2,Established,1,2,")
        }
    }

    /// Einzelne unlesbare Verbindungszeilen werden gezählt, nicht verschluckt und nicht zum Abbruch.
    @Test func countsUnreadableConnectionLines() throws {
        let sample = try NettopParser.parse(block: """
            \(header)
            curl.42,,10,20,
            tcp4 192.0.2.1<->192.0.2.2:443,Established,1,2,
            sctp4 192.0.2.1:1<->192.0.2.2:2,,1,2,
            tcp4 192.0.2.1:1<->192.0.2.2:443,Established,viel,2,
            tcp4 192.0.2.1:50000<->192.0.2.2:443,Established,10,20,
            """)
        #expect(sample.skippedLineCount == 3)
        #expect(sample.processes.first?.connections.count == 1)
    }

    @Test func acceptsBlockWithoutProcesses() throws {
        #expect(try NettopParser.parse(block: header) == NettopSample(processes: []))
    }

    /// nettop lässt die Byte-Felder mancher Prozesse leer: unbekannt (`nil`), nicht 0.
    @Test func readsProcessWithEmptyByteFields() throws {
        let sample = try NettopParser.parse(block: "\(header)\ncurl.42,,,,")
        #expect(sample.processes == [ProcessTraffic(pid: 42, shortName: "curl", bytesIn: nil, bytesOut: nil)])
    }

    @Test func acceptsCRLFLineEndings() throws {
        let sample = try NettopParser.parse(block: "\(header)\r\ncurl.42,,10,20,\r\n")
        #expect(sample.processes == [ProcessTraffic(pid: 42, shortName: "curl", bytesIn: 10, bytesOut: 20)])
    }
}
