import GrantryCharts
import SwiftUI

// Gemeinsame Teile der Kacheln CPU, Kerne, Prozesse und GPU (Teil B des Baukastens, Spec 2026-11-09-uebersicht-baukasten
// § 2). Keine Animation je Takt; Verläufe nur, wenn die Übersicht offen ist.

/// Verlauf der Kachel; ohne Verlauf (Popover geschlossen, Einstellungen) die Spur des aktuellen Werts, damit die Kachel
/// nicht leer wirkt. Der Wert steht schon im Kopf der Kachel, beides liest VoiceOver deshalb nicht noch einmal.
struct OverviewTileTrace<Graph: View>: View {
    let fraction: Double?
    let hue: InstrumentHue
    let graph: Graph?

    @Environment(\.self) private var environment

    var body: some View {
        Group {
            if let graph {
                graph.frame(maxHeight: .infinity)
            } else {
                Spur(fraction: fraction, color: environment.instrumentColor(hue))
                    .frame(height: InstrumentSize.spurTile)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Inhalt einer Kachel füllt die Zellen, die ihm das Raster vorgibt; was nicht passt, schneidet die Kachel ab, statt
    /// über Nachbarn zu zeichnen.
    func fillsOverviewTile(alignment: Alignment = .topLeading) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment).clipped()
    }
}
