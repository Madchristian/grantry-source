import GrantryCharts
import SwiftUI

/// Tabelle des Task-Managers: das gemeinsame Tabellen-Panel der Instrumententafel (`InstrumentTable`).
typealias TaskManagerTable = InstrumentTable

extension View {
    /// Auf- und Zuklappen als benannte VoiceOver-Aktion einer Zeile mit Pfeil.
    func disclosureAction(isExpandable: Bool, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(DisclosureAction(isExpandable: isExpandable, isExpanded: isExpanded, toggle: toggle))
    }
}

/// Nur aufklappbare Zeilen tragen die Aktion; die übrigen bleiben ohne Zusatz, damit große Tabellen je Takt nichts
/// Überflüssiges aufbauen.
private struct DisclosureAction: ViewModifier {
    let isExpandable: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if isExpandable {
            content.accessibilityAction(named: isExpanded ? Text("Zuklappen") : Text("Aufklappen"), toggle)
        } else {
            content
        }
    }
}
