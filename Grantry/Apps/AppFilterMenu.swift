import ManagerKit
import SwiftUI

/// Sortierung und Filter der App-Liste (Spec v3 §5). „Filter zurücksetzen“ behält die Sortierung.
struct AppFilterMenu: View {
    @Binding var filter: AppListFilter

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Apps filtern und sortieren",
                   reset: { filter = AppListFilter(sort: filter.sort) }) {
            Picker("Sortieren nach", selection: $filter.sort) {
                ForEach(AppSortOrder.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Herkunft", selection: $filter.origin) {
                ForEach(AppOriginFilter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Architektur", selection: $filter.architecture) {
                ForEach(AppArchitectureFilter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Nur auffällige", isOn: $filter.onlyFlagged)
        }
    }
}
