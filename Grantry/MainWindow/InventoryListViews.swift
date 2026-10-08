import ManagerKit
import SwiftUI

// Suche, Filter und leere Zustände der Listen (Berechtigungen, Autostart, Agenten).

/// Leerer Zustand einer Liste: noch kein Scan, keine Treffer oder keine Einträge – „keine Einträge“ und „Nichts
/// Auffälliges“ nur bei vollständiger Abdeckung als Entwarnung (`CoverageAwareUnavailableView`, #142).
struct InventoryEmptyState: View {
    let section: MainSection
    let coverage: AreaCoverage?
    let hasSnapshot: Bool
    /// Titel und Erklärung, wenn der Bereich gar keine Einträge hat.
    var emptyTitle: LocalizedStringKey = "Keine Einträge"
    var emptyDescription: LocalizedStringKey?
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        if !hasSnapshot {
            ContentUnavailableView("Noch keine Daten", systemImage: "magnifyingglass",
                                   description: Text("Der erste Scan ist noch nicht abgeschlossen."))
        } else if !window.query(for: section).isEmpty {
            ContentUnavailableView.search(text: window.query(for: section))
        } else if window.filter(for: section) == ListFilter(onlyFlagged: true) {
            CoverageAwareUnavailableView(title: "Nichts Auffälliges", systemImage: "checkmark.shield",
                                         description: "Kein Eintrag hat einen Prüfhinweis.", coverage: coverage)
        } else if window.filter(for: section).isActive {
            NoFilterMatchesView(description: "Kein Eintrag passt zu den gewählten Filtern.") {
                window.filters[section] = nil
            }
        } else {
            CoverageAwareUnavailableView(title: emptyTitle, systemImage: section.systemImage, description: emptyDescription,
                                         coverage: coverage)
        }
    }
}

extension View {
    /// Suchfeld und Filtermenü in der Symbolleiste für einen Listenbereich.
    func inventorySearch(for section: MainSection, prompt: String) -> some View {
        modifier(InventorySearchModifier(section: section, prompt: prompt))
    }
}

private struct InventorySearchModifier: ViewModifier {
    let section: MainSection
    let prompt: String
    @Environment(MainWindowModel.self) private var window

    func body(content: Content) -> some View {
        content
            .searchable(
                text: Binding(get: { window.query(for: section) }, set: { window.searchText[section] = $0 }),
                placement: .toolbar,
                prompt: Text(prompt)
            )
            .toolbar {
                if let context = section.filterContext {
                    ToolbarItem {
                        ListFilterMenu(
                            filter: Binding(get: { window.filter(for: section) }, set: { window.filters[section] = $0 }),
                            context: context
                        )
                    }
                }
            }
    }
}

/// Filtermenü: Zustand (erlaubt/verweigert bzw. aktiviert/deaktiviert), Bereich (Benutzer/System), nur auffällige.
private struct ListFilterMenu: View {
    @Binding var filter: ListFilter
    let context: FilterContext

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Liste filtern", reset: { filter = ListFilter() }) {
            Picker("Zustand", selection: $filter.state) {
                ForEach(GrantStateFilter.allCases, id: \.self) { state in
                    Text(verbatim: state.title(for: context)).tag(state)
                }
            }
            .pickerStyle(.inline)
            Picker("Bereich", selection: $filter.scope) {
                ForEach(ScopeFilter.allCases, id: \.self) { scope in
                    Text(verbatim: scope.title).tag(scope)
                }
            }
            .pickerStyle(.inline)
            Toggle("Nur auffällige", isOn: $filter.onlyFlagged)
        }
    }
}
