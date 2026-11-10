import SwiftUI

/// Zeichenfläche der Graphen aus Formen statt `Canvas` (#521): Die Zeichenfunktion beschreibt Flächen, Linien und
/// Beschriftungen wie in einem `GraphicsContext`; dargestellt werden sie als `Shape`s und Texte. Ein `Canvas`, der neu
/// zeichnet, lässt SwiftUI im Prozess per GPU rastern und legt dafür einen Grafik-Pool von rund 257 MB an – unabhängig
/// von Größe und Inhalt, auch mit `opaque`, `colorMode`, `rendersAsynchronously` oder als `drawingGroup`. Formen rendert
/// Core Animation ohne diesen Pool (Abnahme 2026.11.10/1547: Übersicht, Energie, Chip und Pro Kern je rund 260 MB).
///
/// Wie `Canvas` nimmt die Fläche den angebotenen Platz ein und zeichnet bei jeder Auswertung neu; was über den Rand
/// ragt, schneidet sie ab. Mausereignisse erreicht sie auf der ganzen Fläche, nicht nur auf den Formen.
struct Plot: View {
    let site: StaticString
    let draw: (inout PlotContext, CGSize) -> Void

    #if DEBUG
    @Environment(\.renderRecorder) private var recorder
    #endif

    /// - Parameter site: Zählpunkt des Render-Wächters (`RenderProbe`) für jeden Zeichenaufruf.
    init(_ site: StaticString, draw: @escaping (inout PlotContext, CGSize) -> Void) {
        self.site = site
        self.draw = draw
    }

    var body: some View {
        GeometryReader { proxy in
            let marks = marks(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(marks.shapes.indices, id: \.self) { index in
                    marks.shapes[index].view(in: proxy.size)
                }
                ForEach(marks.labels.indices, id: \.self) { index in
                    marks.labels[index].view(in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .contentShape(Rectangle())
    }

    private func marks(in size: CGSize) -> PlotContext.Marks {
        #if DEBUG
        recorder?.record(site.description, \.draws)
        #endif
        var context = PlotContext()
        draw(&context, size)
        return context.marks
    }
}

/// Zeichenfunktion einer `Plot`: dieselben Aufrufe wie bei `GraphicsContext` (`fill`, `stroke`, `draw`, `translateBy`,
/// `scaleBy`). Kopien zeichnen wie dort auf dieselbe Fläche und tragen ihre eigene Verschiebung.
struct PlotContext {
    /// Füllung einer Form; Punkte des Verlaufs in den Koordinaten der Zeichenfunktion.
    enum Shading {
        case color(Color)
        case linearGradient(Gradient, startPoint: CGPoint, endPoint: CGPoint)

        func transformed(by transform: CGAffineTransform) -> Shading {
            switch self {
            case .color: self
            case .linearGradient(let gradient, let start, let end):
                .linearGradient(gradient, startPoint: start.applying(transform), endPoint: end.applying(transform))
            }
        }
    }

    struct Mark {
        let path: Path
        let shading: Shading
        /// `nil` füllt die Form.
        let stroke: StrokeStyle?

        @ViewBuilder
        func view(in size: CGSize) -> some View {
            let style = Self.style(shading, in: size)
            if let stroke {
                path.stroke(style, style: stroke)
            } else {
                path.fill(style)
            }
        }

        /// Verlauf relativ zur Fläche: Die Form füllt die ganze `Plot`, ihre Punkte sind absolut.
        private static func style(_ shading: Shading, in size: CGSize) -> AnyShapeStyle {
            switch shading {
            case .color(let color):
                AnyShapeStyle(color)
            case .linearGradient(let gradient, let start, let end):
                AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: unit(start, in: size),
                                             endPoint: unit(end, in: size)))
            }
        }

        private static func unit(_ point: CGPoint, in size: CGSize) -> UnitPoint {
            UnitPoint(x: size.width > 0 ? point.x / size.width : 0, y: size.height > 0 ? point.y / size.height : 0)
        }
    }

    /// Beschriftung, deren Punkt `anchor` (Anteil ihrer Größe) auf `point` liegt.
    struct Label {
        let content: AnyView
        let point: CGPoint
        let anchor: UnitPoint

        /// In einem Rahmen der ganzen Fläche: Dort gelten die Ausrichtungshilfen der Beschriftung selbst.
        func view(in size: CGSize) -> some View {
            let point = point, anchor = anchor
            return content
                .fixedSize()
                .alignmentGuide(.leading) { $0.width * anchor.x - point.x }
                .alignmentGuide(.top) { $0.height * anchor.y - point.y }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    /// Gezeichnetes in Zeichenreihenfolge; geteilt von allen Kopien eines Kontexts.
    final class Marks {
        fileprivate(set) var shapes: [Mark] = []
        fileprivate(set) var labels: [Label] = []
    }

    let marks = Marks()
    private(set) var transform = CGAffineTransform.identity

    func fill(_ path: Path, with shading: Shading) {
        add(path, shading, stroke: nil)
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        add(path, shading, stroke: style)
    }

    func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        add(path, shading, stroke: StrokeStyle(lineWidth: lineWidth))
    }

    /// Text, Symbol oder kleine Ansicht über allen Formen, `anchor` auf `point`.
    func draw(_ content: some View, at point: CGPoint, anchor: UnitPoint = .center) {
        marks.labels.append(Label(content: AnyView(content), point: point.applying(transform), anchor: anchor))
    }

    mutating func translateBy(x: CGFloat, y: CGFloat) {
        transform = transform.translatedBy(x: x, y: y)
    }

    mutating func scaleBy(x: CGFloat, y: CGFloat) {
        transform = transform.scaledBy(x: x, y: y)
    }

    private func add(_ path: Path, _ shading: Shading, stroke: StrokeStyle?) {
        marks.shapes.append(Mark(path: path.applying(transform), shading: shading.transformed(by: transform),
                                 stroke: stroke))
    }
}
