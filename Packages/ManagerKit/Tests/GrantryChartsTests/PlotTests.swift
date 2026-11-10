import SwiftUI
import Testing
@testable import GrantryCharts

/// Zeichenfläche aus Formen (#521): Sie nimmt dieselben Aufrufe wie ein `GraphicsContext` an, damit die Graphen ihre
/// Zeichenfunktionen behalten, legt aber keinen Grafik-Pool an.
@MainActor
@Suite struct PlotTests {
    private static let line: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 10))
        path.addLine(to: CGPoint(x: 20, y: 30))
        return path
    }()

    @Test func marksKeepDrawingOrderAndKind() {
        let context = PlotContext()
        context.fill(Path(CGRect(x: 0, y: 0, width: 4, height: 4)), with: .color(.red))
        context.stroke(Self.line, with: .color(.blue), lineWidth: 2)
        context.stroke(Self.line, with: .color(.blue), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        #expect(context.marks.shapes.map(\.stroke?.lineWidth) == [nil, 2, 3])
        #expect(context.marks.shapes[2].stroke?.lineCap == .round)
    }

    /// Wie bei `GraphicsContext`: Eine Kopie zeichnet auf dieselbe Fläche, ihre Verschiebung gilt nur für sie.
    @Test func copiesShareMarksButNotTheirTransform() {
        var context = PlotContext()
        var mirrored = context
        mirrored.translateBy(x: 0, y: 100)
        mirrored.scaleBy(x: 1, y: -1)
        mirrored.stroke(Self.line, with: .color(.blue))
        context.stroke(Self.line, with: .color(.blue))
        context.translateBy(x: 5, y: 0)
        #expect(context.marks.shapes.count == 2)
        #expect(context.marks.shapes[0].path.boundingRect == CGRect(x: 0, y: 70, width: 20, height: 20))
        #expect(context.marks.shapes[1].path.boundingRect == CGRect(x: 0, y: 10, width: 20, height: 20))
    }

    @Test func gradientPointsFollowTheTransform() {
        var context = PlotContext()
        context.translateBy(x: 0, y: 50)
        context.fill(Self.line, with: .linearGradient(Gradient(colors: [.red, .clear]), startPoint: CGPoint(x: 0, y: 10),
                                                      endPoint: CGPoint(x: 0, y: 40)))
        guard case .linearGradient(_, let start, let end) = context.marks.shapes[0].shading else {
            Issue.record("kein Verlauf")
            return
        }
        #expect(start == CGPoint(x: 0, y: 60))
        #expect(end == CGPoint(x: 0, y: 90))
    }

    @Test func labelsSitOnTheirTransformedPoint() {
        var context = PlotContext()
        context.translateBy(x: 10, y: 0)
        context.draw(Text(verbatim: "3"), at: CGPoint(x: 5, y: 7), anchor: .topTrailing)
        #expect(context.marks.labels.map(\.point) == [CGPoint(x: 15, y: 7)])
        #expect(context.marks.labels.map(\.anchor) == [.topTrailing])
        #expect(context.marks.shapes.isEmpty)
    }
}
