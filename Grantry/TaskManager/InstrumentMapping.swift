import GrantryCharts
import ManagerKit

// Zuordnung der Daten des Task-Managers zu Farben und Tönen der Instrumententafel (docs/design/instrumententafel.md
// §2.3, §2.5): eine Stelle für Spalten, Kennzahlen und Zustände, damit Tabellen, Kacheln und Zeilen dieselbe Farbe
// derselben Messgröße zeigen.

extension ProcessColumn {
    /// Farbe der Hitze in Zellen und Spaltenkopf.
    var hue: InstrumentHue {
        switch self {
        case .name, .cpu: .cpu
        case .memory: .memory
        case .disk: .diskRead
        case .network: .received
        case .energy, .energyTrend: .power
        }
    }
}

extension PowerPart {
    /// Gesamt in der Farbe der Leistung, die Blöcke in der Farbe ihrer Messgröße (§2.3, wie im Chip-Tab).
    var hue: InstrumentHue {
        switch self {
        case .total: .power
        case .cpu: .cpu
        case .gpu: .gpu
        case .neuralEngine: .neuralEngine
        }
    }
}

extension ProcessDetailColumn {
    var hue: InstrumentHue {
        switch self {
        case .memory: .memory
        default: .cpu
        }
    }
}

extension AppUsageMetric {
    var hue: InstrumentHue {
        switch self {
        case .cpu: .cpu
        case .energy: .power
        case .network: .received
        case .disk: .diskRead
        }
    }
}

extension SystemVerdict {
    var statusItems: [StatusItem] { items.map { StatusItem($0.text, tone: $0.tone.statusTone) } }
    var hasFinding: Bool { level != .calm }
}
