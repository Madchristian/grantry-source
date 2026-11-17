import GrantryCharts
import ManagerKit
import SwiftUI

/// Popover der Übersicht in der Menüleiste (#495, Baukasten #499, Gestaltung „Lagebild“): Kopf mit „Anpassen“ und
/// „Task-Manager öffnen“, darunter die Tafel, wie Christian sie zusammengestellt hat (`OverviewBoard`). „Anpassen“
/// zeigt an ihrer Stelle den Editor (`OverviewBoardEditor`, Spec 2026-11-09-uebersicht-baukasten § 5). Ein Klick auf eine
/// Kachel meldet ihre Art samt Kachel in „Leistung“ (`open`), „Task-Manager öffnen“ meldet keine. Liest nur fertige
/// Stände und die fertige Lage (`placements`, nur bei geänderter Tafel neu gerechnet); ohne `isLive` (Popover
/// geschlossen) zeichnet es keine Graphen. So hoch wie sein Inhalt (`NSHostingController` mit `.preferredContentSize`),
/// auch nach Ändern der Tafel und beim Wechsel in und aus dem Bearbeiten; höher als `maximumHeight` läuft es im
/// Bildlauf. Die Grenze kommt aus dem Bildschirm des Popovers (`boardLimit(in:)`): Die Standard-Tafel ist samt Kopf rund
/// 840 pt hoch und passt auf einem MacBook Air 13 Zoll oder einem Bildschirm mit 720 pt nicht ganz darunter.
struct TaskManagerMenuBarPopover: View {
    /// Tafel zum Bearbeiten samt den Quellen dieses Macs (Katalog und Standard).
    struct Editing {
        let layout: Binding<OverviewBoardLayout>
        let configured: Set<TaskManagerSource>
    }

    let frame: TaskManagerFrame
    let measuredAt: Date
    let profile: ChipProfile
    let context: MenuBarOverviewContext
    let placements: [OverviewTilePlacement]
    /// Ohne (Snapshots, Render-Wächter) fehlt „Anpassen“.
    var editing: Editing?
    var isLive = true
    var maximumHeight = CGFloat.infinity
    /// Anfangs im Bearbeiten (Höhenprüfung, `popover_fit_check.swift`); in der App öffnet „Anpassen“ den Editor.
    @State var isEditing = false
    let open: (OverviewTileKind?, PerformanceMetric?) -> Void
    @Environment(\.self) private var environment

    /// Zwei Kacheln je Zeile passten bei 360 pt nicht (Bewertung 2026.11.9/1510, Später 8); vier Spalten zu 97 pt
    /// (Spec 2026-11-09-uebersicht-baukasten § 3).
    static let width: CGFloat = 440
    /// Raster der Tafel über die Inhaltsbreite: 440 − 2 × 14 = 412 pt.
    static let boardMetrics = BoardGridMetrics(width: width - 2 * InstrumentSpacing.page)
    /// Pfeil des `NSPopover` über dem Inhalt (gemessen unter macOS 26: Fenster 13 pt über und unter dem Inhalt).
    static let arrowHeight: CGFloat = 13
    /// Kopf mit „Übersicht“, „Anpassen“ und „Task-Manager öffnen“, gemessen 17 pt, mit Reserve für größere Schrift; die
    /// Fensterprüfung (`popover_fit_check.swift`, Fälle auf kleinen Bildschirmen) misst nach.
    static let headerHeight: CGFloat = 24
    /// Popover um die Tafel samt Pfeil: Ränder, Kopf und Abstand zur Tafel.
    static let chromeHeight = 2 * InstrumentSpacing.page + headerHeight + InstrumentSpacing.panel + arrowHeight
    /// Auch auf einem sehr niedrigen Bildschirm bleibt ein Ausschnitt der Tafel im Bildlauf.
    static let minimumBoardLimit: CGFloat = 200

    /// Höchste Höhe der Tafel, damit das Popover samt Pfeil mit Rand (`ScreenFit.margin`) in den sichtbaren Bereich
    /// `visible` seines Bildschirms passt, wie die Einstellungen (#525); darüber läuft die Tafel im Bildlauf.
    static func boardLimit(in visible: CGRect) -> CGFloat {
        max(ScreenFit.contentLimit(in: visible, chrome: chromeHeight), minimumBoardLimit)
    }

    var body: some View {
        let source = Self.source(frame: frame, measuredAt: measuredAt, profile: profile, context: context,
                                 isLive: isLive)
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            header
            if isEditing, let editing {
                scrolling {
                    OverviewBoardEditor(layout: editing.layout, configured: editing.configured, source: source,
                                        metrics: Self.boardMetrics) { isEditing = false }
                }
            } else if placements.isEmpty {
                ContentUnavailableView("Keine Kacheln", systemImage: "square.grid.2x2",
                                       description: Text("Mit „Anpassen“ Kacheln auf die Tafel legen."))
                    .frame(maxWidth: .infinity)
                    .instrumentPanel()
            } else {
                scrolling {
                    OverviewBoard(placements: placements, source: source, metrics: Self.boardMetrics) { kind in
                        open(kind, source.overview.metric(for: kind))
                    }
                }
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: Self.width)
        .instrumentBackground()
        .renderProbe("TaskManagerMenuBarPopover")
    }

    private var header: some View {
        HStack(spacing: InstrumentSpacing.group) {
            PeilHead(String(localized: "Übersicht"))
            if editing != nil, !isEditing {
                headerButton("Anpassen", systemImage: "square.grid.2x2") { isEditing = true }
                    .accessibilityIdentifier("overviewBoard.customize")
            }
            // In SwiftUI gezeichnet statt `.link`: Den AppKit-Knopf zeichnet `ImageRenderer` nicht (Sichtprüfung).
            headerButton("Task-Manager öffnen", systemImage: "arrow.up.forward.app") { open(nil, nil) }
        }
    }

    private func headerButton(_ title: LocalizedStringKey, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(InstrumentFont.body.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(environment.statusTextColor(.info))
    }

    @ViewBuilder
    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        if maximumHeight.isFinite {
            HeightCappedScroll(limit: maximumHeight, content: content)
        } else {
            // Ohne Grenze (Snapshots) ohne Bildlauf: `ImageRenderer` zeichnet keinen `ScrollView`.
            content()
        }
    }

    /// Fertiger Stand eines Takts für die Kacheln; Verläufe der letzten Minute nur bei offenem Popover (`isLive`).
    static func source(frame: TaskManagerFrame, measuredAt: Date, profile: ChipProfile,
                       context: MenuBarOverviewContext, isLive: Bool) -> OverviewTileSource {
        OverviewTileSource(overview: MenuBarOverviewPresentation.overview(for: frame.snapshot, profile: profile,
                                                                          context: context),
                           history: isLive ? ChartHistory(history: frame.history, measuredAt: measuredAt) : nil)
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Menüleiste – Übersicht") {
    @Previewable @State var layout = OverviewBoardLayout.standard(configured: Set(TaskManagerSource.allCases))
    TaskManagerMenuBarPopover(frame: TaskManagerPreviewData.frame, measuredAt: .now, profile: .current,
                              context: MenuBarOverviewContext(uptime: TaskManagerPreviewData.uptime),
                              placements: layout.placements(),
                              editing: .init(layout: $layout, configured: Set(TaskManagerSource.allCases))) { _, _ in }
}

#Preview("Menüleiste – ohne Messwerte") {
    TaskManagerMenuBarPopover(frame: .empty(interval: .oneSecond), measuredAt: .now, profile: .current,
                              context: MenuBarOverviewContext(),
                              placements: OverviewBoardLayout.standard(configured: Set(TaskManagerSource.allCases))
                                  .placements()) { _, _ in }
}
#endif
