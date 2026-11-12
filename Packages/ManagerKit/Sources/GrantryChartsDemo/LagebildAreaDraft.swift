import GrantryCharts
import SwiftUI

// Entwurf LB-2.1 (#538, Spec docs/superpowers/specs/2026-11-10-lagebild-altansichten-design.md § 4.3, § 5 Welle 2):
// gemeinsames Gerüst der vier Liste-Detail-Bereiche Berechtigungen, Autostart, Agenten und Apps. Nur Galerie mit festen
// Beispieldaten; die Bereiche benutzen die zentralen Bausteine aus LB-1.2 (#536) und verändern sie nicht. Knopfzeile und
// Sprungzeile sind seit LB-2.2 (#539) zentral (`DetailActions`, `JumpRow`). Seit LB-5.5 (#556) gibt es keine Entwurfstypen
// mehr: Zustandszeile, Liste, Leerzustand und Banner zeichnen die zentralen Bausteine (`InventoryHead`, `InstrumentList`,
// `InstrumentEmptyState`, `InstrumentBanner` mit `BannerDismissButton`); was auf `Sample` endet, sind Beispieldaten.

// MARK: - Inhalt

/// Abdeckung des letzten Scans als Spur; `showsDetails` zeigt den Sprung zu den Details der Abdeckung.
struct CoverageSample {
    let title: String
    let detail: String
    let fraction: Double?
    let tone: StatusTone
    var showsDetails = false
    var showsScan = false

    static let complete = CoverageSample(title: "Abdeckung vollständig", detail: "alle Quellen gelesen · 14:32",
                                        fraction: 1, tone: .positive)
    static let notScanned = CoverageSample(title: "Abdeckung unbekannt", detail: "noch nichts gelesen",
                                          fraction: 0, tone: .neutral, showsScan: true)
}

/// Umschalter oben im Bereich (etwa „Nach App · Nach Berechtigung“).
struct SegmentsSample {
    let label: String
    let options: [(value: String, label: String)]
    let selected: String
}

/// Badges der Beispieldaten (Abbildung von `RecordBadge` wie in LB-1.1).
enum SampleBadge {
    static let review = InstrumentBadge("prüfen", tone: .finding, spoken: "prüfen, mittlerer Schweregrad")
    static let reviewHigh = InstrumentBadge("prüfen", tone: .critical, spoken: "prüfen, hoher Schweregrad")
    static let new = InstrumentBadge("neu", tone: .neutral)
    static let cleanup = InstrumentBadge("aufräumen", tone: .neutral)
    static let accepted = InstrumentBadge("akzeptiert", tone: .neutral, spoken: "Risiko akzeptiert")
}

extension InstrumentListItem<String> {
    /// Eintrag mit Beispielinhalt; spart in den Beispieldaten die Verschachtelung über `InstrumentRowContent`.
    static func sample(_ id: String, _ symbol: String, _ title: String, _ detail: String,
                       badges: [InstrumentBadge] = [], status: StatusItem? = nil, finding: Bool = false) -> Self {
        InstrumentListItem(id: id, content: InstrumentRowContent(symbol: symbol, title: title, detail: detail,
                                                                 badges: badges, status: status, finding: finding))
    }
}

// MARK: - Seite

/// Galerieseite eines Bereichs: Titel, darunter nummerierte Abschnitte mit den Zuständen.
struct AreaDraftPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                Text(verbatim: title).font(InstrumentFont.display).accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
            content
        }
    }
}

/// Nummerierte Beschriftung eines Abschnitts.
struct AreaDraftCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(InstrumentFont.label.weight(.semibold)).foregroundStyle(.instrumentSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bereich

/// Ein Bereich im Lagebild aus dem zentralen Gerüst `InventoryBoard` (seit LB-2.2, #539): Zustandszeile, Umschalter und
/// Abdeckung, darunter Liste und Detail. Liste und Detail kommen als Slots, damit dieselbe Hülle auch die Leerzustände zeigt.
struct AreaDraftScreen<ListContent: View, DetailContent: View>: View {
    let verdict: InventoryHead
    var segments: SegmentsSample?
    /// Abdeckung des Scans; `nil` in Bereichen ohne eigene Quellen (Beobachtungen).
    let coverage: CoverageSample?
    /// Höhe von Liste und Detail. Im Bild rollen die Panels nicht, und ohne vorgegebene Höhe misst `InstrumentSplit` beide
    /// Teile in voller Breite; im Fenster gibt die Fensterhöhe sie vor.
    let height: CGFloat
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: DetailContent

    var body: some View {
        InventoryBoard(head: verdict) {
            HStack(spacing: InstrumentSpacing.panel) {
                if let segments {
                    InstrumentSegments(segments.label, selection: .constant(segments.selected),
                                       options: segments.options)
                        .frame(width: InstrumentSize.columnNarrow)
                }
                if let coverage { CoverageSampleSpur(coverage: coverage) }
            }
        } list: {
            list.frame(height: height)
        } detail: {
            detail.frame(height: height)
        }
        // Im Bild bestimmen Liste und Detail die Höhe; im Fenster füllt das Gerüst die Fläche.
        .fixedSize(horizontal: false, vertical: true)
        .areaDraftBorder()
    }
}

/// Abdeckung als Spur, bei Lücken mit Sprung zu den Details, vor dem ersten Scan mit „Jetzt scannen“.
struct CoverageSampleSpur: View {
    let coverage: CoverageSample

    var body: some View {
        ProgressSpur(title: coverage.title, detail: coverage.detail, fraction: coverage.fraction, tone: coverage.tone) {
            if coverage.showsDetails {
                Button("Details anzeigen …") {}.buttonStyle(.link).font(InstrumentFont.label)
            }
            if coverage.showsScan {
                Button("Jetzt scannen") {}.controlSize(.small)
            }
        }
    }
}

/// Detail-Spalte: oben auf Wunsch das Ergebnis einer Aktion als Banner (ersetzt `ActionResultContainer`), darunter das
/// Detail-Panel.
struct AreaDetailColumn<Banner: View, Content: View>: View {
    @ViewBuilder let banner: Banner
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            banner
            DetailPanel { content }
        }
    }
}

extension AreaDetailColumn where Banner == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(banner: { EmptyView() }, content: content)
    }
}

// MARK: - Leerzustände

/// Die drei Leerzustände eines Bereichs nebeneinander: noch kein Scan, unvollständige Abdeckung (Liste mit dem, was
/// gelesen wurde), keine Treffer für Suche und Filter.
struct AreaDraftEmptyStates: View {
    let area: String
    let itemsTitle: String
    let partial: InventoryHead
    let partialCoverage: CoverageSample
    let partialSections: [InstrumentListSection<String>]
    let noMatches: InventoryHead

    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
            compact(InventoryHead(verdict: "Noch nicht geprüft", shield: .open, items: [], facts: "kein Scan seit dem Start"),
                    coverage: .notScanned) {
                InstrumentEmptyState(symbol: "clock", title: "Noch kein Scan", message: "Der erste Scan liest \(area) ein.").instrumentPanel()
            }
            compact(partial, coverage: partialCoverage) {
                InstrumentList(itemsTitle, count: "\(partialSections.map(\.items.count).reduce(0, +))", sections: partialSections, selection: .constant(nil))
            }
            compact(noMatches, coverage: .complete) {
                InstrumentEmptyState(symbol: "magnifyingglass", title: "Keine Treffer", message: "Nichts passt zu Suche und Filter.").instrumentPanel()
            }
        }
    }

    /// Schmale Fassung ohne Detail: Zustandszeile, Abdeckung, Liste bzw. Leerzustand.
    private func compact(_ verdict: InventoryHead, coverage: CoverageSample,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: verdict.verdict, shield: verdict.shield, items: verdict.items, facts: verdict.facts)
            CoverageSampleSpur(coverage: coverage)
            content().frame(height: AreaDraftHeight.empty)
        }
        .areaDraftFrame()
    }
}

/// Höhe der Leerzustände im Bild; die Bereiche füllen später das Fenster.
enum AreaDraftHeight {
    static let empty: CGFloat = 300
    static let permissions: CGFloat = 560
    static let permissionsState: CGFloat = 470
    static let autostart: CGFloat = 600
    static let agents: CGFloat = 680
    static let agentsState: CGFloat = 520
    static let apps: CGFloat = 830
    static let appsState: CGFloat = 500
}

extension View {
    /// Rahmen eines Bereichs-Ausschnitts: Seitenrand, Grund und eine feine Kante wie ein Fenster.
    func areaDraftFrame() -> some View {
        padding(InstrumentSpacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .instrumentBackground()
            .areaDraftBorder()
    }

    /// Nur die feine Kante; Seitenrand und Grund bringt `InventoryBoard` selbst mit.
    func areaDraftBorder() -> some View {
        overlay {
            RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous)
                .strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.border)
                .accessibilityHidden(true)
        }
    }
}
