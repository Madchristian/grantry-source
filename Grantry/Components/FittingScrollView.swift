import GrantryCharts
import SwiftUI

/// Bildlauf als Sicherung um den Inhalt eines Fensterbereichs (#480): Passt der Inhalt, füllt er den Bereich genau wie
/// ohne Bildlauf – Tabellen und Listen mit `maxHeight: .infinity` behalten ihren eigenen Bildlauf. Ist er höher oder
/// breiter, als der Bereich erlaubt, rollt er hier, statt seine Mindestgröße nach oben zu melden.
///
/// Ohne diese Sicherung meldete ein zu hoher Inhalt (Leistung › Pro Kern, Energie, Erweiterungen) seine Mindesthöhe an
/// die `NavigationSplitView`; das Fenster konnte nicht mitwachsen, und SwiftUI zentrierte die ganze Split-Ansicht im
/// Fenster: Tab-Leiste und obere Einträge der Seitenleiste lagen über der Titelleiste und waren nicht mehr erreichbar.
///
/// Mit `axes: .horizontal` rollt nur die Breite, mit sichtbarem Rollbalken: für Tabellen, deren Spalten im kleinsten
/// Fenster nicht nebeneinander passen (Details, #486) – vorher wirkte der Inhalt dort rechts abgeschnitten.
struct FittingScrollView<Content: View>: View {
    var axes: Axis.Set = [.horizontal, .vertical]
    @ViewBuilder let content: Content

    /// `ImageRenderer` zeichnet keinen Bildlauf; im Bild steht der Inhalt darum ohne.
    @Environment(\.chartSnapshotRendering) private var snapshot

    var body: some View {
        if snapshot {
            content
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        GeometryReader { geometry in
            ScrollView(axes) {
                FillingLayout(minimum: geometry.size) { content }
            }
            .scrollBounceBehavior(.basedOnSize, axes: axes)
            .scrollIndicators(axes == .horizontal ? .visible : .automatic, axes: .horizontal)
        }
    }
}

/// Schlägt dem Inhalt die sichtbare Größe vor und wird mindestens so groß; was der Inhalt darüber hinaus braucht, rollt
/// im umgebenden `ScrollView`. Auch beim Ablegen bekommt der Inhalt die sichtbare Größe vorgeschlagen, nicht die eigene:
/// Sonst wuchs ein Inhalt, der eine vorgeschlagene Höhe füllt (Tabelle unter gestapelten Karten), über den gemessenen
/// und damit rollbaren Bereich hinaus und blieb unten unerreichbar (Nachbewertung 2026.11.9/1531, Sollte 1, #507).
private struct FillingLayout: Layout {
    let minimum: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(minimum)) ?? .zero
        return CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(minimum))
    }
}
