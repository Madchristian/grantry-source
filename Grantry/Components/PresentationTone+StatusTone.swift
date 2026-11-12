import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

extension PresentationTone {
    /// Ton der Instrumententafel (Standard §2.5) – die einzige Abbildung `PresentationTone` → `StatusTone` in der App:
    /// „Warnung“ heißt dort „auffällig“ (Bernstein des Befund-Punkts).
    var statusTone: StatusTone {
        switch self {
        case .positive: .positive
        case .neutral: .neutral
        case .warning: .finding
        case .critical: .critical
        }
    }

    /// Grafikfarbe des Tons für Ansichten ohne Zugriff auf die Umgebung; folgt dem Erscheinungsbild. Neue Ansichten
    /// nehmen `environment.statusColor(tone.statusTone)` oder `StatusChip`.
    var color: Color { statusTone.appearanceColor }
}

extension VerdictShield {
    /// Schildform der Lage- und Zustandszeile (Spec 2026-11-10 § 11.3 c) – die einzige Abbildung in der App.
    var shieldForm: ShieldForm {
        switch self {
        case .calm: .calm
        case .finding: .finding
        case .open: .open
        }
    }
}

extension StatusTone {
    /// Grafikfarbe, die sich wie `color(in:)` je Erscheinungsbild auflöst – ohne Systemfarben.
    var appearanceColor: Color {
        guard self != .neutral else { return .instrumentSecondary }
        let variants = [ColorScheme.light, .dark].map { NSColor(color(in: $0)) }
        let light = variants[0], dark = variants[1]
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension RecordBadge {
    /// Badge als kleiner Zustandschip (§3.8): „prüfen“ im Ton des Schweregrads, „neu“ und „aufräumen“ neutral; VoiceOver
    /// liest den Schweregrad mit.
    var instrumentBadge: InstrumentBadge {
        InstrumentBadge(title, tone: tone.statusTone, spoken: accessibilityLabel)
    }
}

extension AutostartStatus {
    /// Zustand eines Autostart-Eintrags als kleiner Zustandschip.
    var instrumentBadge: InstrumentBadge {
        InstrumentBadge(title, tone: tone.statusTone)
    }
}
