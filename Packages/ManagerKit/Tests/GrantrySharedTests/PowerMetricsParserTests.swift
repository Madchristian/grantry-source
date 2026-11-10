import Foundation
import Testing
@testable import GrantryShared

@Suite struct PowerMetricsParserTests {
    /// Aufbau einer Probe von `powermetrics -s cpu_power,gpu_power -f plist` auf Apple Silicon (gekürzt, Werte erfunden).
    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>elapsed_ns</key><integer>503112000</integer>
      <key>processor</key><dict>
        <key>clusters</key><array>
          <dict><key>name</key><string>E-Cluster</string><key>freq_hz</key><real>1260000000</real>
            <key>idle_ratio</key><real>0.75</real></dict>
          <dict><key>name</key><string>P0-Cluster</string><key>freq_hz</key><real>3504000000</real>
            <key>idle_ratio</key><real>0.5</real></dict>
        </array>
        <key>cpu_power</key><real>2150.5</real>
        <key>gpu_power</key><real>310</real>
        <key>ane_power</key><real>0</real>
        <key>combined_power</key><real>2460.5</real>
      </dict>
      <key>gpu</key><dict><key>freq_hz</key><real>1398</real><key>idle_ratio</key><real>0.9</real></dict>
    </dict></plist>
    """

    @Test func readsPowerAndClusterFrequencies() throws {
        let reading = try PowerMetricsParser.parse(Data((Self.sample + "\0" + Self.sample + "\0").utf8))
        #expect(reading.cpuMilliwatts == 2150.5)
        #expect(reading.gpuMilliwatts == 310)
        #expect(reading.aneMilliwatts == 0)
        #expect(reading.combinedMilliwatts == 2460.5)
        #expect(reading.gpuFrequencyMHz == 1398)
        #expect(reading.clusters == [
            SensorReading.Cluster(name: "E-Cluster", frequencyMHz: 1260, activeShare: 0.25),
            SensorReading.Cluster(name: "P0-Cluster", frequencyMHz: 3504, activeShare: 0.5),
        ])
        #expect(reading.clusters.map(\.isEfficiency) == [true, false])
        #expect(!reading.isEmpty)
    }

    @Test func missingCombinedPowerIsSumOfParts() {
        let reading = PowerMetricsParser.reading(from: ["processor": ["cpu_power": 1000.0, "ane_power": 25.0]])
        #expect(reading.combinedMilliwatts == 1025)
        #expect(reading.gpuMilliwatts == nil)
    }

    /// Unplausibles (negativ, über 1 kW, Wahrheitswerte, Text) bleibt `nil` statt geraten zu werden.
    @Test func rejectsImplausibleValues() {
        let reading = PowerMetricsParser.reading(from: [
            "processor": ["cpu_power": -5.0, "gpu_power": 2_000_000.0, "ane_power": true, "combined_power": "viel",
                          "clusters": [["name": "E-Cluster", "freq_hz": -1.0, "idle_ratio": 2.0], ["freq_hz": 1e9]]],
            "gpu": ["freq_hz": 0.0],
        ])
        #expect(reading == SensorReading(clusters: [SensorReading.Cluster(name: "E-Cluster", frequencyMHz: nil,
                                                                          activeShare: nil)]))
        #expect(reading.isEmpty)
    }

    @Test func gpuFrequencyInHertzIsConverted() {
        #expect(PowerMetricsParser.reading(from: ["gpu": ["freq_hz": 1_398_000_000.0]]).gpuFrequencyMHz == 1398)
    }

    @Test func emptyOrBrokenOutputFails() {
        #expect(throws: PowerMetricsParser.Failure.noDocument) { try PowerMetricsParser.parse(Data("\0\n\0".utf8)) }
        #expect(throws: PowerMetricsParser.Failure.unreadable) { try PowerMetricsParser.parse(Data("kein plist".utf8)) }
        let huge = Data(repeating: 0x41, count: PowerMetricsParser.maximumDocumentBytes + 1)
        #expect(throws: PowerMetricsParser.Failure.unreadable) { try PowerMetricsParser.parse(huge) }
    }

    @Test func clusterNamesAreSingleLine() {
        let reading = PowerMetricsParser.reading(from: ["processor": ["clusters": [["name": "P\nCluster", "freq_hz": 1e9]]]])
        #expect(reading.clusters.first?.name == "P Cluster")
    }

    /// Feste Kommandozeile: absoluter Pfad, eine Probe, Leistungs-Sampler und thermischer Druck (TM-14.1), kein
    /// Prozess-Sampler.
    @Test func commandLineIsFixed() {
        #expect(PowerMetricsParser.executable == "/usr/bin/powermetrics")
        #expect(PowerMetricsParser.arguments
            == ["-n", "1", "-i", "500", "-s", "cpu_power,gpu_power,thermal", "-f", "plist"])
    }

    /// Ausgaben unter `Fixtures/PowerMetrics`, im Kopf gekennzeichnet: M4 Max echt aufgenommen, M1 und M2 Ultra
    /// nachgebaut.
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "plist",
                                                 subdirectory: "Fixtures/PowerMetrics"))
        return try Data(contentsOf: url)
    }

    @Test func readsCoresAndHighestFrequencyPerCluster() throws {
        let reading = try PowerMetricsParser.parse(Self.fixture("m4-max"))
        #expect(reading.clusters.map(\.name) == ["E-Cluster", "P0-Cluster", "P1-Cluster"])
        #expect(reading.clusters.map { $0.cores.map(\.id) } == [Array(0...3), Array(4...9), Array(10...15)])
        #expect(reading.clusters.map(\.maximumFrequencyMHz) == [2592, 4512, 4512])
        let core = try #require(reading.clusters[2].cores.first)
        #expect(core.id == 10 && core.frequencyMHz == 1848.06)
        #expect(abs(try #require(core.activeShare) - 0.171654) < 1e-6)
        #expect(reading.combinedMilliwatts == 1518.01)
        #expect(reading.thermalPressure == .nominal)
    }

    /// Echte Aufnahme: `idle_ratio`, `down_ratio` und die `used_ratio` der Taktstufen beziehen sich auf das Messfenster
    /// und ergeben zusammen 1. Aktiv ist also nur, was weder Leerlauf noch abgeschaltet war – der fast ganz
    /// abgeschaltete P0-Cluster (`down_ratio` 0,97) ist zu 0,6 % aktiv, nicht zu 98 %; seine Kerne ohne Takt.
    @Test func poweredDownTimeIsNotActive() throws {
        let reading = try PowerMetricsParser.parse(Self.fixture("m4-max"))
        let shares = reading.clusters.map { $0.activeShare ?? -1 }
        #expect(abs(shares[0] - 0.828774) < 1e-6)
        #expect(abs(shares[1] - 0.0056654) < 1e-6)
        #expect(abs(shares[2] - 0.733571) < 1e-6)
        let poweredDown = reading.clusters[1].cores
        #expect(poweredDown.allSatisfy { $0.frequencyMHz == nil && ($0.activeShare ?? 1) < 0.001 })
    }

    /// Ohne `down_ratio` (nachgebaute oder ältere Ausgaben) zählt allein der Leerlauf; Unplausibles bleibt `nil`.
    @Test func activeShareUsesDownRatioWhenPresent() {
        func share(_ cluster: [String: Any]) -> Double? {
            PowerMetricsParser.reading(from: ["processor": ["clusters": [["name": "P"].merging(cluster) { $1 }]]])
                .clusters.first?.activeShare
        }
        #expect(share(["idle_ratio": 0.25]) == 0.75)
        #expect(share(["idle_ratio": 0.25, "down_ratio": 0.5]) == 0.25)
        #expect(share(["idle_ratio": 0.25, "down_ratio": -0.5]) == nil)
        #expect(share(["idle_ratio": 0.75, "down_ratio": 0.5]) == nil)
        #expect(share(["down_ratio": 0.5]) == nil)
    }

    /// Ultra: zwei Chips, Kernnummern je Chip erst Effizienz-, dann Leistungskerne – die Reihenfolge bleibt erhalten.
    @Test func ultraKeepsInterleavedCoreNumbers() throws {
        let reading = try PowerMetricsParser.parse(Self.fixture("m2-ultra"))
        #expect(reading.clusters.map(\.name)
            == ["E0-Cluster", "P0-Cluster", "P1-Cluster", "E1-Cluster", "P2-Cluster", "P3-Cluster"])
        #expect(reading.clusters[3].cores.map(\.id) == [12, 13, 14, 15])
        #expect(reading.clusters[5].maximumFrequencyMHz == 3696)
    }

    @Test(arguments: ["m1", "m4-max", "m2-ultra"])
    func fixturesStayWellBelowOutputLimit(_ name: String) throws {
        let data = try Self.fixture(name)
        #expect(data.count < PowerMetricsParser.maximumDocumentBytes / 4)
        #expect(try !PowerMetricsParser.parse(data).clusters.flatMap(\.cores).isEmpty)
    }

    /// Kerne ohne gültige Nummer entfallen; unplausible Takte und Anteile bleiben `nil`, ebenso ein Höchsttakt ohne
    /// gültige Stufe.
    @Test func implausibleCoreValuesAreDropped() {
        let reading = PowerMetricsParser.reading(from: ["processor": ["clusters": [[
            "name": "P-Cluster",
            "cpus": [["cpu": -1, "freq_hz": 1e9], ["cpu": 2, "freq_hz": -5.0, "idle_ratio": 3.0], ["freq_hz": 1e9],
                     ["cpu": true, "freq_hz": 1e9], ["cpu": 100_000]],
            "dvfm_states": [["freq": 0], ["freq": "viel"], ["freq": -600]],
        ]]]])
        #expect(reading.clusters.first?.cores == [SensorReading.Core(id: 2, frequencyMHz: nil, activeShare: nil)])
        #expect(reading.clusters.first?.maximumFrequencyMHz == nil)
    }

    /// Ein älterer Helper liefert Cluster ohne Kerne, Höchsttakt und Taktverteilung sowie keinen thermischen Druck; die
    /// App liest das weiter.
    @Test func readingFromOlderHelperStillDecodes() throws {
        let json = #"{"clusters":[{"name":"E-Cluster","frequencyMHz":1260,"activeShare":0.25}],"cpuMilliwatts":900}"#
        let reading = try JSONDecoder().decode(SensorReading.self, from: Data(json.utf8))
        #expect(reading.clusters == [SensorReading.Cluster(name: "E-Cluster", frequencyMHz: 1260, activeShare: 0.25)])
        #expect(reading.clusters.first?.frequencySteps == [])
        #expect(reading.clusters.first?.highestFrequencyShare == nil)
        #expect(reading.thermalPressure == nil)
        #expect(reading.cpuMilliwatts == 900)
    }

    // MARK: - Taktverteilung und thermischer Druck (TM-14.1)

    /// Zeitanteile je Taktstufe aus `used_ratio`, bezogen auf die aktive Zeit, aufsteigend nach Takt; der Anteil der
    /// höchsten Stufe ist der Anteil „Höchsttakt“.
    @Test func readsFrequencyDistributionPerCluster() throws {
        let reading = try PowerMetricsParser.parse(Self.fixture("m4-max"))
        let efficiency = try #require(reading.clusters.first)
        #expect(efficiency.frequencySteps.map(\.frequencyMHz) == [1020, 1404, 1788, 2112, 2352, 2532, 2592])
        #expect(abs(efficiency.frequencySteps.map(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(abs(try #require(efficiency.highestFrequencyShare) - 0.153316) < 1e-6)
        #expect(reading.clusters[1].highestFrequencyShare == 0)
        #expect(reading.clusters.allSatisfy { $0.frequencySteps.last?.frequencyMHz == $0.maximumFrequencyMHz })
        #expect(reading.clusters.map(\.frequencySteps.count) == [7, 20, 20])
    }

    @Test(arguments: ["m1", "m4-max", "m2-ultra"])
    func fixturesCarryDistributionAndThermalPressure(_ name: String) throws {
        let reading = try PowerMetricsParser.parse(Self.fixture(name))
        #expect(reading.clusters.allSatisfy { !$0.frequencySteps.isEmpty })
        #expect(reading.thermalPressure != nil)
        #expect(reading.thermalPressure != .unknown)
    }

    /// Anteile werden auf ihre Summe bezogen: Bezöge sich `used_ratio` auf das ganze Messfenster statt auf die aktive
    /// Zeit, ergäbe sich dieselbe Verteilung.
    @Test func sharesAreRelativeToActiveTime() {
        let cluster = Self.cluster(states: [["freq": 600, "used_ratio": 0.125], ["freq": 1200, "used_ratio": 0.375]])
        #expect(cluster?.frequencySteps
            == [.init(frequencyMHz: 600, share: 0.25), .init(frequencyMHz: 1200, share: 0.75)])
        #expect(cluster?.highestFrequencyShare == 0.75)
    }

    /// Ohne `used_ratio` zählt `used_ns`; gleiche Takte werden zusammengefasst und die Stufen nach Takt sortiert.
    @Test func fallsBackToUsedNanosecondsAndMergesSteps() {
        let cluster = Self.cluster(states: [["freq": 2000, "used_ns": 100], ["freq": 1000, "used_ns": 200],
                                            ["freq": 2000, "used_ns": 100]])
        #expect(cluster?.frequencySteps
            == [.init(frequencyMHz: 1000, share: 0.5), .init(frequencyMHz: 2000, share: 0.5)])
    }

    /// Ein Cluster, der nie aktiv war, hat keine Verteilung statt einer erfundenen.
    @Test func idleClusterHasNoDistribution() {
        let cluster = Self.cluster(states: [["freq": 600, "used_ratio": 0.0], ["freq": 1200, "used_ratio": 0.0]])
        #expect(cluster?.frequencySteps == [])
        #expect(cluster?.highestFrequencyShare == nil)
    }

    /// Unbekanntes bleibt leer: eine einzige unplausible Stufe, Anteile über 1, gemischte Quellen oder zu viele Stufen
    /// verwerfen die ganze Verteilung, statt Anteile falsch zu verteilen. Der Höchsttakt bleibt davon unberührt.
    @Test func implausibleDistributionStaysEmpty() {
        let cases: [[[String: Any]]] = [
            [["freq": 600, "used_ratio": 0.5], ["freq": "viel", "used_ratio": 0.5]],
            [["freq": 600, "used_ratio": 0.5], ["freq": 1200, "used_ratio": -0.1]],
            [["freq": 600, "used_ratio": 0.7], ["freq": 1200, "used_ratio": 0.7]],
            [["freq": 600, "used_ratio": 1.5]],
            [["freq": 600, "used_ratio": 0.5], ["freq": 1200, "used_ns": 10]],
            [["freq": 600, "used_ns": -1], ["freq": 1200, "used_ns": 10]],
            [["freq": 600, "used_ns": 1e15]],
            [["freq": 600, "used_ratio": true]],
            [["freq": 600]],
            Array(repeating: ["freq": 600, "used_ratio": 0.001], count: 65),
        ]
        for (index, states) in cases.enumerated() {
            let cluster = Self.cluster(states: states)
            #expect(cluster?.frequencySteps == [], "Fall \(index)")
            #expect(cluster?.highestFrequencyShare == nil, "Fall \(index)")
        }
        #expect(Self.cluster(states: cases[0])?.maximumFrequencyMHz == 600)
    }

    @Test func missingStatesLeaveDistributionEmpty() {
        let reading = PowerMetricsParser.reading(from: ["processor": ["clusters": [["name": "P-Cluster"]]]])
        #expect(reading.clusters.first?.frequencySteps == [])
    }

    /// Stufen von `powermetrics -s thermal` (Groß-/Kleinschreibung egal); Unbekanntes heißt unbekannt, Fehlen `nil`.
    @Test(arguments: [
        ("Nominal", SensorReading.ThermalPressure.nominal), ("Light", .light), ("Moderate", .moderate),
        ("Heavy", .heavy), ("Trapping", .trapping), ("Sleeping", .sleeping), (" heavy ", .heavy),
        ("Glühend", .unknown), ("", .unknown),
    ])
    func readsThermalPressure(_ raw: String, _ expected: SensorReading.ThermalPressure) {
        #expect(PowerMetricsParser.reading(from: ["thermal_pressure": raw]).thermalPressure == expected)
    }

    @Test func thermalPressureOfWrongTypeIsUnknownAndMissingIsNil() {
        #expect(PowerMetricsParser.reading(from: ["thermal_pressure": 2]).thermalPressure == .unknown)
        #expect(PowerMetricsParser.reading(from: [:]).thermalPressure == nil)
    }

    /// Ein Wert, den diese App nicht kennt (neuerer Helper), wird beim Lesen zu „unbekannt“, statt die Antwort zu
    /// verwerfen.
    @Test func unknownThermalPressureFromNewerHelperDecodes() throws {
        let json = #"{"clusters":[],"thermalPressure":"glowing"}"#
        #expect(try JSONDecoder().decode(SensorReading.self, from: Data(json.utf8)).thermalPressure == .unknown)
    }

    /// Der thermische Druck allein füllt keine Sensor-Kachel (Verhalten wie vor TM-14.1).
    @Test func thermalPressureAloneKeepsReadingEmpty() {
        #expect(SensorReading(thermalPressure: .nominal).isEmpty)
    }

    static func cluster(states: [[String: Any]]) -> SensorReading.Cluster? {
        PowerMetricsParser.reading(from: ["processor": ["clusters": [["name": "P-Cluster", "dvfm_states": states]]]])
            .clusters.first
    }

    @Test func readingRoundTripsAsJSON() throws {
        for reading in [try PowerMetricsParser.parse(Data(Self.sample.utf8)),
                        try PowerMetricsParser.parse(Self.fixture("m2-ultra"))] {
            #expect(try JSONDecoder().decode(SensorReading.self, from: JSONEncoder().encode(reading)) == reading)
        }
    }
}
