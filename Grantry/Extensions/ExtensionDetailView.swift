import GrantryCharts
import ManagerKit
import SwiftUI

/// Detail einer Erweiterung mit eigener Einschätzung („Risiko akzeptieren“ wie bei Apps) und den Aktionen: in den
/// Systemeinstellungen öffnen, zugehörige App zeigen, im Finder zeigen und – nur für Plug-ins anderer Hersteller –
/// „In den Papierkorb …“ nach Bestätigung über den Finder. Kernel- und Systemerweiterungen entfernt Grantry nicht.
struct ExtensionDetailView: View {
    let detail: ExtensionDetail
    let appModel: AppModel
    @State private var isSavingAcceptance = false
    @State private var acceptanceError: String?
    @State private var trash = ServicePluginTrashFlow()

    var body: some View {
        ExtensionDetailPanel(content: ExtensionBoardMapping.detail(detail)) {
            if let acceptance = detail.acceptance {
                ExtensionAcceptanceControl(
                    isAccepted: acceptance == .accepted, isSaving: isSavingAcceptance,
                    error: acceptanceError ?? appModel.monitoring.riskAcceptanceError
                ) { setAccepted(acceptance != .accepted) }
            }
        } actions: {
            ForEach(detail.actions, id: \.self) { action in
                ExtensionActionButton(action: action, record: detail.row.record, appModel: appModel, trash: trash)
            }
        }
        .servicePluginTrashDialogs(trash, appModel: appModel)
    }

    private func setAccepted(_ accepted: Bool) {
        isSavingAcceptance = true
        acceptanceError = nil
        Task {
            defer { isSavingAcceptance = false }
            do { try await appModel.setExtensionRiskAccepted(accepted, extensionID: detail.row.id) }
            catch { acceptanceError = String(localized: "Entscheidung nicht gespeichert: \(error.readableDescription)") }
        }
    }

}

/// Knopf der eigenen Einschätzung mit Fehlertext.
private struct ExtensionAcceptanceControl: View {
    let isAccepted: Bool
    let isSaving: Bool
    let error: String?
    let toggle: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        Button(isAccepted ? "Akzeptanz aufheben" : "Risiko akzeptieren", action: toggle)
            .disabled(isSaving)
        if let error {
            Label {
                Text(verbatim: error)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(InstrumentFont.label)
            .foregroundStyle(environment.statusTextColor(.critical))
        }
    }
}
