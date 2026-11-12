import Foundation

/// Kernklasse einer Leistungsstufe auf Apple Silicon (`hw.perflevelN`, #589) – die einzige Zuordnung für Chip-Tab,
/// Menüleiste und „Leistung“; Texte in `CoreKind+Presentation`. `unknown` bei Intel, virtuellen Maschinen oder
/// Kernen außerhalb des Profils.
public enum CoreKind: Hashable, Sendable {
    /// Super-Kerne (ab M5), schneller als die Leistungskerne.
    case `super`
    case performance, efficiency
    /// Stufe `level` mit unbekanntem oder fehlendem Namen, etwa eine Klasse künftiger Chips.
    case other(level: Int, name: String?)
    case unknown

    /// Klasse der Stufe `level` von `levelCount` (0 = schnellste) nach ihrem Namen laut System. Ohne Namen wie vor
    /// #589 nach Position: bei zwei Stufen die schnellere Leistungs-, die langsamere Effizienzkerne; eine einzelne
    /// Stufe ohne Namen hat keine Klasse.
    public init(levelName name: String?, level: Int, levelCount: Int) {
        switch name?.lowercased() {
        case "super": self = .super
        case "performance": self = .performance
        case "efficiency": self = .efficiency
        case nil where levelCount == 2: self = level == 0 ? .performance : .efficiency
        case nil where levelCount < 2: self = .unknown
        default: self = .other(level: level, name: name)
        }
    }
}

extension CoreKind: Comparable {
    /// Schnellste Klasse zuerst: Super, Leistung, unbekannte Klassen nach ihrer Stufe, Effizienz, ohne Klasse.
    public static func < (lhs: CoreKind, rhs: CoreKind) -> Bool {
        lhs.rank == rhs.rank ? lhs.level < rhs.level : lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .super: 0
        case .performance: 1
        case .other: 2
        case .efficiency: 3
        case .unknown: 4
        }
    }

    private var level: Int {
        if case .other(let level, _) = self { level } else { 0 }
    }
}
