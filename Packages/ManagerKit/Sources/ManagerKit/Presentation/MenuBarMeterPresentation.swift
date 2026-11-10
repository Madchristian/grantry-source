import Foundation

/// Inhalt eines Menüleisten-Elements (TM17, Spec 2026-11-09 § 2). Nicht Gemessenes bleibt `nil` bzw. „–“ (Spec § 5).
public struct MenuBarMeterReading: Equatable, Sendable {
    public enum Gauge: Equatable, Sendable {
        /// Pegel 0…1 (CPU, GPU, Arbeitsspeicher).
        case level(Double?)
        /// Thermometer: Füllstand je thermischer Stufe (¼ … voll).
        case thermometer(Double?)
        case battery(Double?, isCharging: Bool)
    }

    public let tag: String
    /// Eine Zeile (Wert) oder zwei (Netz, Datenträger).
    public let lines: [String]
    /// Breiteste mögliche Zeilen – das Element behält seine Breite, damit nichts rechts davon je Takt springt.
    public let widest: [String]
    /// Verlauf 0…1, älteste zuerst; bei Netz und Datenträger die obere Hälfte (empfangen bzw. lesen).
    public let history: [Double?]
    /// Untere Hälfte des gespiegelten Verlaufs (gesendet bzw. schreiben); sonst `nil`.
    public let lowerHistory: [Double?]?
    public let gauge: Gauge?
    /// Auffällig (Befund-Punkt): Speicherdruck erhöht, Thermik hoch oder kritisch, Akku höchstens 20 % ohne Laden.
    public let isFinding: Bool
    public let accessibilityLabel: String
    public let accessibilityValue: String
}

/// Werte der Menüleisten-Elemente mit denselben Texten wie der Leistung-Tab (`PerformancePresentation`).
public enum MenuBarMeterPresentation {
    /// Punkte des Mini-Graphen: 30 – auf 28 pt Breite noch als Kurve lesbar.
    public static let pointCount = 30
    /// Untergrenze der gemeinsamen Skala von Netz und Datenträger wie `MirrorGraph`: wenig Verkehr bleibt flach.
    static let mirrorMinimum = 1_000_000.0
    private static let lowBattery = 0.2
    private static let missing = PerformancePresentation.missing
    private static let percentWidest = ["100 %"]

    public static func reading(for kind: MenuBarMeterKind, in frame: TaskManagerFrame) -> MenuBarMeterReading {
        let snapshot = frame.snapshot
        switch kind {
        case .overview: return overview(frame)
        case .cpu:
            return share(kind, snapshot.cpu?.total, history: points(.cpuTotal, in: frame))
        case .gpu:
            return share(kind, snapshot.gpu?.utilization, history: points(.gpu, in: frame))
        case .memory: return memory(frame)
        case .network: return network(frame)
        case .disk: return disk(frame)
        case .thermal: return thermal(snapshot.thermal)
        case .battery: return battery(snapshot.battery)
        }
    }

    /// Zwei Reihen auf gemeinsamer Skala (mindestens `mirrorMinimum`), als Anteile 0…1.
    public static func mirrored(upper: [Double?], lower: [Double?]) -> (upper: [Double?], lower: [Double?]) {
        let peak = max((upper + lower).compactMap { $0 }.max() ?? 0, mirrorMinimum)
        let scale = { (values: [Double?]) in values.map { $0.map { min(max($0 / peak, 0), 1) } } }
        return (scale(upper), scale(lower))
    }

    private static func points(_ key: MetricKey, in frame: TaskManagerFrame) -> [Double?] {
        Array(frame.history.points(for: key, in: .oneMinute).suffix(pointCount))
    }

    private static func overview(_ frame: TaskManagerFrame) -> MenuBarMeterReading {
        let memoryShare = frame.snapshot.memory.flatMap(PerformancePresentation.usedShare)
        let value = "CPU \(PerformancePresentation.percent(frame.snapshot.cpu?.total)), "
            + "Arbeitsspeicher \(PerformancePresentation.percent(memoryShare))"
        return MenuBarMeterReading(tag: "", lines: [], widest: [], history: points(.cpuTotal, in: frame),
                                   lowerHistory: nil, gauge: .level(memoryShare), isFinding: false,
                                   accessibilityLabel: MenuBarMeterKind.overview.title, accessibilityValue: value)
    }

    private static func share(_ kind: MenuBarMeterKind, _ share: Double?, history: [Double?],
                              isFinding: Bool = false, note: String? = nil) -> MenuBarMeterReading {
        let text = PerformancePresentation.percent(share)
        return MenuBarMeterReading(tag: kind.tag, lines: [text], widest: percentWidest, history: history,
                                   lowerHistory: nil, gauge: .level(share), isFinding: isFinding,
                                   accessibilityLabel: kind.title,
                                   accessibilityValue: [text, note].compactMap { $0 }.joined(separator: ", "))
    }

    private static func memory(_ frame: TaskManagerFrame) -> MenuBarMeterReading {
        let memory = frame.snapshot.memory
        let usedShare = memory.flatMap(PerformancePresentation.usedShare)
        let physical = memory.map { Double($0.physicalBytes) } ?? 0
        let history = physical > 0 ? points(.memoryUsed, in: frame).map { $0.map { $0 / physical } } : []
        let pressure = memory?.pressure
        let isFinding = pressure == .warning || pressure == .critical
        let note = isFinding ? pressure.map { "Speicherdruck \(ProcessCleanupPresentation.pressureText($0))" } : nil
        return share(.memory, usedShare, history: history, isFinding: isFinding, note: note)
    }

    private static func network(_ frame: TaskManagerFrame) -> MenuBarMeterReading {
        let interface = PerformancePresentation.primaryInterface(in: frame.snapshot.interfaces)
        let traces = interface.map { mirrored(upper: points(.received($0.name), in: frame),
                                              lower: points(.sent($0.name), in: frame)) }
        return twoWay(.network, prefixes: ("↓", "↑"), spoken: ("empfangen", "gesendet"),
                      rates: (interface?.receivedPerSecond, interface?.sentPerSecond), traces: traces)
    }

    private static func disk(_ frame: TaskManagerFrame) -> MenuBarMeterReading {
        let drive = frame.snapshot.drives.first
        let traces = drive.map { mirrored(upper: points(.diskRead($0.id), in: frame),
                                          lower: points(.diskWrite($0.id), in: frame)) }
        return twoWay(.disk, prefixes: ("L", "S"), spoken: ("lesen", "schreiben"),
                      rates: (drive?.readPerSecond, drive?.writePerSecond), traces: traces)
    }

    private static func twoWay(_ kind: MenuBarMeterKind, prefixes: (String, String), spoken: (String, String),
                               rates: (Double?, Double?), traces: (upper: [Double?], lower: [Double?])?)
        -> MenuBarMeterReading {
        let upper = rate(rates.0), lower = rate(rates.1)
        let widest = ["999 KB/s", "9,9 MB/s", "999 MB/s"]
        return MenuBarMeterReading(
            tag: kind.tag, lines: ["\(prefixes.0) \(upper)", "\(prefixes.1) \(lower)"],
            widest: widest.map { "\(prefixes.0) \($0)" }, history: traces?.upper ?? [], lowerHistory: traces?.lower,
            gauge: nil, isFinding: false, accessibilityLabel: kind.title,
            accessibilityValue: "\(spoken.0) \(upper), \(spoken.1) \(lower)"
        )
    }

    private static func rate(_ bytesPerSecond: Double?) -> String { bytesPerSecond.map(TrafficFormat.rate) ?? missing }

    private static func thermal(_ condition: ThermalCondition?) -> MenuBarMeterReading {
        let text = condition.map { thermalText($0.state) } ?? missing
        let isFinding = condition.map { $0.state == .serious || $0.state == .critical } ?? false
        let lowPower = condition.map { "Energiesparmodus \($0.isLowPowerModeEnabled ? "an" : "aus")" }
        return MenuBarMeterReading(
            tag: MenuBarMeterKind.thermal.tag, lines: [text], widest: ["Kritisch", "Erhöht", "Normal"], history: [],
            lowerHistory: nil, gauge: .thermometer(condition.map { thermalLevel($0.state) }), isFinding: isFinding,
            accessibilityLabel: MenuBarMeterKind.thermal.title,
            accessibilityValue: [text, lowPower].compactMap { $0 }.joined(separator: ", ")
        )
    }

    /// Kurz für die Menüleiste; ausführlich in `PerformancePresentation.thermalText`.
    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Erhöht"
        case .serious: "Hoch"
        case .critical: "Kritisch"
        @unknown default: missing
        }
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal: 0.25
        case .fair: 0.5
        case .serious: 0.75
        default: 1
        }
    }

    private static func battery(_ battery: BatteryReading?) -> MenuBarMeterReading {
        let text = PerformancePresentation.percent(battery?.charge)
        let isCharging = battery?.isCharging ?? false
        let isFinding = !isCharging && (battery?.charge).map { $0 <= lowBattery } ?? false
        return MenuBarMeterReading(
            tag: MenuBarMeterKind.battery.tag, lines: [text], widest: percentWidest, history: [], lowerHistory: nil,
            gauge: .battery(battery?.charge, isCharging: isCharging), isFinding: isFinding,
            accessibilityLabel: MenuBarMeterKind.battery.title,
            accessibilityValue: isCharging ? "\(text), wird geladen" : text
        )
    }
}
