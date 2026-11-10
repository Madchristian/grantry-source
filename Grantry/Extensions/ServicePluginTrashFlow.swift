import AppKit
import ManagerKit
import Observation
import SwiftUI

/// „In den Papierkorb …“ für ein Plug-in eines Systemdienstes – gemeinsam für das Detail im Bereich „Erweiterungen“ und
/// die Reste in „Aufräumen“: belegt den Eintrag beim Öffnen der Bestätigung (gesperrte nennen den Grund statt zu fragen),
/// legt erst nach der Bestätigung über den Finder in den Papierkorb und scannt danach die Erweiterungen neu.
@MainActor
@Observable
final class ServicePluginTrashFlow {
    /// Offene Bestätigung.
    var request: ServicePluginTrashRequest?
    /// Grund, warum nichts im Papierkorb liegt.
    var failure: String?
    private(set) var isTrashing = false

    func prepare(_ record: ExtensionRecord, appModel: AppModel) {
        switch appModel.extensionRemover.prepare(record) {
        case .ready(let request): self.request = request
        case .blocked(let reason): failure = reason
        }
    }

    func moveToTrash(_ request: ServicePluginTrashRequest, appModel: AppModel) {
        isTrashing = true
        Task {
            let outcome = await appModel.extensionRemover.moveToTrash(request)
            isTrashing = false
            switch outcome {
            case .trashed: await appModel.scanNow(only: [.extensions])
            case .notTrashed(let reason): failure = reason
            }
        }
    }
}

extension View {
    /// Bestätigung und Fehlermeldung von `flow`.
    func servicePluginTrashDialogs(_ flow: ServicePluginTrashFlow, appModel: AppModel) -> some View {
        modifier(ServicePluginTrashDialogs(flow: flow, appModel: appModel))
    }
}

private struct ServicePluginTrashDialogs: ViewModifier {
    @Bindable var flow: ServicePluginTrashFlow
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "In den Papierkorb legen?",
                isPresented: Binding(get: { flow.request != nil }, set: { if !$0 { flow.request = nil } }),
                titleVisibility: .visible, presenting: flow.request
            ) { request in
                Button("In den Papierkorb legen", role: .destructive) { flow.moveToTrash(request, appModel: appModel) }
                Button("Abbrechen", role: .cancel) {}
            } message: { request in
                Text("Der Finder legt „\(request.name)“ in den Papierkorb; „Zurücklegen“ bleibt möglich. Für Plug-ins unter /Library fragt der Finder nach deinem Passwort. Ein schon geladenes Plug-in bleibt bis zum Neustart seines Dienstes aktiv.")
            }
            .alert("Nicht in den Papierkorb gelegt", isPresented: Binding(get: { flow.failure != nil },
                                                                         set: { if !$0 { flow.failure = nil } }),
                   presenting: flow.failure) { _ in
                Button("OK") {}
            } message: { reason in
                Text(verbatim: reason)
            }
    }
}

/// Knopf einer Aktion an einer Erweiterung – gleich im Detail des Bereichs „Erweiterungen“ und bei den Resten in
/// „Aufräumen“. „In den Papierkorb …“ öffnet nur die Bestätigung von `trash` (`servicePluginTrashDialogs`).
struct ExtensionActionButton: View {
    let action: ExtensionAction
    let record: ExtensionRecord
    let appModel: AppModel
    let trash: ServicePluginTrashFlow
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        switch action {
        case .openSettings(let url):
            Button("In den Systemeinstellungen öffnen") { NSWorkspace.shared.open(url) }
        case .showApp(let path):
            Button("Zugehörige App zeigen") { showApp(at: path) }
        case .revealInFinder(let path):
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case .moveToTrash:
            Button("In den Papierkorb …") { trash.prepare(record, appModel: appModel) }
                .disabled(trash.isTrashing)
        }
    }

    /// Zeigt die App im Bereich „Apps“ (dort mit dem vorhandenen Entfernen); fehlt sie im Inventar, nur den Bereich.
    private func showApp(at path: String) {
        if let app = appModel.monitoring.snapshot?.installedApps.first(where: { $0.path == path }) {
            window.show(app)
        } else {
            window.show(.apps)
        }
    }
}
