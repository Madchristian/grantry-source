import GrantryCharts
import ManagerKit
import SwiftUI

/// Kopf der Aktivität als Panel (Gestaltung „Lagebild“, #366): Datenverkehr des Macs als Spiegel der letzten 2 Minuten mit
/// den aktuellen Raten, darunter die Kennzahlen als Messfelder in einer Reihe.
struct NetworkActivityHeader: View {
    let overview: NetworkActivityOverview
    let history: [TrafficRate]

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Datenverkehr"), detail: String(localized: "Alle Programme · letzte 2 Minuten"))
            TrafficMirror(rate: overview.rate, history: history)
            MeasureFieldRow(fields: [
                (String(localized: "Empfangen gesamt"), TrafficFormat.bytes(overview.transferred.received)),
                (String(localized: "Gesendet gesamt"), TrafficFormat.bytes(overview.transferred.sent)),
                (String(localized: "Programme aktiv"), "\(overview.activePrograms)"),
                (String(localized: "Offene Verbindungen"), "\(overview.openConnections)"),
                (String(localized: "Gegenstellen"), "\(overview.remoteHosts)"),
            ])
        }
        .instrumentPanel()
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
        .accessibilityReading(Text(label), value: Text(verbatim: TrafficFormat.rate(value)))
    }

    private var label: LocalizedStringKey { direction == .download ? "Empfangen" : "Gesendet" }
}
