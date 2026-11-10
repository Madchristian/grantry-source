import Foundation

/// Leistungsaufnahme, Takt und thermischer Druck laut `powermetrics` (TM-9.4, TM-14.1), vom Helper an die App. Alles
/// optional: Was die Ausgabe nicht enthält, bleibt `nil` bzw. leer und erscheint als „–“ bzw. ohne Kachel (Spec §5).
/// Temperaturen gibt es auf Apple Silicon nur über private Schnittstellen – sie fehlen hier bewusst.
public struct SensorReading: Codable, Hashable, Sendable {
    /// Ein Kern eines Clusters mit seiner logischen Nummer (wie `host_processor_info`).
    public struct Core: Codable, Hashable, Sendable {
        public let id: Int
        public let frequencyMHz: Double?
        /// Anteil aktiver Zeit (0…1).
        public let activeShare: Double?

        public init(id: Int, frequencyMHz: Double?, activeShare: Double?) {
            self.id = id
            self.frequencyMHz = frequencyMHz
            self.activeShare = activeShare
        }
    }

    /// Eine Taktstufe aus `dvfm_states` mit ihrem Anteil an der aktiven Zeit des Clusters (TM-14.1).
    public struct FrequencyStep: Codable, Hashable, Sendable {
        public let frequencyMHz: Double
        /// Anteil an der aktiven Zeit (0…1); die Anteile eines Clusters ergeben zusammen 1.
        public let share: Double

        public init(frequencyMHz: Double, share: Double) {
            self.frequencyMHz = frequencyMHz
            self.share = share
        }
    }

    /// Thermischer Druck laut Sampler `thermal` (feiner als `ProcessInfo.thermalState`). `unknown` steht für eine
    /// Stufe, die diese Version nicht kennt – auch beim Lesen der Antwort eines neueren Helpers.
    public enum ThermalPressure: String, Codable, Hashable, Sendable {
        case nominal, light, moderate, heavy, trapping, sleeping, unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// Ein CPU-Cluster („E-Cluster“, „P0-Cluster“ …).
    public struct Cluster: Codable, Hashable, Sendable {
        public let name: String
        public let frequencyMHz: Double?
        /// Anteil aktiver Zeit (0…1).
        public let activeShare: Double?
        /// Höchste Taktstufe laut `dvfm_states` (Chip-Tab).
        public let maximumFrequencyMHz: Double?
        /// Kerne des Clusters; leer, wenn die Ausgabe sie nicht nennt (oder ein älterer Helper misst).
        public let cores: [Core]
        /// Taktverteilung aufsteigend nach Takt; leer, wenn unbekannt, der Cluster im Messfenster nie aktiv war oder
        /// ein älterer Helper misst.
        public let frequencySteps: [FrequencyStep]

        public init(name: String, frequencyMHz: Double?, activeShare: Double?, maximumFrequencyMHz: Double? = nil,
                    cores: [Core] = [], frequencySteps: [FrequencyStep] = []) {
            self.name = name
            self.frequencyMHz = frequencyMHz
            self.activeShare = activeShare
            self.maximumFrequencyMHz = maximumFrequencyMHz
            self.cores = cores
            self.frequencySteps = frequencySteps
        }

        /// Ohne `cores` und `frequencySteps` (älterer Helper) leer statt Fehler.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try container.decode(String.self, forKey: .name),
                      frequencyMHz: try container.decodeIfPresent(Double.self, forKey: .frequencyMHz),
                      activeShare: try container.decodeIfPresent(Double.self, forKey: .activeShare),
                      maximumFrequencyMHz: try container.decodeIfPresent(Double.self, forKey: .maximumFrequencyMHz),
                      cores: try container.decodeIfPresent([Core].self, forKey: .cores) ?? [],
                      frequencySteps: try container.decodeIfPresent([FrequencyStep].self,
                                                                    forKey: .frequencySteps) ?? [])
        }

        /// Anteil der aktiven Zeit auf der höchsten Taktstufe („Höchsttakt erreicht“); `nil` ohne Taktverteilung.
        public var highestFrequencyShare: Double? { frequencySteps.last?.share }

        /// Effizienzcluster laut Name.
        public var isEfficiency: Bool { name.uppercased().hasPrefix("E") }
    }

    public var cpuMilliwatts: Double?
    public var gpuMilliwatts: Double?
    public var aneMilliwatts: Double?
    /// Gesamte SoC-Leistung; fehlt sie, die Summe der vorhandenen Teile.
    public var combinedMilliwatts: Double?
    public var clusters: [Cluster]
    public var gpuFrequencyMHz: Double?
    /// Zum Ende des Messfensters; `nil`, wenn die Ausgabe ihn nicht enthält (oder ein älterer Helper misst).
    public var thermalPressure: ThermalPressure?

    public init(cpuMilliwatts: Double? = nil, gpuMilliwatts: Double? = nil, aneMilliwatts: Double? = nil,
                combinedMilliwatts: Double? = nil, clusters: [Cluster] = [], gpuFrequencyMHz: Double? = nil,
                thermalPressure: ThermalPressure? = nil) {
        self.cpuMilliwatts = cpuMilliwatts
        self.gpuMilliwatts = gpuMilliwatts
        self.aneMilliwatts = aneMilliwatts
        self.combinedMilliwatts = combinedMilliwatts
        self.clusters = clusters
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.thermalPressure = thermalPressure
    }

    /// Ob überhaupt ein Leistungs- oder Taktwert gelesen wurde; der thermische Druck allein füllt keine Sensor-Kachel.
    public var isEmpty: Bool {
        combinedMilliwatts == nil && cpuMilliwatts == nil && gpuMilliwatts == nil && aneMilliwatts == nil
            && gpuFrequencyMHz == nil && clusters.allSatisfy { $0.frequencyMHz == nil }
    }
}

/// Liest die Ausgabe von `powermetrics -f plist` (NUL-getrennte Property-Listen). Die Schlüssel sind von Apple nicht als
/// stabile Schnittstelle zugesichert: Was fehlt oder unplausibel ist, bleibt `nil` statt zu raten.
public enum PowerMetricsParser {
    public static let executable = "/usr/bin/powermetrics"
    /// Feste Kommandozeile des Helpers: eine Probe über 500 ms, Leistungs-Sampler und thermischer Druck (TM-14.1).
    public static let arguments = ["-n", "1", "-i", "500", "-s", "cpu_power,gpu_power,thermal", "-f", "plist"]
    /// Größere Dokumente verwirft der Parser (eine Probe ist wenige KiB groß).
    public static let maximumDocumentBytes = 1 << 20
    /// Obergrenze plausibler Leistungswerte (1 kW).
    static let maximumMilliwatts = 1_000_000.0
    /// Logische Kernnummern unterhalb dieser Grenze gelten als plausibel.
    static let coreLimit = 4096
    /// Mehr Taktstufen je Cluster gelten als unplausibel (beobachtet: höchstens 20).
    static let frequencyStepLimit = 64
    /// Obergrenze plausibler Verweildauer je Stufe (1000 s; das Messfenster dauert 500 ms).
    static let maximumUsedNanoseconds = 1e12
    /// Spielraum für Rundung, wenn Anteile einer Ausgabe zusammen knapp über 1 liegen.
    static let ratioTolerance = 0.01

    public enum Failure: LocalizedError, Equatable {
        case noDocument
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .noDocument: "powermetrics lieferte keine Messung"
            case .unreadable: "Ausgabe von powermetrics nicht lesbar"
            }
        }
    }

    /// Das erste nicht leere Dokument der Ausgabe.
    public static func parse(_ output: Data) throws(Failure) -> SensorReading {
        guard let document = output.split(separator: 0, omittingEmptySubsequences: true)
            .first(where: { !$0.allSatisfy { $0 == 0x0A || $0 == 0x20 } }) else { throw .noDocument }
        guard document.count <= maximumDocumentBytes,
              let root = try? PropertyListSerialization.propertyList(from: Data(document), format: nil)
                as? [String: Any] else { throw .unreadable }
        return reading(from: root)
    }

    static func reading(from root: [String: Any]) -> SensorReading {
        let processor = root["processor"] as? [String: Any] ?? [:]
        let gpu = root["gpu"] as? [String: Any] ?? [:]
        var reading = SensorReading(
            cpuMilliwatts: milliwatts(processor["cpu_power"]),
            gpuMilliwatts: milliwatts(processor["gpu_power"]) ?? milliwatts(gpu["gpu_power"]),
            aneMilliwatts: milliwatts(processor["ane_power"]),
            combinedMilliwatts: milliwatts(processor["combined_power"]),
            clusters: (processor["clusters"] as? [[String: Any]] ?? []).compactMap(cluster),
            gpuFrequencyMHz: megahertz(gpu["freq_hz"]),
            thermalPressure: root["thermal_pressure"].map(thermalPressure)
        )
        if reading.combinedMilliwatts == nil {
            let parts = [reading.cpuMilliwatts, reading.gpuMilliwatts, reading.aneMilliwatts].compactMap { $0 }
            reading.combinedMilliwatts = parts.isEmpty ? nil : parts.reduce(0, +)
        }
        return reading
    }

    private static func cluster(_ entry: [String: Any]) -> SensorReading.Cluster? {
        guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
        let states = entry["dvfm_states"] as? [[String: Any]] ?? []
        return SensorReading.Cluster(
            name: DisplayText.singleLine(name),
            frequencyMHz: hertzAsMegahertz(entry["freq_hz"]),
            activeShare: activeShare(entry),
            maximumFrequencyMHz: states.compactMap { megahertz($0["freq"]) }.max(),
            cores: (entry["cpus"] as? [[String: Any]] ?? []).compactMap(core),
            frequencySteps: frequencySteps(states)
        )
    }

    /// Zeitanteile je Taktstufe aus `used_ratio`, sonst `used_ns`, bezogen auf ihre Summe – also auf die aktive Zeit,
    /// gleich ob `powermetrics` sie auf das Messfenster oder die aktive Zeit bezieht. Eine einzige unplausible Stufe
    /// verwirft die ganze Verteilung, weil ihr Anteil sonst den übrigen zufiele.
    private static func frequencySteps(_ states: [[String: Any]]) -> [SensorReading.FrequencyStep] {
        guard !states.isEmpty, states.count <= frequencyStepLimit else { return [] }
        let frequencies = states.compactMap { megahertz($0["freq"]) }
        guard frequencies.count == states.count, let times = usedTimes(states) else { return [] }
        let total = times.reduce(0, +)
        guard total > 0 else { return [] }
        return Dictionary(zip(frequencies, times), uniquingKeysWith: +)
            .sorted { $0.key < $1.key }
            .map { SensorReading.FrequencyStep(frequencyMHz: $0.key, share: $0.value / total) }
    }

    /// Verweildauer je Stufe aus `used_ratio` (zusammen höchstens 1), sonst aus `used_ns`; `nil`, wenn keine Quelle für
    /// alle Stufen plausibel ist.
    private static func usedTimes(_ states: [[String: Any]]) -> [Double]? {
        if let ratios = values(states, key: "used_ratio", range: 0...1) {
            return ratios.reduce(0, +) <= 1 + ratioTolerance ? ratios : nil
        }
        return values(states, key: "used_ns", range: 0...maximumUsedNanoseconds)
    }

    /// Die Werte unter `key` aller Stufen, oder `nil`, sobald einer fehlt oder außerhalb von `range` liegt.
    private static func values(_ states: [[String: Any]], key: String, range: ClosedRange<Double>) -> [Double]? {
        let values = states.compactMap { number($0[key]).flatMap { range.contains($0) ? $0 : nil } }
        return values.count == states.count ? values : nil
    }

    /// Stufen des Samplers `thermal` (`thermal_pressure`, z. B. „Nominal“); Unbekanntes heißt `unknown`.
    private static func thermalPressure(_ value: Any) -> SensorReading.ThermalPressure {
        guard let text = value as? String, text.count <= 32,
              let pressure = SensorReading.ThermalPressure(
                rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return .unknown }
        return pressure
    }

    private static func core(_ entry: [String: Any]) -> SensorReading.Core? {
        guard let id = number(entry["cpu"]), id >= 0, id < Double(coreLimit), id.rounded() == id else { return nil }
        return SensorReading.Core(id: Int(id), frequencyMHz: hertzAsMegahertz(entry["freq_hz"]),
                                  activeShare: activeShare(entry))
    }

    /// `freq_hz` der Cluster und Kerne in Hz.
    private static func hertzAsMegahertz(_ value: Any?) -> Double? {
        number(value).flatMap { $0 > 0 && $0 < 1e11 ? $0 / 1e6 : nil }
    }

    /// Aktiver Anteil (0…1): was weder Leerlauf (`idle_ratio`) noch abgeschaltet (`down_ratio`, falls vorhanden) war.
    /// Beide beziehen sich auf das Messfenster und ergeben mit den `used_ratio` der Taktstufen zusammen 1 (echte
    /// Aufnahme M4 Max); ohne `down_ratio` erschiene ein abgeschalteter Cluster als fast voll aktiv.
    private static func activeShare(_ entry: [String: Any]) -> Double? {
        guard let idle = ratio(entry["idle_ratio"]),
              let down = entry["down_ratio"] == nil ? 0 : ratio(entry["down_ratio"]),
              idle + down <= 1 + ratioTolerance else { return nil }
        return max(0, 1 - idle - down)
    }

    private static func ratio(_ value: Any?) -> Double? {
        number(value).flatMap { (0...1).contains($0) ? $0 : nil }
    }

    /// `gpu.freq_hz` und `dvfm_states[].freq` enthalten MHz (beobachtete Ausgabe); Werte in Hz werden umgerechnet.
    private static func megahertz(_ value: Any?) -> Double? {
        guard let value = number(value), value > 0 else { return nil }
        return value < 100_000 ? value : value / 1e6
    }

    private static func milliwatts(_ value: Any?) -> Double? {
        number(value).flatMap { (0...maximumMilliwatts).contains($0) ? $0 : nil }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
