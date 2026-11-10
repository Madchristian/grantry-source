import GrantryCharts
import ManagerKit
import SwiftUI

/// Anordnung der Aktivität (§3.13): Datenverkehr mit Kennzahlen (ohne Messung ausgeblendet), Suche und Umschalter
/// „Aktiv | Alle“, darunter die Tabelle. Zeigt nur fertige Stände; Messung und Filter liegen beim `NetworkActivityModel`.
struct NetworkActivityBoard<Empty: View>: View {
    let rows: [NetworkActivityRow]
    let overview: NetworkActivityOverview
    let history: [TrafficRate]
    /// Ohne Messung (Fehlerzustand) gibt es weder Summen noch Verlauf.
    let measures: Bool
    @Binding var filter: NetworkActivityFilter
    @Binding var query: String
    @Binding var sortOrder: [KeyPathComparator<NetworkActivityRow>]
    let listeners: [NetworkListener]
    let showListener: (NetworkListener) -> Void
    /// Steht über der Tabelle, solange sie keine Zeile zeigt.
    @ViewBuilder let empty: () -> Empty

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            if measures {
                NetworkActivityHeader(overview: overview, history: history)
            }
            HStack(spacing: InstrumentSpacing.panel) {
                InstrumentSearchField(text: $query, prompt: String(localized: "Name, Ziel oder Port"))
                InstrumentSegments(String(localized: "Prozesse"), selection: $filter.onlyActive,
                                   options: [(true, String(localized: "Aktiv")), (false, String(localized: "Alle"))])
                Spacer(minLength: 0)
            }
            NetworkActivityTable(rows: rows, sortOrder: $sortOrder, listeners: listeners, showListener: showListener)
                .frame(maxHeight: .infinity)
                .overlay {
                    if rows.isEmpty { empty() }
                }
        }
        .padding(InstrumentSpacing.page)
    }
}
