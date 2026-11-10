import GrantryCharts
import ManagerKit
import SwiftUI

/// Live-Vorschau eines Elements in den Einstellungen. Liest den Stand erst hier, damit ein Takt nur die Symbole neu
/// zeichnet, und nur mit `isLive`: Das Einstellungsfenster bleibt nach dem Schließen bestehen und wertete sonst je Takt
/// weiter aus (#482).
struct MenuBarMeterLabel: View {
    let kind: MenuBarMeterKind
    let meters: MenuBarMetersModel
    let model: TaskManagerModel
    var isLive = true

    var body: some View {
        let frame = isLive ? model.latestFrame : .empty(interval: model.interval)
        MenuBarMeterImage(reading: MenuBarMeterPresentation.reading(for: kind, in: frame),
                          style: meters.style(for: kind), showsTags: meters.showsTags)
    }
}

/// Vorlagenbild eines Elements samt VoiceOver-Name und -Wert; auch die Vorschau der Einstellungen zeigt es.
struct MenuBarMeterImage: View, Equatable {
    let reading: MenuBarMeterReading
    let style: MenuBarMeterStyle
    let showsTags: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(nsImage: Self.image(reading: reading, style: style, showsTags: showsTags,
                                  increasedContrast: contrast == .increased))
            .accessibilityLabel(Text(verbatim: reading.spokenText))
    }

    /// Vorlagenbild mit VoiceOver-Beschreibung; auch für die Statusobjekte (`MenuBarMeterStatusItems`).
    static func image(reading: MenuBarMeterReading, style: MenuBarMeterStyle, showsTags: Bool,
                      increasedContrast: Bool) -> NSImage {
        let image = MenuBarMeterRenderer.image(for: MenuBarMeterFace(reading, style: style, showsTags: showsTags),
                                               increasedContrast: increasedContrast)
        image.accessibilityDescription = reading.spokenText
        return image
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reading == rhs.reading && lhs.style == rhs.style && lhs.showsTags == rhs.showsTags
    }
}

extension MenuBarMeterReading {
    /// Name und Wert für VoiceOver: „CPU, 12 %“.
    var spokenText: String { "\(accessibilityLabel), \(accessibilityValue)" }
}

extension MenuBarMeterFace {
    init(_ reading: MenuBarMeterReading, style: MenuBarMeterStyle, showsTags: Bool) {
        let gauge: Gauge? = switch reading.gauge {
        case .level(let share)?: .level(share)
        case .thermometer(let level)?: .thermometer(level)
        case .battery(let charge, let isCharging)?: .battery(charge, isCharging: isCharging)
        case nil: nil
        }
        self.init(tag: showsTags ? reading.tag : nil, lines: reading.lines, widest: reading.widest,
                  trace: reading.lowerHistory.map { .mirror(upper: reading.history, lower: $0) }
                      ?? .single(reading.history),
                  gauge: gauge, showsNumber: style.showsNumber, showsGraph: style.showsGraph,
                  showsBar: style.showsBar, isFinding: reading.isFinding)
    }
}
