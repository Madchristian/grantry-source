import Foundation

/// Texte einer Kernklasse (#589) für Chip-Tab, Menüleiste und „Leistung“ – nirgends sonst eine eigene Zuordnung.
extension CoreKind {
    /// Mehrzahl als Titel: „Super-Kerne“, „Leistungskerne“; unbekannte Klassen mit dem Namen laut System oder neutral.
    public var title: String {
        switch self {
        case .super: "Super-Kerne"
        case .performance: "Leistungskerne"
        case .efficiency: "Effizienzkerne"
        case .other(_, let name?): "\(name)-Kerne"
        case .other(let level, nil): "Kerne der Stufe \(level + 1)"
        case .unknown: "Kerne"
        }
    }

    /// Ein Kern für VoiceOver, vor seiner Nummer: „Super-Kern 12“.
    public var coreName: String {
        switch self {
        case .super: "Super-Kern"
        case .performance: "Leistungskern"
        case .efficiency: "Effizienzkern"
        case .other(_, let name?): "\(name)-Kern"
        case .other(let level, nil): "Kern der Stufe \(level + 1)"
        case .unknown: "Kern"
        }
    }

    /// Kürzel wie bei `powermetrics` („S“, „P“, „E“); unbekannte Klassen ohne, statt eines geratenen.
    public var tag: String? {
        switch self {
        case .super: "S"
        case .performance: "P"
        case .efficiency: "E"
        case .other, .unknown: nil
        }
    }
}
