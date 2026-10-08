import ManagerKit
import SwiftUI

/// Kopf der Aktivität: Summe ↓/s und ↑/s des Macs, daneben der Verlauf der letzten 2 Minuten (empfangen in der
/// Akzentfarbe, gesendet in Sekundärfarbe, gemeinsame Skala).
struct NetworkActivityHeader: View {
    let total: TrafficRate
    let history: [TrafficRate]

    var body: some View {
        HStack(spacing: 16) {
            TrafficRateLabel(value: total.download, direction: .download)
            TrafficRateLabel(value: total.upload, direction: .upload)
            Spacer(minLength: 8)
            TrafficSparkline(history: history,
                             help: "Verlauf der letzten 2 Minuten: empfangen (farbig) und gesendet (grau)")
                .frame(width: 160, height: 28)
        }
        .font(.callout)
        .padding(8)
    }
}

/// Rate mit Pfeil (↓ empfangen, ↑ gesendet); VoiceOver liest Richtung und Wert.
struct TrafficRateLabel: View {
    enum Direction {
        case download, upload
    }

    let value: Double
    let direction: Direction

    var body: some View {
        Label {
            Text(verbatim: TrafficFormat.rate(value)).monospacedDigit()
        } icon: {
            Image(systemName: direction == .download ? "arrow.down" : "arrow.up")
        }
        .help(Text(label))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: TrafficFormat.rate(value)))
    }

    private var label: LocalizedStringKey { direction == .download ? "Empfangen" : "Gesendet" }
}
