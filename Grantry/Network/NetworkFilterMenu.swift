import ManagerKit
import SwiftUI

/// Filter der Liste „Netzwerk“ (Spec §8); Systemdienste sind standardmäßig ausgeblendet.
struct NetworkFilterMenu: View {
    @Binding var filter: NetworkListenerFilter

    var body: some View {
        FilterMenu(isActive: filter.isActive, help: "Dienste filtern", reset: { filter = NetworkListenerFilter() }) {
            Toggle("Von außen erreichbar", isOn: $filter.onlyExposed)
            Toggle("Nicht von Apple", isOn: $filter.onlyNonApple)
            Toggle("Interpreter (node, python …)", isOn: $filter.onlyInterpreters)
            Toggle("Ohne zugehörige App", isOn: $filter.onlyWithoutApp)
            Divider()
            Toggle("Systemdienste anzeigen", isOn: $filter.showsSystemServices)
        }
    }
}
