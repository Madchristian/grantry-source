import SwiftUI

/// Urteil der Zustandszeile über den gewählten Zeitraum (§ 3.1).
public struct WatchbookStatus: Equatable, Sendable {
    public var verdict: String
    public var finding: Bool
    public var items: [StatusItem]
    public var facts: String

    public init(verdict: String, finding: Bool, items: [StatusItem], facts: String) {
        self.verdict = verdict
        self.finding = finding
        self.items = items
        self.facts = facts
    }
}

/// Maße der Tafel, die der Aufrufer zum Lesen braucht: Je Bildpunktspalte der Zeichenfläche höchstens ein Wert (§ 4.4).
public enum WatchbookBoardLayout {
    /// Breite der Zeichenfläche einer Spur bei `width` Breite der ganzen Tafel: Seitenrand, Innenabstand des Panels und
    /// Beschriftung der Spuren abgezogen.
    /// Steht „Zu diesem Zeitpunkt“ unter statt neben dem Verlauf, gehört dem Verlauf die ganze Breite.
    public static func graphWidth(forBoardWidth width: CGFloat) -> CGFloat {
        let inner = width - 2 * InstrumentSpacing.page
        let main = sideColumn.isSideBySide(in: inner) ? inner - InstrumentSpacing.panel - InstrumentSize.columnWide : inner
        return max(main - 2 * InstrumentSpacing.panel - InstrumentSize.laneLabel - InstrumentSpacing.panel, 0)
    }

    /// Verlauf mit Befunden und rechts „Zu diesem Zeitpunkt“; der Verlauf braucht neben der Spalte mindestens Zeitraum
    /// und Beschriftung der Spuren samt einer lesbaren Zeichenfläche, die Tabelle „Befunde“ darunter ihre festen Spalten
    /// samt „Grund“ (gut 538 pt). Mit 480 lief das Wachbuch bei 900 pt ohne Seitenleiste 42 pt rechts aus dem Fenster
    /// (Fensterprüfung, Befund 10.11.2026).
    static let sideColumn = InstrumentSideColumnLayout(side: .trailing, width: InstrumentSize.columnWide,
                                                       mainMinimum: 540)

    /// Höhe der Tabelle „Befunde“: Kopf und vier Zeilen; mehr scrollen.
    static let findingTableHeight: CGFloat = 4 * InstrumentSize.row + 5 * InstrumentSpacing.stack
        + 2 * InstrumentSpacing.item + 2 * InstrumentSpacing.cell + 2 * InstrumentSpacing.bar
}

/// Was neben und unter dem Verlauf steht: das Panel „Zu diesem Zeitpunkt“ und die Tabelle „Befunde“ (TM-12.6).
public struct WatchbookAnalysis: Equatable, Sendable {
    /// Inhalt des Panels an der Zeitmarke; `nil` ohne Zeitmarke („nichts gewählt“).
    public var moment: WatchbookMomentContent?
    /// Befunde im Zeitraum, neueste zuerst.
    public var findings: [WatchbookFindingRowContent]
    /// Satz, wenn der Zeitraum keine Befunde hat.
    public var findingsEmptyText: String

    public init(moment: WatchbookMomentContent?, findings: [WatchbookFindingRowContent], findingsEmptyText: String) {
        self.moment = moment
        self.findings = findings
        self.findingsEmptyText = findingsEmptyText
    }
}

/// Tab „Wachbuch“ im Lagebild (TM-12.5, Spec 2026-11-08 § 5.1): oben die Zustandszeile mit dem Urteil über den Zeitraum,
/// darunter das Panel „Verlauf“ mit Umschalter Zeitraum, Ereignisleiste, Verlaufsspuren, Thermikband und gemeinsamer
/// Zeitachse. Eine Zeitmarke per Klick, Ziehen oder Pfeiltasten wählt die Spalte, deren Werte die Spuren links zeigen;
/// Escape entfernt sie. Rechts (`column.wide`) das Panel „Zu diesem Zeitpunkt“, unter dem Verlauf die Tabelle „Befunde“
/// (TM-12.6); die Wahl eines Befunds setzt die Zeitmarke, Sprünge meldet `jump` mit der ID des Ziels. Kein Abspielen,
/// keine Wiedergabe-Knöpfe.
///
/// Zeichnet nur bei neuen Spalten, neuer Größe oder bewegter Zeitmarke (§ 4.4): Die Graphen hängen allein an ihren
/// Spalten, die Zeitmarke liegt als eigene Ebene darüber.
public struct WatchbookBoard<Period: Hashable>: View {
    let status: WatchbookStatus
    let state: WatchbookBoardState
    let readout: WatchbookReadout?
    let detail: String
    @Binding var period: Period
    let periods: [(value: Period, label: String)]
    @Binding var marker: Int?
    let analysis: WatchbookAnalysis
    @Binding var selectedFinding: String?
    let jump: (String) -> Void
    let enable: () -> Void

    /// - Parameters:
    ///   - detail: Detailzeile im Peilkopf, etwa „Letzte 24 Stunden · gemeinsame Zeitachse“.
    ///   - readout: Werte unter der Zeitmarke bzw. der neueste Stand; nur mit Aufzeichnung.
    ///   - analysis: Panel „Zu diesem Zeitpunkt“ und Tabelle „Befunde“; nur mit Aufzeichnung.
    ///   - selectedFinding: gewählte Zeile der Tabelle „Befunde“.
    ///   - jump: Sprung aus dem Panel mit der ID des Ziels (`WatchbookJumpContent.id`).
    ///   - enable: „Wachbuch einschalten“ im Leerzustand „aus“.
    public init(status: WatchbookStatus, state: WatchbookBoardState, readout: WatchbookReadout?, detail: String,
                period: Binding<Period>, periods: [(value: Period, label: String)], marker: Binding<Int?>,
                analysis: WatchbookAnalysis, selectedFinding: Binding<String?>, jump: @escaping (String) -> Void,
                enable: @escaping () -> Void) {
        self.status = status
        self.state = state
        self.readout = readout
        self.detail = detail
        _period = period
        self.periods = periods
        _marker = marker
        self.analysis = analysis
        _selectedFinding = selectedFinding
        self.jump = jump
        self.enable = enable
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusLine(verdict: status.verdict, finding: status.finding, items: status.items, facts: status.facts)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            if case .recorded = state {
                // Bei 900 pt mit Seitenleiste steht „Zu diesem Zeitpunkt“ unter dem Verlauf, statt rechts aus dem
                // Fenster zu laufen (#486).
                WatchbookBoardLayout.sideColumn {
                    VStack(spacing: InstrumentSpacing.panel) {
                        panel
                        WatchbookFindingTable(rows: analysis.findings, emptyText: analysis.findingsEmptyText,
                                              selection: $selectedFinding)
                            .frame(height: WatchbookBoardLayout.findingTableHeight)
                    }
                    WatchbookMomentPanel(content: analysis.moment, jump: jump)
                }
                .padding(InstrumentSpacing.page)
            } else {
                panel
                    .padding(InstrumentSpacing.page)
            }
        }
        .renderProbe("WatchbookBoard")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(String(localized: "Verlauf"), detail: detail, value: marker == nil ? "" : readout?.time ?? "",
                     identifier: "watchbookTitle")
            InstrumentControlRow {
                InstrumentSegments(String(localized: "Zeitraum"), selection: $period, options: periods)
            } trailing: {
                if case .recorded = state { WatchbookLegend() }
            }
            switch state {
            case .off:
                WatchbookOffState(enable: enable)
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text("Wachbuch wird gelesen"))
            case .empty:
                WatchbookEmptyState()
            case .recorded(let content):
                WatchbookTimeline(content: content, readout: readout, marker: $marker)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .instrumentPanel()
    }
}

private struct WatchbookLegend: View {
    var body: some View {
        HStack(spacing: InstrumentSpacing.page) {
            LegendItem(title: String(localized: "Empfangen"), hue: .received)
            LegendItem(title: String(localized: "Gesendet"), hue: .sent)
            LegendItem(title: String(localized: "Lesen"), hue: .diskRead)
            LegendItem(title: String(localized: "Schreiben"), hue: .diskWrite)
        }
    }
}

private struct WatchbookOffState: View {
    let enable: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Wachbuch ist aus", systemImage: "book.closed")
        } description: {
            Text("""
                Mit dem Wachbuch zeichnet Grantry alle 10 Sekunden Auslastung, Befunde und Änderungen auf – nur auf \
                diesem Mac, 7 Tage lang, ohne Helper.
                """)
        } actions: {
            Button("Wachbuch einschalten", action: enable)
                .accessibilityIdentifier("enableWatchbook")
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchbookEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("Noch keine Aufzeichnung", systemImage: "clock")
        } description: {
            Text("""
                Das Wachbuch ist an. Erste Werte erscheinen nach etwa 10 Sekunden; Zeiten mit ausgeschaltetem Mac oder \
                im Ruhezustand bleiben leer.
                """)
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Ereignisleiste, Spuren, Thermikband und Zeitachse; darüber die Zeitmarke.
private struct WatchbookTimeline: View {
    let content: WatchbookTimelineContent
    let readout: WatchbookReadout?
    @Binding var marker: Int?

    @Environment(\.self) private var environment

    private var gridPositions: [Double] { content.axis.map(\.position) }

    var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            VStack(spacing: InstrumentSpacing.group) {
                TimelineRow {
                    TimelineLabel(title: String(localized: "Ereignisse"), value: content.eventSummary)
                } content: {
                    WatchbookEventBar(marks: content.marks)
                        .frame(height: InstrumentSize.eventBar)
                }
                ForEach(content.lanes.enumerated(), id: \.element.id) { index, lane in
                    self.lane(lane, value: readout?.laneValues[safe: index] ?? "–")
                }
                TimelineRow {
                    TimelineLabel(title: String(localized: "Thermik"), value: readout?.thermal ?? "–")
                } content: {
                    WatchbookStateBand(tones: content.thermal)
                        .frame(height: InstrumentSize.stateBand)
                }
                .accessibilityElement(children: .combine)
            }
            .overlay(alignment: .leading) {
                WatchbookMarkerLayer(column: $marker, count: content.columnCount, step: content.markerStep,
                                     time: readout?.time)
                    .padding(.leading, InstrumentSize.laneLabel + InstrumentSpacing.panel)
            }
            TimelineRow {
                Color.clear.frame(height: 0)
            } content: {
                WatchbookAxis(ticks: content.axis)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func lane(_ lane: WatchbookLaneContent, value: String) -> some View {
        VerlaufLane(title: lane.title, value: value, hue: lane.hue) {
            switch lane.graph {
            case .line(let values, let upperBound, let hue):
                TimelineGraph(values: values, upperBound: upperBound, color: environment.instrumentColor(hue),
                              gridPositions: gridPositions)
            case .mirror(let upper, let lower, let upperBound, let upperHue, let lowerHue):
                TimelineMirrorGraph(upper: upper, lower: lower, upperBound: upperBound,
                                    colors: (environment.instrumentColor(upperHue), environment.instrumentColor(lowerHue)),
                                    gridPositions: gridPositions)
            }
        }
        .accessibilityReading(Text(verbatim: lane.title), value: Text(verbatim: ChartAccessibility.value(
            current: value, trend: ChartAccessibility.trend(of: lane.trendValues, tolerance: lane.upperBound * 0.05))))
    }
}

/// Zeile der Zeitleiste: Beschriftung links in der Breite der Verlaufsspuren, rechts die Zeichenfläche.
private struct TimelineRow<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    init(@ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            label.frame(width: InstrumentSize.laneLabel, alignment: .leading)
            content.frame(maxWidth: .infinity)
        }
    }
}

private struct TimelineLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            Text(verbatim: title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
            Text(verbatim: value).font(InstrumentFont.label.weight(.medium).monospacedDigit())
                .foregroundStyle(.instrumentSecondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
