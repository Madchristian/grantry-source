import Foundation

/// Messgröße eines Wachbuch-Punkts (Spec 2026-11-08 §5.1) und zugleich Spalte der Wachbuch-Datei: Die Reihenfolge der
/// Fälle ist die Spaltenfolge im Dateiformat (`WatchbookFileFormat`). Neue Messgrößen kommen nur hinten dazu (ältere
/// Zeilen lesen sich dann ohne sie); jede andere Änderung braucht eine neue Formatversion.
public enum WatchbookMetric: Int, CaseIterable, Hashable, Sendable {
    /// CPU gesamt als Anteil aller Kerne (0…1).
    case cpuTotal
    /// Mittlere Auslastung der Leistungs- bzw. Effizienzkerne (0…1); leer ohne solche Kerne (Intel).
    case cpuPerformance
    case cpuEfficiency
    /// Arbeitsspeicher belegt (wie „Benutzter Speicher“), davon komprimiert, und Swap in Byte.
    case memoryUsed
    case memoryCompressed
    case swapUsed
    /// Speicherdruck: 0 normal, 1 erhöht, 2 kritisch.
    case memoryPressure
    /// Datenträger gesamt (alle Laufwerke) in Byte/s.
    case diskRead
    case diskWrite
    /// Netz gesamt (Schnittstellen mit Kachel, ohne Loopback) in Byte/s.
    case networkReceived
    case networkSent
    /// GPU-Auslastung (0…1).
    case gpu
    /// Thermischer Zustand: 0 normal, 1 erhöht, 2 ernst, 3 kritisch (`ProcessInfo.ThermalState`).
    case thermalState
    /// Ladestand des Akkus (0…1).
    case batteryCharge
    /// Stromquelle: 0 Akku, 1 Netzteil; leer ohne Akku.
    case externalPower
    /// Leistungsaufnahme in Watt – nur, wenn die Sensoren des Helpers ohnehin laufen.
    case power
    /// Leistungsaufnahme von CPU, GPU und Neural Engine in Watt, wie `power` (TM-14.5).
    case cpuPower
    case gpuPower
    case neuralEnginePower

    /// Raster der Datei: Sie speichert ganze Schritte (0,1 % CPU, 1 MiB Speicher, 100 B/s, 0,1 W gesamt, 0,01 W je
    /// Block – die Neural Engine braucht oft nur Hundertstel).
    var quantum: WatchbookQuantum {
        switch self {
        case .cpuTotal, .cpuPerformance, .cpuEfficiency, .gpu, .batteryCharge: .fraction(1_000)
        case .memoryUsed, .memoryCompressed, .swapUsed: .multiple(1_048_576)
        case .diskRead, .diskWrite, .networkReceived, .networkSent: .multiple(100)
        case .memoryPressure, .thermalState, .externalPower: .multiple(1)
        case .power: .fraction(10)
        case .cpuPower, .gpuPower, .neuralEnginePower: .fraction(100)
        }
    }
}

/// Schrittweite eines Werts in der Datei. Teilen bzw. Vervielfachen statt Multiplizieren mit 0,001: So liest sich
/// 123 Schritte genau als `0.123` zurück.
enum WatchbookQuantum: Sendable {
    /// Wert = Schritte ÷ Teiler.
    case fraction(Double)
    /// Wert = Schritte × Faktor.
    case multiple(Double)

    /// Größte Schrittzahl; darunter sind ganze Zahlen als `Double` exakt.
    private static let maximumSteps = 1e15

    /// Ob `value` als ganze Schritte in die Datei passt.
    func fits(_ value: Double) -> Bool {
        let scaled = scaled(value)
        return scaled.isFinite && abs(scaled) <= Self.maximumSteps
    }

    /// Voraussetzung: `fits(value)`.
    func steps(_ value: Double) -> Int64 { Int64(scaled(value).rounded()) }

    func value(_ steps: Int64) -> Double {
        switch self {
        case .fraction(let divisor): Double(steps) / divisor
        case .multiple(let factor): Double(steps) * factor
        }
    }

    private func scaled(_ value: Double) -> Double {
        switch self {
        case .fraction(let divisor): value * divisor
        case .multiple(let factor): value / factor
        }
    }
}

/// Werte je Messgröße. `nil` heißt „nicht gemessen“ und wird nie zu 0 (Standard §3.4); ungültige Werte (negativ, nicht
/// endlich, zu groß für die Datei) gelten ebenfalls als nicht gemessen.
public struct WatchbookValues: Hashable, Sendable {
    private var storage = [Double?](repeating: nil, count: WatchbookMetric.allCases.count)

    public init() {}

    public subscript(metric: WatchbookMetric) -> Double? {
        get { storage[metric.rawValue] }
        set { storage[metric.rawValue] = newValue.flatMap { $0 >= 0 && metric.quantum.fits($0) ? $0 : nil } }
    }

    /// Nichts gemessen.
    public var isEmpty: Bool { storage.allSatisfy { $0 == nil } }
}
