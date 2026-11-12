import GrantryCharts
import SwiftUI

/// Galerieseite „Alle Ansichten“ (LB-5.5, #556): je umgebautem Bereich, Blatt und Fenster der Hauptzustand aus den
/// zentralen Bausteinen, in halber Größe und zwei Spalten. Dieselben Beispieldaten wie die Seiten der einzelnen Bereiche;
/// Task-Manager, Netzwerk, Sicherheit, Erweiterungen und Belegung haben eigene Bilder.
struct AllViewsBoard: View {
    /// Bereiche in der Reihenfolge der Seitenleiste, danach Blätter und Fenster.
    private static let areas: [(title: String, view: AnyView)] = [
        ("Übersicht", AnyView(OverviewDraftBoard.primary)),
        ("Apps", AnyView(AppsDraftBoard.primary)),
        ("Berechtigungen", AnyView(PermissionsDraftBoard.primary)),
        ("Autostart", AnyView(AutostartDraftBoard.primary)),
        ("Agenten", AnyView(AgentsDraftBoard.primary)),
        ("Verlauf", AnyView(HistoryDraftBoard.primary)),
        ("Beobachtungen", AnyView(ObservationsDraftBoard.primary)),
        ("Aufräumen › App-Reste", AnyView(LeftoversDraftBoard.primary)),
        ("Aufräumen › Speicher", AnyView(StorageDraftBoard.primary)),
        ("Aufräumen › Prozesse", AnyView(ProcessesDraftBoard.primary)),
        ("Blatt „App entfernen“", AnyView(RemovalDraftBoard.primary)),
        ("Einstellungen", AnyView(SettingsDraftBoard.primary)),
        ("Onboarding", AnyView(OnboardingDraftBoard.primary)),
        ("Was ist neu", AnyView(WhatsNewDraftBoard.primary)),
        ("Menüleisten-Menü", AnyView(MenuDraftBoard.primary)),
    ]

    var body: some View {
        AreaDraftPage(title: "Lagebild · Alle Ansichten",
                      subtitle: "Stand nach dem Umbau der übrigen Ansichten (Epic #557): je Bereich der Hauptzustand in "
                          + "halber Größe – feste Beispieldaten") {
            Grid(alignment: .topLeading, horizontalSpacing: InstrumentSpacing.empty,
                 verticalSpacing: InstrumentSpacing.empty) {
                ForEach(Array(stride(from: 0, to: Self.areas.count, by: 2)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(start..<min(start + 2, Self.areas.count), id: \.self) { index in
                            VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                                AreaDraftCaption(text: Self.areas[index].title)
                                HalfSize { Self.areas[index].view }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Zeichnet den Inhalt in halber Größe: misst ihn mit doppelter Breite, meldet die halbe Größe und verkleinert die
/// Zeichnung um die linke obere Ecke. Nur für die Übersichtsseite der Galerie.
private struct HalfSize<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HalfSizeLayout { content.scaleEffect(HalfSizeLayout.scale, anchor: .topLeading) }
    }
}

private struct HalfSizeLayout: Layout {
    static let scale: CGFloat = 0.5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(Self.enlarged(proposal))
        return CGSize(width: size.width * Self.scale, height: size.height * Self.scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width / Self.scale,
                                                         height: bounds.height / Self.scale))
    }

    private static func enlarged(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}
