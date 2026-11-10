import SwiftUI

/// Tabelle als Panel der Instrumententafel (§3.7): Spaltenkopf, Trennlinie, Zeilen im Bildlauf. Gemeinsam für Prozesse,
/// Details, Energie, App-Verlauf, Benutzer, Dienste, Verbindungen und Erweiterungen. Rollende Zeilen behalten
/// `InstrumentSize.tableRowsMinimum`; reicht der Platz nicht, rollt der Detailbereich (#507).
public struct InstrumentTable<Header: View, Rows: View>: View {
    /// Ohne Bildlauf in natürlicher Höhe, etwa für wenige Zeilen mit einem Panel darunter (Benutzer).
    var scrolls = true
    let header: Header
    let rows: Rows

    public init(scrolls: Bool = true, @ViewBuilder header: () -> Header, @ViewBuilder rows: () -> Rows) {
        self.scrolls = scrolls
        self.header = header()
        self.rows = rows()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scrolls {
                ChartScrollView(showsIndicators: true) { rows }
                    .frame(minHeight: InstrumentSize.tableRowsMinimum)
            } else {
                rows
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
        .instrumentPanel(padding: 0)
    }
}

extension View {
    /// Zeile, die ein Klick wählt: für VoiceOver eine Taste mit derselben Aktion, sonst ließe sich ohne Maus nichts
    /// wählen und „Task beenden“ oder „Stoppen“ blieben unerreichbar (Bewertung 2026.11.7, Mangel 12).
    public func selectableRow(_ select: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: select)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
    }
}

/// Abschnittskopf einer gruppierten Tabelle (§3.7): Leiste im Ton bzw. Befund-Punkt, Titel und Anzahl.
public struct InstrumentSectionHeader: View {
    let title: String
    let count: Int
    let tone: StatusTone
    let finding: Bool

    @Environment(\.self) private var environment

    /// - Parameter finding: Befund-Punkt statt der Leiste.
    public init(title: String, count: Int, tone: StatusTone = .neutral, finding: Bool = false) {
        self.title = title
        self.count = count
        self.tone = tone
        self.finding = finding
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            if finding {
                FindingDot(size: InstrumentSize.findingDotSmall)
            } else {
                Capsule().fill(environment.statusColor(tone))
                    .frame(width: InstrumentStroke.focusBar, height: InstrumentSize.disclosure)
            }
            Text(verbatim: title).font(InstrumentFont.label.weight(.semibold))
            Text(verbatim: "\(count)").font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
            Spacer()
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.top, InstrumentSpacing.group)
        .padding(.bottom, InstrumentSpacing.stack)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
