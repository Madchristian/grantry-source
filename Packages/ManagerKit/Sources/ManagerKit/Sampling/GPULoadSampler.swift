import Foundation
import IOKit
import Synchronization

/// GPU-Auslastung und belegter Speicher (Spec 2026-11-06 §3) aus `IOAccelerator` → `PerformanceStatistics`, ohne Root.
///
/// Die Quelle ist immer eingerichtet; beim Erzeugen läuft kein IOKit-Aufruf (das geschähe sonst beim App-Start auf dem
/// Main Actor). Ob eine Auslastung lesbar ist, zeigt erst die erste Lesung im Messtakt abseits des Main Actors. Fehlt
/// sie dort, merkt sich die Quelle das und meldet danach dauerhaft keinen Wert – ohne weiteren IOKit-Aufruf und ohne
/// Ausfall –, die GPU-Kachel fehlt dann. Nach einer gelungenen ersten Lesung gelten Ausfälle wie bei jeder Quelle.
public final class GPULoadSampler: MetricSource {
    struct NotAvailable: Error, Equatable {}

    /// Ergebnis der ersten Lesung; davor `unknown`.
    private enum Availability {
        case unknown, available, unavailable
    }

    private static let noValue = GPULoadReading(utilization: nil, usedMemoryBytes: nil)

    private let reader: @Sendable () throws -> GPULoadReading
    private let availability = Mutex(Availability.unknown)

    public convenience init() {
        self.init(reader: Self.readAccelerators)
    }

    /// Mit austauschbarer Lesefunktion, damit Tests Erzeugen und erste Lesung getrennt prüfen können.
    init(reader: @escaping @Sendable () throws -> GPULoadReading) {
        self.reader = reader
    }

    public func read() throws -> GPULoadReading {
        switch availability.withLock({ $0 }) {
        case .unavailable:
            return Self.noValue
        case .available:
            return try reader()
        case .unknown:
            return firstReading()
        }
    }

    /// Erste Lesung: entscheidet über die Verfügbarkeit. Ein Fehler oder eine fehlende Auslastung gilt als „nicht lesbar“.
    private func firstReading() -> GPULoadReading {
        guard let reading = try? reader(), reading.utilization != nil else {
            availability.withLock { $0 = .unavailable }
            return Self.noValue
        }
        availability.withLock { $0 = .available }
        return reading
    }

    /// Liest alle `IOAccelerator`-Dienste und nimmt bei mehreren GPUs die ausgelastetste.
    static func readAccelerators() throws -> GPULoadReading {
        var readings: [GPULoadReading] = []
        try IORegistryReader.forEachService(matching: "IOAccelerator") { accelerator in
            readings.append(reading(from: IORegistryReader.dictionary("PerformanceStatistics", of: accelerator)))
        }
        guard let reading = busiest(readings) else { throw NotAvailable() }
        return reading
    }

    static func reading(from statistics: [String: Any]?) -> GPULoadReading {
        GPULoadReading(
            utilization: IORegistryReader.uint64(statistics?["Device Utilization %"]).map { min(Double($0), 100) / 100 },
            usedMemoryBytes: IORegistryReader.uint64(statistics?["In use system memory"])
        )
    }

    /// Bei mehreren GPUs (Intel-Macs mit zwei Grafikchips) die mit der höchsten Auslastung; ohne Auslastung die erste.
    static func busiest(_ readings: [GPULoadReading]) -> GPULoadReading? {
        readings.filter { $0.utilization != nil }.max { ($0.utilization ?? 0) < ($1.utilization ?? 0) }
            ?? readings.first
    }
}
