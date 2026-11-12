import SwiftUI

extension EnvironmentValues {
    /// Für Bilder per `ImageRenderer` (Sichtprüfung, Snapshot-Tests): Der zeichnet den Inhalt einer `ScrollView` nicht.
    /// Gesetzt, ersetzt `ChartScrollView` sie durch einen `VStack`; Graphen zeichnen einen festen Zeitpunkt.
    @Entry public var chartSnapshotRendering = false
    /// Für `ImageRenderer`, der AppKit-Schalter nur als Platzhalter zeichnet: Gesetzt, zeichnet `SettingToggle` einen
    /// Schalter selbst. Größe und Grundlinie des fensterlosen `NSSwitch` hängen vom Skalierungsfaktor des Hauptbildschirms
    /// ab und verschoben die Zeilen auf einem Rechner mit 1×-Bildschirm. Die Galerie (offscreen) zeigt den nativen.
    @Entry public var chartDrawsSwitches = false
}

/// Senkrechter Bildlauf, ohne Rollbalken für Kachelspalten, mit für lange Tabellen; im Snapshot ein `VStack`.
public struct ChartScrollView<Content: View>: View {
    let showsIndicators: Bool
    let content: Content

    @Environment(\.chartSnapshotRendering) private var snapshot

    public init(showsIndicators: Bool = false, @ViewBuilder content: () -> Content) {
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public var body: some View {
        if snapshot {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView { content }
                .scrollIndicators(showsIndicators ? .automatic : .never)
        }
    }
}
