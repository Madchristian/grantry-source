import Foundation

/// Stufe des Energieverbrauchs wie die Spalte „Energieverbrauch“ in Windows 11 (Spec 2026-11-06 §6 Stufe 2).
public enum EnergyLevel: Int, Hashable, Sendable, CaseIterable {
    case veryLow, low, moderate, high, veryHigh

    /// Untergrenzen in Milliwatt: ab 100 mW niedrig, ab 500 mW mittel, ab 1,5 W hoch, ab 4 W sehr hoch. Ein voll
    /// ausgelasteter Leistungskern (M4) liegt um 2,7 W (am 2026-11-06 gemessen).
    static let thresholds: [(level: EnergyLevel, milliwatts: Double)] = [
        (.veryHigh, 4_000), (.high, 1_500), (.moderate, 500), (.low, 100),
    ]

    public init(milliwatts: Double) {
        self = Self.thresholds.first { milliwatts >= $0.milliwatts }?.level ?? .veryLow
    }

    public var title: String {
        switch self {
        case .veryLow: "Sehr niedrig"
        case .low: "Niedrig"
        case .moderate: "Mittel"
        case .high: "Hoch"
        case .veryHigh: "Sehr hoch"
        }
    }

    /// Intensität für Heatmap und Lastfarbe (0…1).
    public var heat: Double {
        switch self {
        case .veryLow: 0.08
        case .low: 0.3
        case .moderate: 0.55
        case .high: 0.8
        case .veryHigh: 1
        }
    }
}

/// Texte für Leistung und Energiemengen, deutsch formatiert.
public enum EnergyFormat {
    private static let locale = Locale(identifier: "de_DE")

    /// „350 mW“, „2,7 W“, „89 W“; „–“ ohne Wert.
    public static func power(_ milliwatts: Double?) -> String {
        guard let milliwatts else { return PerformancePresentation.missing }
        return scaled(abs(milliwatts), small: "mW", large: "W")
    }

    /// Energiemenge in Wattstunden: „10 mWh“, „3,4 Wh“, „50 Wh“.
    public static func energy(joules: Double) -> String {
        scaled(max(joules, 0) / 3.6, small: "mWh", large: "Wh")
    }

    /// Unter 1 000 der kleinen Einheit ganzzahlig, darüber in der großen mit einer Nachkommastelle unter 10.
    private static func scaled(_ small: Double, small smallUnit: String, large largeUnit: String) -> String {
        guard small.rounded() >= 1_000 else { return "\(Int(small.rounded())) \(smallUnit)" }
        let large = small / 1_000
        let digits = large < 9.95 ? 1 : 0
        return "\(large.formatted(.number.precision(.fractionLength(digits)).locale(locale))) \(largeUnit)"
    }
}

/// Texte, Spalten und Auswahl des Energie-Tabs (Spec 2026-11-06 §6 Stufe 2). Nicht Gemessenes erscheint als „–“.
public enum EnergyPresentation {
    /// Spalten neben dem Namen.
    public static let columns: [ProcessColumn] = [.energy, .energyTrend, .cpu]

    /// Nach Energie absteigend; „System und andere Benutzer“ zugeklappt – dort misst macOS ohne Root keine Energie.
    public static var defaultOptions: ProcessListOptions {
        var options = ProcessListOptions()
        options.sort = ProcessSort(column: .energy, ascending: false)
        options.collapsedGroups = [.system]
        return options
    }

    /// Gilt auch mit bereitem Helper: Er liefert Leistungsaufnahme und Takt, aber keine Energie je Prozess
    /// (Bewertung 2026.11.7-1188, Mangel 14).
    public static let foreignNote = "Energie liest macOS ohne Administratorrechte nur für eigene Prozesse; Prozesse "
        + "anderer Benutzer bleiben hier ohne Wert."

    /// Der große Graph: Leistungsaufnahme des Macs, wenn der Akku sie meldet, sonst die Summe der eigenen Prozesse.
    public static func powerMetric(for battery: BatteryReading?) -> MetricKey {
        battery?.systemMilliwatts == nil ? .energyTotal : .systemPower
    }

    public static func powerTitle(for metric: MetricKey) -> String {
        metric == .systemPower ? "Leistungsaufnahme" : "Eigene Prozesse"
    }

    /// Aktueller Wert zum Graphen.
    public static func powerValue(for metric: MetricKey, in snapshot: TaskManagerSnapshot) -> String {
        if metric == .systemPower { return EnergyFormat.power(snapshot.battery?.systemMilliwatts) }
        let measured = snapshot.processes.compactMap(\.energyMilliwatts)
        return EnergyFormat.power(measured.isEmpty ? nil : measured.reduce(0, +))
    }

    public static func chargeText(_ battery: BatteryReading) -> String {
        PerformancePresentation.percent(battery.charge)
    }

    /// Kurzer Zustand unter dem Ladestand.
    public static func stateText(_ battery: BatteryReading) -> String {
        if battery.isCharged { return "Voll geladen" }
        if battery.isCharging { return "Lädt" }
        return battery.source == .battery ? "Akkubetrieb" : "Netzteil"
    }

    /// Lastfarbe des Rings: voll = kühl, leer = warm.
    public static func chargeHeat(_ battery: BatteryReading) -> Double {
        1 - (battery.charge ?? 1)
    }

    public static func batteryStats(_ battery: BatteryReading) -> [PerformanceStat] {
        var stats = [
            PerformanceStat("Leistungsaufnahme", EnergyFormat.power(battery.systemMilliwatts)),
            PerformanceStat("Akku", signedPower(battery.batteryMilliwatts)),
        ]
        if battery.isCharging {
            stats.append(PerformanceStat("Voll in", duration(battery.minutesToFull)))
        } else if battery.source == .battery {
            stats.append(PerformanceStat("Restlaufzeit", duration(battery.minutesToEmpty)))
        }
        stats += [
            PerformanceStat("Ladezyklen", cycles(battery)),
            PerformanceStat("Maximale Kapazität", PerformancePresentation.percent(battery.maximumCapacity)),
            PerformanceStat("Zustand", conditionText(battery.condition)),
        ]
        return stats
    }

    /// Panel „Netzteil und Laden“ (Spec 2026-11-08 § 5.3): nur mit Akku am Netzteil, dessen Angaben macOS meldet. Im
    /// Kopf, was das Netzteil gerade liefert, der Ring als Anteil an seiner Nennleistung („Auslastung“) – auch ohne
    /// Laden versorgt es den Mac (Befund 10.11.2026: „0 W“ und „0 %“ bei 24 W Leistungsaufnahme). Vier Messfelder,
    /// damit im schmalen Panel keines allein in einer Reihe steht.
    public static func chargingPanel(for battery: BatteryReading?) -> ChargingPanel? {
        guard let battery, let adapter = battery.adapter else { return nil }
        let charging = battery.batteryMilliwatts.map { max($0, 0) }
        let supplied = adapterMilliwatts(battery)
        let fraction = supplied.flatMap { supplied in
            adapter.watts.map { min(supplied / (Double($0) * 1_000), 1) }
        }
        return ChargingPanel(detail: adapter.name ?? "", value: wholeWatts(supplied), fraction: fraction, stats: [
            PerformanceStat("Netzteil", adapter.watts.map { "\($0) W" } ?? PerformancePresentation.missing),
            PerformanceStat("Ladeleistung", wholeWatts(charging)),
            PerformanceStat("Ladezustand", chargingState(battery)),
            PerformanceStat("Auslastung", PerformancePresentation.percent(fraction)),
        ], note: battery.isCharging || battery.isCharged ? nil : notChargingNote)
    }

    /// Warum „Lädt nicht“ am Netzteil: macOS nennt den Grund nicht öffentlich.
    public static let notChargingNote = "Der Mac läuft vom Netzteil. macOS lädt den Akku gerade nicht, etwa wegen "
        + "Ladegrenze, optimiertem Laden oder Wärme."

    /// Was das Netzteil liefert: Leistungsaufnahme des Macs und Leistung am Akku (positiv beim Laden, negativ, wenn der
    /// Akku zuschießt) – wie `SystemPowerIn` in `PowerTelemetryData`. Ohne beide Messwerte unbekannt.
    private static func adapterMilliwatts(_ battery: BatteryReading) -> Double? {
        battery.systemMilliwatts.flatMap { system in battery.batteryMilliwatts.map { max(system + $0, 0) } }
    }

    /// Ladezustand am Netzteil: „Voll geladen“, „Lädt“ oder „Lädt nicht“ (etwa Ladeschutz).
    private static func chargingState(_ battery: BatteryReading) -> String {
        if battery.isCharged { return "Voll geladen" }
        return battery.isCharging ? "Lädt" : "Lädt nicht"
    }

    /// „+31 W“ beim Laden, „−14 W“ beim Entladen, „0 W“, wenn der Akku ruht.
    private static func signedPower(_ milliwatts: Double?) -> String {
        guard let milliwatts, milliwatts.rounded() != 0 else { return wholeWatts(milliwatts) }
        return (milliwatts > 0 ? "+" : "−") + EnergyFormat.power(milliwatts)
    }

    /// Leistung an Akku und Netzteil: „0 W“ statt „0 mW“, wenn nichts fließt; „–“ ohne Messwert.
    private static func wholeWatts(_ milliwatts: Double?) -> String {
        milliwatts.map { $0.rounded() == 0 ? "0 W" : EnergyFormat.power($0) } ?? PerformancePresentation.missing
    }

    /// „4:14 h“.
    private static func duration(_ minutes: Int?) -> String {
        guard let minutes else { return PerformancePresentation.missing }
        return String(format: "%d:%02d h", minutes / 60, minutes % 60)
    }

    private static func cycles(_ battery: BatteryReading) -> String {
        guard let count = battery.cycleCount else { return PerformancePresentation.missing }
        let locale = Locale(identifier: "de_DE")
        guard let design = battery.designCycleCount else { return count.formatted(.number.locale(locale)) }
        return "\(count.formatted(.number.locale(locale))) von \(design.formatted(.number.locale(locale)))"
    }

    private static func conditionText(_ condition: BatteryCondition?) -> String {
        switch condition {
        case .normal: "Normal"
        case .serviceRecommended: "Service empfohlen"
        case nil: PerformancePresentation.missing
        }
    }
}

/// Inhalt des Panels „Netzteil und Laden“: Beschreibung des Netzteils, Ladeleistung als Wert und Anteil an der
/// Nennleistung, dazu die Messfelder.
public struct ChargingPanel: Hashable, Sendable {
    public let detail: String
    public let value: String
    /// Ladeleistung im Verhältnis zur Nennleistung, 0…1.
    public let fraction: Double?
    public let stats: [PerformanceStat]
    /// Erklärung unter den Messfeldern, etwa warum am Netzteil nicht geladen wird.
    public let note: String?
}
