import SwiftUI

// Gerüst des Bereichs Aufräumen im Lagebild (LB-4.2, #548; Entwurf LB-4.1, #547, Spec 2026-11-10 § 11.4): oben die
// Zustandszeile, darunter der Umschalter der Segmente mit Scan-Fortschritt bzw. Stand als Spur, Banner (Ergebnis,
// Teilerfolg, veraltet, fehlende Voraussetzung) und das Fund-Panel mit der Aktionsleiste unten. Reste, Speicher und
// Prozesse liefern Umschalter, Banner, Funde und Leiste als Slots.

/// Scan-Fortschritt oder Stand des Ergebnisses neben dem Umschalter (`ProgressSpur`).
public struct CleanupProgress: Hashable, Sendable {
    public let title: String
    public let detail: String
    /// `nil`: Dauer noch unbekannt, leere Bahn.
    public let fraction: Double?
    public let tone: StatusTone

    public init(title: String, detail: String, fraction: Double?, tone: StatusTone) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.tone = tone
    }
}

/// Ein Aufräumen-Segment im Lagebild. Vor dem ersten Ergebnis trägt `head` die Schildform `.open` ohne Chips
/// (Korrektur 3). Füllt die Fläche, die das Fenster gibt; die Funde rollen im Panel (`CleanupFindingList`).
public struct CleanupBoard<Controls: View, Banner: View, Content: View, Bar: View>: View {
    let head: InventoryHead
    let progress: CleanupProgress?
    let controls: Controls
    let banner: Banner
    let content: Content
    let bar: Bar

    public init(head: InventoryHead, progress: CleanupProgress?, @ViewBuilder controls: () -> Controls,
                @ViewBuilder banner: () -> Banner, @ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.head = head
        self.progress = progress
        self.controls = controls()
        self.banner = banner()
        self.content = content()
        self.bar = bar()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: head.verdict, shield: head.shield, items: head.items, facts: head.facts)
            HStack(spacing: InstrumentSpacing.panel) {
                controls.fixedSize()
                if let progress {
                    ProgressSpur(title: progress.title, detail: progress.detail, fraction: progress.fraction,
                                 tone: progress.tone)
                } else {
                    Spacer(minLength: 0)
                }
            }
            banner
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                bar
            }
            .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
            .instrumentPanel(padding: 0)
            .frame(maxHeight: .infinity)
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }
}

extension CleanupBoard where Banner == EmptyView {
    public init(head: InventoryHead, progress: CleanupProgress?, @ViewBuilder controls: () -> Controls,
                @ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.init(head: head, progress: progress, controls: controls, banner: { EmptyView() }, content: content,
                  bar: bar)
    }
}

/// Fundliste im Panel: Gruppen und Häkchenzeilen untereinander, lazy und rollend, ohne `GeometryReader` je Zeile. Im
/// Snapshot ohne Bildlauf (`ChartScrollView`), sonst zeichnet `ImageRenderer` die Funde nicht.
public struct CleanupFindingList<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ChartScrollView(showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: InstrumentSpacing.stack) { content }
                .padding(InstrumentSpacing.item)
        }
    }
}
