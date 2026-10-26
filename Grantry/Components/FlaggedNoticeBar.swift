import ManagerKit
import SwiftUI

/// Hinweis über einer nach Befunden gefilterten Liste (#275): wie viele der gezählten Einträge hier stehen und in welchen
/// Bereichen die übrigen liegen – jeder Bereich als Sprung dorthin mit derselben Schwelle. Ohne weitere Bereiche nichts.
/// Gestaltung wie die Abdeckungshinweise (`NoticeBarLayout`).
struct FlaggedNoticeBar: View {
    let breakdown: FlaggedBreakdown?
    let area: FlaggedArea
    let filter: FindingFilter
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        if let notice = breakdown?.notice(in: area, filter: filter) {
            NoticeBarLayout(
                systemImage: PresentationTone.neutral.systemImage, tone: .neutral, headline: notice.headline,
                accessibilityLabel: notice.accessibilityLabel, isEmphasized: false
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { links(notice) }
                    VStack(alignment: .leading, spacing: 4) { links(notice) }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func links(_ notice: FlaggedNotice) -> some View {
        ForEach(notice.others) { other in
            Button { window.show(MainSection(other.area), findings: filter) } label: {
                Text(verbatim: other.label)
            }
            .buttonStyle(.link)
            .accessibilityLabel(Text(verbatim: other.accessibilityLabel))
        }
    }
}

/// Auswahl des Befund-Filters in den Filtermenüs der Listen – gleiche Stufen und Beschriftung überall.
struct FindingFilterPicker: View {
    @Binding var selection: FindingFilter

    var body: some View {
        Picker("Befunde", selection: $selection) {
            ForEach(FindingFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.inline)
    }
}

extension FindingFilter {
    /// Beschriftung im Filtermenü; „Nur auffällige“ heißt höchster Befund mittel oder hoch – wie die Kachel „Auffällig“.
    var title: LocalizedStringKey {
        switch self {
        case .all: "Alle Einträge"
        case .flagged: "Nur auffällige"
        case .withFindings: "Auffällige und Hinweise"
        }
    }

    /// Erklärung im leeren Zustand, wenn nur dieser Filter gesetzt ist.
    var emptyDescription: LocalizedStringKey {
        switch self {
        case .all, .withFindings: "Kein Eintrag hat einen Prüfhinweis."
        case .flagged: "Kein Eintrag hat einen Befund mit mittlerem oder hohem Risiko."
        }
    }
}

extension MainSection {
    /// Bereich des Hauptfensters zu einem Bereich mit Befunden.
    init(_ area: FlaggedArea) {
        self.init(area.inventoryArea)
    }
}
