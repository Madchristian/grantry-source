import Foundation

/// Stufen des thermischen Drucks für die Regel „Drosselung“: die feineren Stufen des Samplers `thermal` von
/// `powermetrics`, darauf abgebildet die vier Stufen von `ProcessInfo.thermalState`.
public enum ThermalPressureLevel: Int, Comparable, CaseIterable, Sendable {
    case nominal, light, moderate, heavy, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `nil` für eine unbekannte Stufe; die Anzeige nennt `fair` „mäßig“, so auch hier.
    init?(_ pressure: SensorReading.ThermalPressure) {
        switch pressure {
        case .nominal: self = .nominal
        case .light: self = .light
        case .moderate: self = .moderate
        case .heavy: self = .heavy
        case .trapping, .sleeping: self = .critical
        case .unknown: return nil
        }
    }

    init?(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .moderate
        case .serious: self = .heavy
        case .critical: self = .critical
        @unknown default: return nil
        }
    }
}

/// Eine Sensor-Messung als Messpunkt der Regel „Drosselung“ (`FindingRules.throttlingFindings`).
public struct ThrottlingSample: Hashable, Sendable {
    /// Ein Leistungscluster.
    public struct Cluster: Hashable, Sendable {
        /// Aktiver Anteil (0…1); `nil`, wenn nicht gemessen.
        public let load: Double?
        /// Mittlerer Takt als Anteil an der höchsten Taktstufe; `nil`, wenn nicht gemessen.
        public let clockShare: Double?

        public init(load: Double?, clockShare: Double?) {
            self.load = load
            self.clockShare = clockShare
        }
    }

    public let time: Date
    /// `nil`, wenn weder Helper noch `ProcessInfo` gelesen wurden.
    public let pressure: ThermalPressureLevel?
    /// `nil` ohne Messung des Helpers; leer ohne Leistungscluster (Intel).
    public let performanceClusters: [Cluster]?

    public init(time: Date, pressure: ThermalPressureLevel?, performanceClusters: [Cluster]?) {
        self.time = time
        self.pressure = pressure
        self.performanceClusters = performanceClusters
    }

    /// Aus einer Messung des Helpers. Der Druck kommt vom Sampler `thermal`; fehlt er (älterer Helper) oder ist die
    /// Stufe unbekannt, aus `thermalState`.
    /// - Parameters:
    ///   - sensors: `nil`, wenn der Helper nichts lieferte – dann ist der Takt nicht gemessen.
    ///   - thermalState: `ProcessInfo.thermalState` aus `ThermalStateSource`; `nil`, wenn nicht gelesen.
    public init(time: Date, sensors: SensorReading?, thermalState: ProcessInfo.ThermalState?) {
        self.init(
            time: time,
            pressure: sensors?.thermalPressure.flatMap(ThermalPressureLevel.init) ?? thermalState
                .flatMap(ThermalPressureLevel.init),
            performanceClusters: sensors.map { reading in
                reading.clusters.filter { !$0.isEfficiency }.map { cluster in
                    Cluster(load: cluster.activeShare, clockShare: Self.clockShare(cluster))
                }
            }
        )
    }

    private static func clockShare(_ cluster: SensorReading.Cluster) -> Double? {
        guard let frequency = cluster.frequencyMHz, let maximum = cluster.maximumFrequencyMHz, maximum > 0 else {
            return nil
        }
        return frequency / maximum
    }
}
