import Foundation
import Testing
@testable import ManagerKit

/// Penetrationstests (Audit 2026-10-09, Befund B1): nettop schreibt den Prozessnamen ungeschützt in die CSV-Zeile.
/// Der Name ist der Dateiname des Programms – den wählt ein lokaler Prozess ohne Rechte frei
/// (`cp /usr/bin/nc "/tmp/,x"`). Zwei Namen reichen, um die Netzwerkaktivität zu stören:
///
/// - `,x` erzeugt `,x.4711,,0,0,` – der Block-Splitter hält jede Zeile mit führendem `,` für eine Kopfzeile, der Parser
///   lehnt den Block ab, der Sampler endet mit `unrecognizedFormat` („Ausgabeformat von nettop nicht erkannt“, ohne
///   Erneut-Knopf). Die Aktivität **aller** Prozesse verschwindet, die Meldung verdächtigt macOS statt den Angreifer.
/// - `tcp4 a<->b` erzeugt `tcp4 a<->b.4711,,5,6,` – eine Prozesszeile, die wie eine Verbindungszeile aussieht. Sie wird
///   übersprungen, und die echten Verbindungen des Angreifers landen beim **vorherigen** Prozess (etwa einem Browser).
@Suite struct PenetrationNettopHostileNamesTests {
    private let header = NettopParser.header

    /// Alle Blöcke, die der Assembler aus `lines` fertigstellt.
    private func samples(_ lines: [String]) throws -> [NettopSample] {
        let assembler = NettopSampleAssembler(startTime: { _ in 1 })
        let now = ContinuousClock.now
        var samples: [NettopSample] = []
        for line in lines {
            if let sample = try assembler.consume(line, at: now) { samples.append(sample.sample) }
        }
        return samples
    }

    /// Befund B1a: Ein Prozess namens `,x` darf den Sampler nicht beenden; seine Zeile gehört in den laufenden Block.
    @Test func processNamedLikeAHeaderDoesNotStopTheSampler() throws {
        let samples = try samples([header, "curl.42,,1,2,", ",x.4711,,0,0,", header, "curl.42,,3,4,", header])
        #expect(samples.count == 2)
        #expect(samples.first?.processes.map(\.pid) == [42, 4711])
    }

    /// Befund B1b: Verbindungen gehören zu dem Prozess, dessen Zeile sie folgen – auch wenn dessen Name wie eine
    /// Verbindungszeile aussieht.
    @Test func processNamedLikeAConnectionLineKeepsItsConnectionsApart() throws {
        let sample = try NettopParser.parse(block: """
            \(header)
            Safari.100,,1,1,
            tcp4 a<->b.4711,,5,6,
            tcp4 192.0.2.1:50000<->203.0.113.9:443,Established,5,6,
            """)
        let safari = try #require(sample.processes.first { $0.pid == 100 })
        #expect(safari.connections.isEmpty, "die Verbindung des Angreifers darf nicht Safari zugeschrieben werden")
        #expect(sample.processes.contains { $0.pid == 4711 })
        let attacker = try #require(sample.processes.first { $0.pid == 4711 })
        #expect(attacker.connections.map(\.remote) == [ConnectionEndpoint(address: "203.0.113.9", port: 443)])
    }

    /// Die Erkennung gilt auch für andere Protokollpräfixe, zusätzliche Kommas und Endpunkttexte im Namen.
    @Test(arguments: [",x", ",state,bytes_in,bytes_out,", "tcp4 a<->b", "udp6 a<->b", "quic6 ::.1<->::.2", "a,b.c d"])
    func hostileNamesKeepTrafficAndIdentity(_ name: String) throws {
        let samples = try samples([
            header, "Safari.100,,1,2,", "\(name).4711,,5,6,",
            "tcp4 192.0.2.1:50000<->203.0.113.9:443,Established,5,6,", header,
        ])
        let sample = try #require(samples.first)
        #expect(sample.skippedLineCount == 0)
        #expect(sample.processes.map(\.pid) == [100, 4711])
        #expect(sample.processes.first?.connections.isEmpty == true)
        let attacker = try #require(sample.processes.last)
        #expect(attacker.shortName == name)
        #expect(attacker.bytesIn == 5 && attacker.bytesOut == 6)
        #expect(attacker.startTime == 1)
        #expect(attacker.connections.map(\.remote) == [ConnectionEndpoint(address: "203.0.113.9", port: 443)])
    }

    /// Gegenprobe (heute korrekt): Namen mit Punkten, Kommas und Leerzeichen bleiben Prozesszeilen.
    @Test func ordinaryHostileLookingNamesStayProcessLines() throws {
        let sample = try NettopParser.parse(block: """
            \(header)
            a,b.c d.42,,1,2,
            tcp4 192.0.2.1:50000<->203.0.113.9:443,Established,1,2,
            """)
        #expect(sample.processes.map(\.shortName) == ["a,b.c d"])
        #expect(sample.processes.first?.connections.count == 1)
    }
}
