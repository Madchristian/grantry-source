import Foundation

/// Kachel „Leistungsaufnahme“ und ihre Kennzahlen (TM-9.4): Werte des Helpers (`powermetrics`) und der thermische
/// Zustand (`ProcessInfo.thermalState`, ohne Root). Temperaturen gibt es auf Apple Silicon nur über private
/// Schnittstellen – sie fehlen bewusst.
extension PerformancePresentation {
    /// `nil` ohne Gesamtleistung: Dann gibt es keine Kachel statt einer Kachel voller „–“.
    static func sensorTile(_ reading: SensorReading?) -> PerformanceTile? {
        guard let reading, let combined = reading.combinedMilliwatts else { return nil }
        let parts = [("CPU", reading.cpuMilliwatts), ("GPU", reading.gpuMilliwatts)]
            .compactMap { name, value in value.map { "\(name) \(watts($0))" } }
        return PerformanceTile(metric: .power, title: "Leistungsaufnahme", value: watts(combined),
                               detail: parts.joined(separator: " · "))
    }

    static func sensorStats(_ reading: SensorReading?, thermalState: ProcessInfo.ThermalState) -> [PerformanceStat] {
        [PerformanceStat("Gesamt", reading?.combinedMilliwatts.map(watts) ?? missing),
         PerformanceStat("CPU", reading?.cpuMilliwatts.map(watts) ?? missing),
         PerformanceStat("GPU", reading?.gpuMilliwatts.map(watts) ?? missing),
         PerformanceStat("Neural Engine", reading?.aneMilliwatts.map(watts) ?? missing),
         PerformanceStat("CPU-Takt", reading.map { clusterText($0.clusters) } ?? missing),
         PerformanceStat("GPU-Takt", reading?.gpuFrequencyMHz.map(frequency) ?? missing),
         PerformanceStat("Thermischer Zustand", thermalText(thermalState))]
    }

    /// „2,46 W“ (unter 10 W zwei Nachkommastellen, darüber eine).
    public static func watts(_ milliwatts: Double) -> String {
        let value = milliwatts / 1000
        let digits = value < 10 ? 2 : 1
        return value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE"))) + " W"
    }

    /// „1,3 GHz“ bzw. „980 MHz“ – kurz, damit drei Cluster in eine Zeile passen.
    static func frequency(_ megahertz: Double) -> String {
        let german = Locale(identifier: "de_DE")
        guard megahertz >= 1000 else { return "\(Int(megahertz.rounded())) MHz" }
        return (megahertz / 1000).formatted(.number.precision(.fractionLength(1)).locale(german)) + " GHz"
    }

    /// „E 1,3 GHz · P0 3,5 GHz“ – Cluster ohne Takt entfallen.
    static func clusterText(_ clusters: [SensorReading.Cluster]) -> String {
        let parts = clusters.compactMap { cluster in
            cluster.frequencyMHz.map { "\(clusterLabel(cluster.name)) \(frequency($0))" }
        }
        return parts.isEmpty ? missing : parts.joined(separator: " · ")
    }

    /// „E-Cluster“ → „E“, „P0-Cluster“ → „P0“.
    private static func clusterLabel(_ name: String) -> String {
        name.hasSuffix("-Cluster") ? String(name.dropLast("-Cluster".count)) : name
    }

    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Erhöht"
        case .serious: "Hoch – Leistung gedrosselt"
        case .critical: "Kritisch"
        @unknown default: missing
        }
    }
}
