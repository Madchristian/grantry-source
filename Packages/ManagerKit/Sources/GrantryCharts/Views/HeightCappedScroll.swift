import AppKit
import SwiftUI

/// Bildlauf, der so hoch ist wie sein Inhalt, höchstens `limit` (#479): Für Fenster, die sich nach ihrem Inhalt richten
/// (Einstellungen), damit sie nie über den Bildschirm hinausragen. Bis 2026.11.9 (1492) öffnete „Allgemein“ 1231 pt hoch
/// auf einem 949 pt hohen Bildschirm.
public struct HeightCappedScroll<Content: View>: View {
    private let limit: CGFloat
    private let content: Content

    public init(limit: CGFloat, @ViewBuilder content: () -> Content) {
        self.limit = limit
        self.content = content()
    }

    public var body: some View {
        HeightCap(limit: limit) {
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Bildlauf für Fenster, die sich nach ihrem Inhalt richten (Einstellungen, #525): so hoch wie der Inhalt, höchstens so
/// hoch, dass das Fenster mit Rand in den sichtbaren Bereich seines Bildschirms passt; das Fenster bleibt auf dem Bildschirm.
/// Die Grenze folgt dem Bildschirm des Fensters und dem gemessenen Rahmen darum, auch nach einem Wechsel des Bildschirms
/// oder der Auflösung. Bis 2026.11.10 (1547) kam sie aus `NSScreen.main` abzüglich geschätzter 100 pt und nur beim Zeichnen.
public struct ScreenCappedScroll<Content: View>: View {
    /// Bis das Fenster bekannt ist: Hauptbildschirm abzüglich geschätzter Titel- und Bereichsleiste.
    private static var estimatedLimit: CGFloat {
        ScreenFit.contentLimit(in: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768), chrome: 100)
    }

    private let content: Content
    @State private var limit: CGFloat?

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HeightCappedScroll(limit: limit ?? Self.estimatedLimit) { content }
            .fixedSize(horizontal: false, vertical: true)
            .background(WindowOnScreenKeeper { if limit != $0 { limit = $0 } })
    }
}

/// Nimmt die ideale Höhe des Inhalts, höchstens `limit`; in der Breite gilt der Vorschlag.
private struct HeightCap: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = min(ideal.height, limit)
        return CGSize(width: ideal.width, height: proposal.height.map { min($0, height) } ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
