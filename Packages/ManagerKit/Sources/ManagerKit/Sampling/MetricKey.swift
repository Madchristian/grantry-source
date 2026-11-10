/// Eine Metrik im Verlauf (`SampleHistory`). Laufwerke und Schnittstellen über ihre `id` bzw. ihren Namen.
public enum MetricKey: Hashable, Sendable {
    case cpuTotal
    /// Systemanteil der CPU-Last (Übersicht der Menüleiste, #495).
    case cpuSystem
    case cpuCore(Int)
    case memoryUsed
    /// Bestandteil des Arbeitsspeichers für die Stapelfläche.
    case memory(MemoryComponents.Kind)
    case diskRead(String)
    case diskWrite(String)
    case received(String)
    case sent(String)
    case gpu
    case processCPU(ProcessKey)
    /// Summe der Leistung aller messbaren (eigenen) Prozesse in Milliwatt.
    case energyTotal
    /// Leistungsaufnahme des Macs in Milliwatt (Akku-Quelle).
    case systemPower
    /// Ladestand des Akkus 0…1.
    case batteryCharge
    /// Leistungsaufnahme des SoC in Watt (`SensorModel`, TM-9.4).
    case power
    /// Leistungsaufnahme der Neural Engine in Watt (`SensorModel`, Chip-Tab).
    case neuralEnginePower
    /// Leistungsaufnahme von CPU und GPU in Watt (`SensorModel`, Darstellung „Je Block“, TM-14.5).
    case cpuPower
    case gpuPower
}

/// Sichtbarer Zeitraum eines Graphen (Spec §2).
public enum HistoryWindow: Hashable, Sendable, CaseIterable {
    case oneMinute, fiveMinutes, fifteenMinutes

    public var duration: Duration {
        switch self {
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(300)
        case .fifteenMinutes: .seconds(900)
        }
    }
}

/// Messtakt (Spec §3), Standard 1 s.
public enum TaskManagerInterval: String, Hashable, Sendable, CaseIterable, Identifiable {
    case halfSecond, oneSecond, twoSeconds, fiveSeconds

    public static let `default` = TaskManagerInterval.oneSecond

    public var id: Self { self }

    public var duration: Duration {
        switch self {
        case .halfSecond: .milliseconds(500)
        case .oneSecond: .seconds(1)
        case .twoSeconds: .seconds(2)
        case .fiveSeconds: .seconds(5)
        }
    }
}
