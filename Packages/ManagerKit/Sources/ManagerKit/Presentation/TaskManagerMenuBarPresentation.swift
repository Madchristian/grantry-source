import Foundation

/// Popover der Menüleisten-Elemente (#317, TM17): Kacheln, Kennzahlen und Thermik mit denselben Texten wie der
/// Leistung-Tab; die Symbole liefert `MenuBarMeterPresentation`.
public enum TaskManagerMenuBarPresentation {
    /// Kacheln des Popovers: CPU, Arbeitsspeicher, das erste Laufwerk und die Schnittstelle der Default-Route
    /// (`PerformancePresentation.primaryInterface(in:)`) in der Reihenfolge des Leistung-Tabs; was nicht gemessen ist,
    /// fehlt.
    public static func popoverTiles(for snapshot: TaskManagerSnapshot, configured: Set<TaskManagerSource>)
        -> [PerformanceTile] {
        let tiles = PerformancePresentation.tiles(for: snapshot, configured: configured)
        return [MenuBarMeterKind.cpu, .memory, .disk, .network].compactMap { tile(for: $0, in: tiles, snapshot: snapshot) }
    }

    /// Kachel des Leistung-Tabs zu einem Menüleisten-Element (TM17): Datenträger das erste Laufwerk, Netz die
    /// Schnittstelle der Default-Route; Thermik, Akku und „Auslastung“ haben keine.
    public static func tile(for kind: MenuBarMeterKind, in snapshot: TaskManagerSnapshot,
                            configured: Set<TaskManagerSource>) -> PerformanceTile? {
        tile(for: kind, in: PerformancePresentation.tiles(for: snapshot, configured: configured), snapshot: snapshot)
    }

    private static func tile(for kind: MenuBarMeterKind, in tiles: [PerformanceTile], snapshot: TaskManagerSnapshot)
        -> PerformanceTile? {
        switch kind {
        case .cpu: tiles.first { $0.metric == .cpu }
        case .memory: tiles.first { $0.metric == .memory }
        case .gpu: tiles.first { $0.metric == .gpu }
        case .disk: tiles.first { if case .drive = $0.metric { true } else { false } }
        case .network: PerformancePresentation.primaryInterfaceTile(in: tiles, for: snapshot)
        case .overview, .thermal, .battery: nil
        }
    }

    /// Kennzahlen des Leistung-Tabs für das Popover eines Elements, ohne die der Prozessquelle (Prozesse, Threads),
    /// die die Menüleiste nicht liest.
    public static func stats(for tile: PerformanceTile, in snapshot: TaskManagerSnapshot, uptime: TimeInterval)
        -> [PerformanceStat] {
        PerformancePresentation.stats(for: tile.metric, in: snapshot, uptime: uptime)
            .filter { !processStatTitles.contains($0.title) }
    }

    static let processStatTitles: Set<String> = ["Prozesse", "Threads"]

    /// Popover „Thermik“: Zustand und Energiesparmodus als Chips, ein Satz zur Bedeutung, Messfelder.
    public static func thermalDetail(_ condition: ThermalCondition?) -> ThermalDetail {
        let state = condition?.state
        let text = state.map(MenuBarMeterPresentation.thermalText) ?? PerformancePresentation.missing
        let tone: PresentationTone = switch state {
        case .nominal?: .positive
        case .fair?, nil: .neutral
        case .serious?: .warning
        default: .critical
        }
        let lowPower = condition?.isLowPowerModeEnabled ?? false
        let note = switch state {
        case .serious?, .critical?:
            "macOS senkt Takt und Leistung, um den Mac zu kühlen."
        case nil:
            "Noch kein Stand von macOS."
        default:
            "macOS drosselt nicht. Bei „hoch“ oder „kritisch“ senkt macOS Takt und Leistung, um den Mac zu kühlen."
        }
        return ThermalDetail(
            value: text,
            items: [SystemVerdict.Item(text: "Thermik \(text.lowercased())", tone: tone),
                    SystemVerdict.Item(text: lowPower ? "Energiesparmodus an" : "Energiesparmodus aus",
                                       tone: .neutral)],
            note: note,
            fields: [PerformanceStat("Stufe", text), PerformanceStat("Energiesparmodus", lowPower ? "an" : "aus")]
        )
    }

    public struct ThermalDetail: Equatable, Sendable {
        public let value: String
        public let items: [SystemVerdict.Item]
        public let note: String
        public let fields: [PerformanceStat]
    }
}
