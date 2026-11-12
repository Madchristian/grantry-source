import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Eine App im Detail (Spec v3 §5; LB-2.5, #542): `RecordDetailPanel` mit Kopf, Knopfzeile „App entfernen …“ und „Reste
/// anzeigen“ (beide öffnen nur das Entfernen-Blatt), Hinweisen, eigener Einschätzung, Angaben aus dem Kit
/// (`InstalledAppDetail`), Pfad mit „Im Finder zeigen“ sowie Berechtigungen, Autostart-Einträgen und mitgebrachten
/// Erweiterungen als Sprungzeilen in ihre Bereiche.
struct InstalledAppDetailView: View {
    let detail: InstalledAppDetail
    let presentation: PresentationSnapshot
    let actions: ActionRunner
    let isRiskAccepted: Bool
    let acceptanceError: String?
    let setRiskAccepted: (Bool) async throws -> Void
    @State private var isSavingAcceptance = false
    @State private var saveError: String?
    @Environment(MainWindowModel.self) private var window

    private var app: InstalledApp { detail.app }

    var body: some View {
        let isRunning = actions.runningRecordID == app.id
        RecordDetailPanel(content: AppsBoardMapping.detail(detail, presentation: presentation,
                                                           isRiskAccepted: isRiskAccepted)) {
            AppIconView(app: app.identity, size: InstrumentSize.shield)
        } actions: {
            // „App entfernen …“ (Spec v3 §3, Einstiegspunkt 1) und „Reste anzeigen“.
            DetailActions(runningText: isRunning ? String(localized: "Wird entfernt …") : nil) {
                Group {
                    Button("App entfernen …") { window.requestRemoval(of: app) }
                    Button("Reste anzeigen") { window.requestRemoval(of: app, mode: .leftovers) }
                }
                .disabled(isRunning)
            }
        } accessory: { group in
            accessory(group.id)
        }
    }

    @ViewBuilder
    private func accessory(_ groupID: String) -> some View {
        switch groupID {
        case AppsBoardMapping.GroupID.acceptance:
            RiskAcceptanceControls(AppsBoardMapping.acceptance(isRiskAccepted: isRiskAccepted,
                                                               error: saveError ?? acceptanceError)) {
                Button(isRiskAccepted ? "Akzeptanz aufheben" : "Risiko akzeptieren") { toggleAcceptance() }
                    .disabled(isSavingAcceptance)
            }
        case AppsBoardMapping.GroupID.place:
            Button("Im Finder zeigen") { app.revealInFinder() }.controlSize(.small)
        case AppsBoardMapping.GroupID.grants:
            ForEach(detail.grants) { grant in
                JumpRow(AppsBoardMapping.grantRow(grant, presentation: presentation),
                        destination: MainSection.permissions.title) {
                    window.show(grant)
                } icon: {
                    ServiceIconView(service: PermissionCatalog.service(for: grant.service),
                                    size: InstrumentSize.rowIconTall)
                }
            }
        case AppsBoardMapping.GroupID.autostart:
            ForEach(detail.autostartItems) { item in
                JumpRow(item.jumpRowContent(badges: presentation.badges.badges(for: item.id)),
                        destination: MainSection.autostart.title) {
                    window.show(item)
                } icon: {
                    AutostartItemIcon(item: item, size: InstrumentSize.rowIconTall)
                }
            }
        case AppsBoardMapping.GroupID.extensions:
            ForEach(detail.extensions) { reference in
                JumpRow(AppsBoardMapping.extensionRow(reference, presentation: presentation),
                        destination: MainSection.extensions.title) {
                    window.show(reference)
                }
                .accessibilityIdentifier("appExtensionLink")
            }
        default:
            EmptyView()
        }
    }

    private func toggleAcceptance() {
        let accepted = !isRiskAccepted
        isSavingAcceptance = true
        saveError = nil
        Task {
            defer { isSavingAcceptance = false }
            do { try await setRiskAccepted(accepted) }
            catch { saveError = "Entscheidung nicht gespeichert: \(error.readableDescription)" }
        }
    }
}

extension InstalledApp {
    /// Zeigt das Bundle im Finder (Nutzeraktion, verändert nichts).
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
