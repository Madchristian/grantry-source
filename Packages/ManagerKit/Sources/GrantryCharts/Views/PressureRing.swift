import SwiftUI

/// Speicherdruck als Bogen (§3.5): Füllstand = belegter Anteil, Farbe = Zustandston der Druckstufe.
public struct PressureRing: View {
    public enum Level: Sendable, Equatable {
        case normal, warning, critical

        public var tone: StatusTone {
            switch self {
            case .normal: .positive
            case .warning: .finding
            case .critical: .critical
            }
        }

        var title: String {
            switch self {
            case .normal: String(localized: "Normal")
            case .warning: String(localized: "Erhöht")
            case .critical: String(localized: "Kritisch")
            }
        }
    }

    let fraction: Double
    let level: Level

    public init(fraction: Double, level: Level) {
        self.fraction = min(max(fraction, 0), 1)
        self.level = level
    }

    @Environment(\.self) private var environment

    public var body: some View {
        let color = environment.statusColor(level.tone)
        ArcGauge(fraction: fraction, color: color,
                 textColor: level == .normal ? .primary : environment.statusTextColor(level.tone),
                 value: fraction.formatted(.percent.precision(.fractionLength(0))), caption: level.title)
            // Eigenes Element: Bezeichnung „Speicherdruck“, Wert mit Stufe – statt der Beschriftung des Bogens.
            .accessibilityReading(Text("Speicherdruck"), value: Text(verbatim:
                "\(fraction.formatted(.percent.precision(.fractionLength(0)))), \(level.title)"))
    }
}
