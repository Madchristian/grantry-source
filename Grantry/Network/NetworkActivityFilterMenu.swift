import ManagerKit
import SwiftUI

/// Filter der Netzwerkaktivität (Spec §4): „Nur aktive“ und „Apple-Systemdienste ausblenden“ sind standardmäßig an.
struct NetworkActivityFilterMenu: View {
    @Binding var filter: NetworkActivityFilter

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Aktivität filtern", reset: { filter = NetworkActivityFilter() }) {
            Toggle("Nur aktive", isOn: $filter.onlyActive)
            Toggle("Apple-Systemdienste ausblenden", isOn: $filter.hidesAppleServices)
            Toggle("Nur Interpreter (node, python …)", isOn: $filter.onlyInterpreters)
        }
    }
}
