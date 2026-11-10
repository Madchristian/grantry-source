import Foundation

/// Pegel der Übersicht (Optik 2026-11-07): Messgröße, Text unter dem Pegel und Füllstand 0…1.
public struct OverviewMeter: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case cpu, power, gpu, memory
    }

    public let kind: Kind
    public let title: String
    public let value: String
    /// `nil`: nicht gemessen – der Pegel bleibt dunkel.
    public let level: Double?

    public var id: Kind { kind }
}

/// Zeile der Liste „Top-Prozesse“: nach CPU sortiert, `heat` 0…1 relativ zum Spitzenreiter.
public struct OverviewProcess: Hashable, Sendable, Identifiable {
    public let key: ProcessKey
    public let pid: String
    public let name: String
    public let cpu: String
    public let memory: String
    public let heat: Double

    public var id: ProcessKey { key }
}

/// Übersicht des Task-Managers (Optik 2026-11-07): Pegel, Top-Prozesse und Statuszeile aus dem fertigen Stand –
/// ausschließlich Werte, die der Task-Manager ohnehin misst. Nicht Gemessenes erscheint als „–“, nie als 0.
public enum OverviewPresentation {
    public static let topProcessCount = 12

    /// CPU, Leistung (nur mit Sensoren des Helpers), GPU (nur mit Auslastung) und Arbeitsspeicher. `powerScale` ist die
    /// Obergrenze der Leistungsachse in Watt, damit Pegel und Graph dieselbe Skala zeigen.
    public static func meters(for snapshot: TaskManagerSnapshot, sensors: SensorReading?,
                              powerScale: Double) -> [OverviewMeter] {
        var meters = [OverviewMeter(kind: .cpu, title: "CPU", value: PerformancePresentation.percent(snapshot.cpu?.total),
                                    level: snapshot.cpu?.total)]
        if let milliwatts = sensors?.combinedMilliwatts {
            meters.append(OverviewMeter(kind: .power, title: "Leistung", value: PerformancePresentation.watts(milliwatts),
                                        level: powerScale > 0 ? min(milliwatts / 1000 / powerScale, 1) : nil))
        }
        if let utilization = snapshot.gpu?.utilization {
            meters.append(OverviewMeter(kind: .gpu, title: "GPU", value: PerformancePresentation.percent(utilization),
                                        level: utilization))
        }
        let memoryShare = snapshot.memory.flatMap(PerformancePresentation.usedShare)
        meters.append(OverviewMeter(kind: .memory, title: "Speicher", value: PerformancePresentation.percent(memoryShare),
                                    level: memoryShare))
        return meters
    }

    /// Die Prozesse mit der höchsten CPU-Last; ohne Messung (erste Messung, fremde Prozesse ohne ps) fallen sie weg.
    public static func topProcesses(in snapshot: TaskManagerSnapshot, count: Int = topProcessCount)
        -> [OverviewProcess] {
        let measured = snapshot.processes.filter { $0.cpuLoad != nil }
            .sorted { ($0.cpuLoad ?? 0, $1.key.pid) > ($1.cpuLoad ?? 0, $0.key.pid) }
            .prefix(count)
        let peak = max(measured.first?.cpuLoad ?? 0, 0.01)
        return measured.map { process in
            let figures = ProcessFigures(cpuLoad: process.cpuLoad, memoryBytes: process.memoryBytes, diskPerSecond: nil,
                                         networkPerSecond: nil)
            return OverviewProcess(key: process.key, pid: "\(process.key.pid)", name: process.name,
                            cpu: ProcessColumn.cpu.text(figures), memory: ProcessColumn.memory.text(figures),
                            heat: min((process.cpuLoad ?? 0) / peak, 1))
        }
    }

    /// Statuszeile: Takt, Prozesse und Threads, Laufzeit.
    public static func status(for snapshot: TaskManagerSnapshot, interval: String, uptime: TimeInterval) -> [String] {
        let stats = PerformancePresentation.stats(for: .cpu, in: snapshot, uptime: uptime)
        let value = { (title: String) in stats.first { $0.title == title }?.value ?? PerformancePresentation.missing }
        return ["Takt \(interval)", "\(value("Prozesse")) Prozesse · \(value("Threads")) Threads",
                "Laufzeit \(value("Laufzeit"))"]
    }

    /// Summe mehrerer Reihen desselben Verlaufs (etwa der CPU-Last aller Prozesse eines Benutzers), am neuesten Wert
    /// ausgerichtet; eine Stelle ohne jeden Wert bleibt Lücke.
    public static func sum(_ series: [HistoryPoints]) -> HistoryPoints? {
        combine(series) { $0.reduce(0, +) }
    }

    /// Mittel mehrerer Reihen desselben Verlaufs (etwa aller Effizienzkerne), am neuesten Wert ausgerichtet; eine Stelle
    /// ohne jeden Wert bleibt Lücke.
    public static func average(_ series: [HistoryPoints]) -> HistoryPoints? {
        combine(series) { $0.reduce(0, +) / Double($0.count) }
    }

    private static func combine(_ series: [HistoryPoints], _ reduce: ([Double]) -> Double) -> HistoryPoints? {
        guard let longest = series.max(by: { $0.values.count < $1.values.count }) else { return nil }
        let count = longest.values.count
        let values = (0..<count).map { index -> Double? in
            let measured = series.compactMap { points -> Double? in
                let offset = index - (count - points.values.count)
                return offset >= 0 ? points.values[offset] : nil
            }
            return measured.isEmpty ? nil : reduce(measured)
        }
        return HistoryPoints(values: values, spacing: longest.spacing, latestOffset: longest.latestOffset)
    }
}
