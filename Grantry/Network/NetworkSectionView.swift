import ManagerKit
import SwiftUI

/// Bereich „Netzwerk“: Umschalter „Dienste | Aktivität“ in der Symbolleiste, darunter die lauschenden Dienste
/// (`NetworkView`) oder die Live-Aktivität (`NetworkActivityView`). Die Wahl merkt sich `MainWindowModel.networkMode`.
struct NetworkSectionView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        Group {
            switch window.networkMode {
            case .services:
                NetworkView(appModel: appModel, prerequisites: prerequisites)
            case .activity:
                NetworkActivityView(model: appModel.networkActivity,
                                    listeners: appModel.presentation?.network.listeners ?? [])
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $window.networkMode) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Lauschende Dienste oder aktuelle Netzwerkaktivität zeigen")
            }
        }
    }
}
