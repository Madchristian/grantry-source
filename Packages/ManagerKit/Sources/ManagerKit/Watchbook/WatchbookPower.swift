import Foundation
import GrantryShared

/// Leistungsaufnahme laut Helper-Sensoren (`powermetrics`) in Watt (Spec 2026-11-08 §5.3, TM-14.5): gesamt und je Block.
/// Was eine Messung nicht enthält, bleibt leer.
public struct WatchbookPower: Hashable, Sendable {
    public var total: Double?
    public var cpu: Double?
    public var gpu: Double?
    public var neuralEngine: Double?

    /// Spalten des Wachbuchs und ihr Teil.
    static var parts: [(metric: WatchbookMetric, value: WritableKeyPath<WatchbookPower, Double?>)] {
        [(.power, \.total), (.cpuPower, \.cpu), (.gpuPower, \.gpu), (.neuralEnginePower, \.neuralEngine)]
    }

    /// Die Spalten der Leistungsaufnahme.
    public static var metrics: [WatchbookMetric] { parts.map(\.metric) }

    public init(total: Double?, cpu: Double?, gpu: Double?, neuralEngine: Double?) {
        self.total = total
        self.cpu = cpu
        self.gpu = gpu
        self.neuralEngine = neuralEngine
    }

    /// `nil`, wenn die Messung keinen Leistungswert enthält (nur Takt oder thermischer Druck).
    public init?(_ reading: SensorReading) {
        let watts = { (milliwatts: Double?) in milliwatts.map { $0 / 1_000 } }
        self.init(total: watts(reading.combinedMilliwatts), cpu: watts(reading.cpuMilliwatts),
                  gpu: watts(reading.gpuMilliwatts), neuralEngine: watts(reading.aneMilliwatts))
        guard !isEmpty else { return nil }
    }

    var isEmpty: Bool { Self.parts.allSatisfy { self[keyPath: $0.value] == nil } }

    func write(into values: inout WatchbookValues) {
        for part in Self.parts { values[part.metric] = self[keyPath: part.value] }
    }
}

/// Messungen der Sensoren bis zum nächsten Wachbuch-Punkt (TM-14.5). Die Sensoren messen alle 2 s, solange Leistung,
/// Chip oder Übersicht sichtbar ist; der Punkt erhält das Mittel seines Abschnitts, die volle Auflösung um Befunde die
/// jüngste Messung. Älteres als ein Abschnitt (`WatchbookPoint.maximumCoverage`) zählt nie – nach Ruhezustand oder
/// geschlossenem Tab bleibt die Leistung leer statt veraltet.
struct WatchbookPowerLog: Sendable {
    /// Höchstens so viele Messungen; mehr passen bei 2 s nicht in einen Abschnitt.
    static let capacity = 16

    private var readings: [(time: Date, power: WatchbookPower)] = []

    var count: Int { readings.count }

    mutating func record(_ power: WatchbookPower, at time: Date) {
        readings.append((time, power))
        if readings.count > Self.capacity { readings.removeFirst(readings.count - Self.capacity) }
    }

    /// Mittel je Teil über die Messungen des Abschnitts bis `end`; danach beginnt der nächste leer.
    mutating func section(endingAt end: Date) -> WatchbookPower? {
        let recent = readings.filter { Self.isFresh($0.time, at: end) }.map(\.power)
        readings.removeAll { $0.time <= end }
        var mean = WatchbookPower(total: nil, cpu: nil, gpu: nil, neuralEngine: nil)
        for part in WatchbookPower.parts {
            let measured = recent.compactMap { $0[keyPath: part.value] }
            guard !measured.isEmpty else { continue }
            mean[keyPath: part.value] = measured.reduce(0, +) / Double(measured.count)
        }
        return mean.isEmpty ? nil : mean
    }

    /// Jüngste Messung, sofern sie in den Abschnitt bis `time` fällt.
    func latest(at time: Date) -> WatchbookPower? {
        readings.last.flatMap { Self.isFresh($0.time, at: time) ? $0.power : nil }
    }

    private static func isFresh(_ time: Date, at end: Date) -> Bool {
        time <= end && end.timeIntervalSince(time) <= WatchbookPoint.maximumCoverage
    }
}
